#Requires -Version 7.2
<#
.SYNOPSIS
    Installs, configures or upgrades the ODGO agent on an on-premises data gateway server.

.DESCRIPTION
    Run from an elevated PowerShell 7 session. One command:
      1. copies the agent to InstallPath (default %ProgramFiles%\ODGO), which only SYSTEM and Administrators can
         change because the scheduled task runs the agent as SYSTEM;
      2. creates DataPath (default %ProgramData%\ODGO) with config, state and logs folders that only
         SYSTEM, Administrators and the task identity can access;
      3. writes config\config.json with the values below (every other setting keeps its default, see docs/configuration.md);
      4. stores the client secret encrypted with DPAPI (machine scope); you are prompted for it when needed;
      5. registers the scheduled task "\ODGO\Collect Gateway Logs";
      6. tests authentication and write access to OneLake.
    Re-run without parameters to upgrade the agent: the folders, configuration, secret, state and scheduled task of the
    existing installation are kept.
    InstallPath and DataPath must be new, empty or ODGO folders, owned by SYSTEM, Administrators, you or the task
    identity: a folder created by another user is refused, because that user could replace the agent or read the
    secret.

.PARAMETER InstallPath
    Folder of the agent files. Default: the folder of the existing installation, or %ProgramFiles%\ODGO. Use a local
    folder such as D:\ODGO: drive roots and network paths are refused.

.PARAMETER DataPath
    Folder of the configuration, client secret, state and logs. Default: the folder of the existing installation, or
    %ProgramData%\ODGO. If you change it, pass -ConfigPath <DataPath>\config\config.json to
    Invoke-GatewayLogCollection.ps1 when you run it yourself.

.PARAMETER WorkspaceId
    Fabric workspace id (printed by the ODGO_Setup notebook).

.PARAMETER LakehouseId
    Lakehouse id (printed by the ODGO_Setup notebook).

.PARAMETER TenantId
    Microsoft Entra tenant id of the app registration.

.PARAMETER ClientId
    Application (client) id of the app registration.

.PARAMETER ClientSecret
    Client secret value. When omitted you are prompted for it (input hidden) if no secret is stored yet.

.PARAMETER UpdateSecret
    Prompts for a new client secret (secret rotation) and keeps everything else.

.PARAMETER ManagedIdentity
    Uses the managed identity of the server (Azure Arc-enabled server or Azure VM) instead of a client secret.

.PARAMETER ManagedIdentityClientId
    Client id of a user-assigned managed identity (Azure VM only).

.PARAMETER ProxyUrl
    Outbound proxy such as http://proxy.contoso.com:8080. An empty string removes it.

.PARAMETER IntervalMinutes
    Collection interval of the scheduled task. Default: the interval of the existing task, or 15 minutes.

.PARAMETER TaskUser
    SYSTEM or a group managed service account such as CONTOSO\odgo-agent$. Default: the identity of the existing
    task, or SYSTEM.

.PARAMETER SkipTest
    Skips the connection test at the end.

.EXAMPLE
    .\Install-Agent.ps1 -WorkspaceId <workspace id> -LakehouseId <lakehouse id> -TenantId <tenant id> -ClientId <client id>

    First installation with an app registration; prompts for the client secret.
.EXAMPLE
    .\Install-Agent.ps1 -InstallPath D:\ODGO -WorkspaceId <workspace id> -LakehouseId <lakehouse id> -ManagedIdentity

    First installation in D:\ODGO, with the managed identity of the server.
.EXAMPLE
    & "$env:ProgramFiles\ODGO\Install-Agent.ps1" -UpdateSecret

    Secret rotation, from the agent folder.
.EXAMPLE
    .\Install-Agent.ps1

    Upgrade: run the script of the new version without parameters.
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'ClientSecret')]
param(
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')][string] $WorkspaceId,
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')][string] $LakehouseId,
    [Parameter(ParameterSetName = 'ClientSecret')]
    [ValidatePattern('^([0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}|[A-Za-z0-9.-]+\.[A-Za-z]{2,})$')][string] $TenantId,
    [Parameter(ParameterSetName = 'ClientSecret')]
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')][string] $ClientId,
    [Parameter(ParameterSetName = 'ClientSecret')][securestring] $ClientSecret,
    [Parameter(ParameterSetName = 'ClientSecret')][switch] $UpdateSecret,
    [Parameter(Mandatory, ParameterSetName = 'ManagedIdentity')][switch] $ManagedIdentity,
    [Parameter(ParameterSetName = 'ManagedIdentity')]
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')][string] $ManagedIdentityClientId,
    [AllowEmptyString()][string] $ProxyUrl,
    [ValidateRange(5, 1440)][int] $IntervalMinutes = 15,
    [string] $TaskUser = 'SYSTEM',
    [switch] $SkipTest,
    [string] $InstallPath = (Join-Path $env:ProgramFiles 'ODGO'),
    [string] $DataPath = (Join-Path $env:ProgramData 'ODGO'),
    [switch] $SkipElevationCheck
)
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) { throw 'The agent runs on Windows gateway servers.' }
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
$isElevated = ([Security.Principal.WindowsPrincipal]$currentUser).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isElevated -and -not $SkipElevationCheck -and -not $WhatIfPreference) {
    throw 'Run this script from an elevated PowerShell 7 session (Run as administrator).'
}
$modulePath = Join-Path $PSScriptRoot 'modules\ODGO.Agent\ODGO.Agent.psd1'
if (-not (Test-Path -LiteralPath $modulePath)) { throw "Agent module not found next to Install-Agent.ps1 ('$modulePath')." }
Get-Module ODGO.Agent | Remove-Module -Force -WhatIf:$false
Import-Module $modulePath -Force

function Set-ConfigValue {
    param([System.Collections.IDictionary] $Settings, [string] $Path, $Value)
    $parts = $Path.Split('.')
    $node = $Settings
    foreach ($part in $parts[0..($parts.Count - 2)]) {
        if ($node[$part] -isnot [System.Collections.IDictionary]) { $node[$part] = [ordered]@{} }
        $node = $node[$part]
    }
    $node[$parts[-1]] = $Value
}

function Resolve-AccountSid {
    param([string] $Name)
    if ($Name -match '^S-1-[0-9-]+$') { return [System.Security.Principal.SecurityIdentifier]::new($Name) }
    return [System.Security.Principal.NTAccount]::new($Name).Translate([System.Security.Principal.SecurityIdentifier])
}

function Assert-TrustedFolder {
    <# Refuses a folder that another user created or changed: that user could replace the agent, plant a configuration or read the client secret. #>
    param([string] $Path, [string[]] $TrustedSids)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $advice = "Check the folder, then delete it or make Administrators its owner (takeown /F `"$Path`" /A /R /D Y) and run the installer again."
    try { $items = @(Get-Item -LiteralPath $Path -Force) + @(Get-ChildItem -LiteralPath $Path -Recurse -Force) }
    catch { throw "Can't check the content of '$Path': $($_.Exception.Message) $advice" }
    foreach ($item in $items) {
        $owner = $null
        try { $owner = (Get-Acl -LiteralPath $item.FullName).GetOwner([System.Security.Principal.SecurityIdentifier]).Value }
        catch { $null = $_ }
        if ($owner -and $owner -in $TrustedSids) { continue }
        $name = if ($owner) { try { [System.Security.Principal.SecurityIdentifier]::new($owner).Translate([System.Security.Principal.NTAccount]).Value } catch { $owner } } else { 'an owner that can''t be read' }
        throw "'$($item.FullName)' is owned by $name, not by SYSTEM, Administrators, you or the task identity: another user may have created it to replace the agent or read the client secret. $advice"
    }
}

function Resolve-AgentFolder {
    <# Full path of an agent folder. Network paths and drive roots are refused. #>
    param([string] $Path, [string] $Name)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw "$Name is empty." }
    if ($Path.Trim().StartsWith('\\')) { throw "$Name must be a local folder, not a network path ('$Path')." }
    $full = [System.IO.Path]::GetFullPath($Path.Trim()).TrimEnd('\')
    if ([System.IO.Path]::GetPathRoot($full).TrimEnd('\') -ieq $full) { throw "$Name can't be the root of a drive ('$Path'): use a folder such as D:\ODGO." }
    return $full
}

function Assert-AgentFolderContent {
    <# An existing folder must be empty or already belong to ODGO, because its access rules are replaced. #>
    param([string] $Path, [string] $Name, [string[]] $Markers)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if (@(Get-ChildItem -LiteralPath $Path -Force).Count -eq 0) { return }
    foreach ($marker in $Markers) { if (Test-Path -LiteralPath (Join-Path $Path $marker)) { return } }
    throw "$Name '$Path' already contains other files: choose a new or empty folder, for example '$(Join-Path $Path 'ODGO')'."
}

function Set-FolderAccess {
    <# Replaces the access rules of a folder (inherited by its content). Writes the DACL only: Set-Acl would also try to write the SACL, which requires SeSecurityPrivilege. #>
    param([string] $Path, [hashtable[]] $Rules)
    $acl = [System.Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    foreach ($rule in $Rules) {
        $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($rule.Sid, $rule.Rights, $inherit, 'None', 'Allow'))
    }
    [System.IO.FileSystemAclExtensions]::SetAccessControl([System.IO.DirectoryInfo]::new($Path), $acl)
}

# The scheduled task keeps its identity and interval unless -TaskUser or -IntervalMinutes is passed.
$taskPath = '\ODGO\'
$taskName = 'Collect Gateway Logs'
$existingTask = Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction SilentlyContinue
$existingAction = if ($existingTask) { @($existingTask.Actions)[0] } else { $null }
$existingTaskUser = if ($existingTask) { "$($existingTask.Principal.UserId)" } else { '' }
if ($existingTaskUser -and -not $PSBoundParameters.ContainsKey('TaskUser')) {
    $TaskUser = $existingTaskUser
    if ($TaskUser -match '^S-1-[0-9-]+$') {
        try { $TaskUser = [System.Security.Principal.SecurityIdentifier]::new($TaskUser).Translate([System.Security.Principal.NTAccount]).Value } catch { $null = $_ }
    }
}
if ($existingTask -and -not $PSBoundParameters.ContainsKey('IntervalMinutes')) {
    $interval = @($existingTask.Triggers | ForEach-Object { $_.Repetition.Interval } | Where-Object { $_ }) | Select-Object -First 1
    try {
        $minutes = [int][System.Xml.XmlConvert]::ToTimeSpan($interval).TotalMinutes
        if ($minutes -ge 5 -and $minutes -le 1440) { $IntervalMinutes = $minutes }
    }
    catch { $null = $_ }
}
$systemNames = @('SYSTEM', 'NT AUTHORITY\SYSTEM', 'LocalSystem', 'S-1-5-18')
$runAsSystem = $TaskUser -in $systemNames
$taskUserSid = $null
if (-not $runAsSystem) {
    if ($TaskUser -notmatch '^S-1-' -and -not $TaskUser.EndsWith('$')) {
        throw "TaskUser must be SYSTEM or a group managed service account ending with '$' (got '$TaskUser')."
    }
    try { $taskUserSid = Resolve-AccountSid $TaskUser }
    catch { throw "The task identity '$TaskUser' can't be resolved ($($_.Exception.Message)). Pass -TaskUser SYSTEM, or the DOMAIN\name$ of a group managed service account that this server can use (Test-ADServiceAccount)." }
}

# The folders of an existing installation are kept unless -InstallPath or -DataPath is passed.
$previousInstallPath = if ($existingAction) { "$($existingAction.WorkingDirectory)".TrimEnd('\') } else { '' }
$previousDataPath = if ($existingAction -and "$($existingAction.Arguments)" -match '-ConfigPath "([^"]+)\\config\\config\.json"') { $Matches[1] } else { '' }
if ($previousInstallPath -and -not $PSBoundParameters.ContainsKey('InstallPath')) { $InstallPath = $previousInstallPath }
if ($previousDataPath -and -not $PSBoundParameters.ContainsKey('DataPath')) { $DataPath = $previousDataPath }
$InstallPath = Resolve-AgentFolder -Path $InstallPath -Name 'InstallPath'
$DataPath = Resolve-AgentFolder -Path $DataPath -Name 'DataPath'
if ($InstallPath -ieq $DataPath -or $InstallPath.StartsWith("$DataPath\", [StringComparison]::OrdinalIgnoreCase) -or
    $DataPath.StartsWith("$InstallPath\", [StringComparison]::OrdinalIgnoreCase)) {
    throw "InstallPath and DataPath must be separate folders, neither inside the other (got '$InstallPath' and '$DataPath')."
}
Assert-AgentFolderContent -Path $InstallPath -Name 'InstallPath' -Markers @('Invoke-GatewayLogCollection.ps1', 'modules\ODGO.Agent')
Assert-AgentFolderContent -Path $DataPath -Name 'DataPath' -Markers @('config', 'state', 'logs')

# Data written by SYSTEM, Administrators, you or the task identities (current and previous) is trusted; anything else is refused.
$trustedOwners = @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464', $currentUser.User.Value)
if ($taskUserSid) { $trustedOwners += $taskUserSid.Value }
if ($existingTaskUser -and $existingTaskUser -notin $systemNames) {
    try { $trustedOwners += (Resolve-AccountSid $existingTaskUser).Value } catch { $null = $_ }
}
Assert-TrustedFolder -Path $InstallPath -TrustedSids $trustedOwners
Assert-TrustedFolder -Path $DataPath -TrustedSids $trustedOwners

# 1. Configuration: the existing file (if any) plus the parameters, validated before anything changes.
$configFile = Join-Path $DataPath 'config\config.json'
$settings = [ordered]@{}
if (Test-Path -LiteralPath $configFile) {
    try { $settings = Get-Content -LiteralPath $configFile -Raw | ConvertFrom-Json -AsHashtable }
    catch { throw "The existing configuration '$configFile' is not valid JSON: $($_.Exception.Message)" }
    if ($settings -isnot [System.Collections.IDictionary]) { throw "The existing configuration '$configFile' must contain a JSON object. Fix or delete it, then run the installer again." }
}
elseif (-not $WorkspaceId -or -not $LakehouseId -or (-not $ManagedIdentity -and (-not $TenantId -or -not $ClientId))) {
    throw 'First installation: pass -WorkspaceId, -LakehouseId and either -TenantId and -ClientId or -ManagedIdentity. The ODGO_Setup notebook prints the complete command.'
}
$before = $settings | ConvertTo-Json -Depth 16 -Compress
if ($WorkspaceId) { Set-ConfigValue $settings 'target.workspaceId' $WorkspaceId.ToLowerInvariant() }
if ($LakehouseId) { Set-ConfigValue $settings 'target.lakehouseId' $LakehouseId.ToLowerInvariant() }
if ($ManagedIdentity) {
    Set-ConfigValue $settings 'authentication.mode' 'ManagedIdentity'
    if ($ManagedIdentityClientId) { Set-ConfigValue $settings 'authentication.managedIdentityClientId' $ManagedIdentityClientId.ToLowerInvariant() }
}
elseif ($TenantId -or $ClientId) {
    Set-ConfigValue $settings 'authentication.mode' 'ClientSecret'
    if ($TenantId) { Set-ConfigValue $settings 'authentication.tenantId' $TenantId }
    if ($ClientId) { Set-ConfigValue $settings 'authentication.clientId' $ClientId.ToLowerInvariant() }
}
if ($PSBoundParameters.ContainsKey('ProxyUrl')) { Set-ConfigValue $settings 'network.proxyUrl' $(if ($ProxyUrl) { $ProxyUrl } else { $null }) }
if ([System.IO.Path]::GetFullPath($DataPath).TrimEnd('\') -ine [System.IO.Path]::GetFullPath((Join-Path $env:ProgramData 'ODGO')).TrimEnd('\')) {
    Set-ConfigValue $settings 'agent.stateDirectory' (Join-Path $DataPath 'state')
    Set-ConfigValue $settings 'agent.logDirectory' (Join-Path $DataPath 'logs')
    Set-ConfigValue $settings 'authentication.clientSecretPath' (Join-Path $DataPath 'config\client-secret.dat')
}
$configuration = Get-GwmConfiguration -InputObject $settings
$authentication = $configuration.authentication
$configChanged = -not (Test-Path -LiteralPath $configFile) -or (($settings | ConvertTo-Json -Depth 16 -Compress) -ne $before)

# 2. Client secret: prompt before changing anything so that a cancelled prompt leaves the server untouched.
$secret = $ClientSecret
if ($authentication.mode -eq 'ClientSecret') {
    if (-not $secret -and -not $WhatIfPreference -and ($UpdateSecret -or -not (Test-Path -LiteralPath $authentication.clientSecretPath))) {
        try { $secret = Read-Host -Prompt "Client secret VALUE of application $($authentication.clientId) (input hidden)" -AsSecureString }
        catch { throw "Cannot prompt for the client secret ($($_.Exception.Message)). Pass it with -ClientSecret (Read-Host -AsSecureString)." }
        if ($null -eq $secret -or $secret.Length -eq 0) { throw 'No client secret entered: nothing was changed.' }
    }
}
elseif ($secret -or $UpdateSecret) {
    throw "-ClientSecret and -UpdateSecret apply to client secret authentication; this agent uses $($authentication.mode)."
}

# 3. Agent folder: SYSTEM and Administrators full control, everyone else read and execute, because the scheduled task
#    runs the agent as SYSTEM. The files are copied after the access rules are set, so that they inherit them. The
#    copy is skipped when the installed copy of this script runs, for example with -UpdateSecret.
$systemSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18')
$administratorsSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
$installRules = @(@{ Sid = $systemSid; Rights = 'FullControl' }, @{ Sid = $administratorsSid; Rights = 'FullControl' },
    @{ Sid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'); Rights = 'ReadAndExecute' })
$dataRules = @(@{ Sid = $systemSid; Rights = 'FullControl' }, @{ Sid = $administratorsSid; Rights = 'FullControl' })
if (-not $runAsSystem) {
    $installRules += @{ Sid = $taskUserSid; Rights = 'ReadAndExecute' }
    $dataRules += @{ Sid = $taskUserSid; Rights = 'Modify' }
}
if (-not $isElevated) {
    # Non-elevated run (-SkipElevationCheck, used by the tests): keep access for the current user.
    $installRules += @{ Sid = $currentUser.User; Rights = 'Modify' }
    $dataRules += @{ Sid = $currentUser.User; Rights = 'Modify' }
}
if ($PSCmdlet.ShouldProcess($InstallPath, 'Create the agent folder, restricted to SYSTEM and Administrators (read for users)')) {
    [void][System.IO.Directory]::CreateDirectory($InstallPath)
    Set-FolderAccess -Path $InstallPath -Rules $installRules
}
$sameFolder = [System.IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') -ieq $InstallPath
if (-not $sameFolder -and $PSCmdlet.ShouldProcess($InstallPath, 'Install agent files')) {
    foreach ($file in @('Install-Agent.ps1', 'Invoke-GatewayLogCollection.ps1', 'Uninstall-Agent.ps1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination (Join-Path $InstallPath $file) -Force
    }
    $moduleDestination = Join-Path $InstallPath 'modules\ODGO.Agent'
    if (Test-Path -LiteralPath $moduleDestination) { Remove-Item -LiteralPath $moduleDestination -Recurse -Force }
    [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $moduleDestination))
    Copy-Item -LiteralPath (Split-Path -Parent $modulePath) -Destination $moduleDestination -Recurse -Force
    Get-ChildItem -LiteralPath $InstallPath -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1' | Unblock-File
}

# 4. Data folders: SYSTEM and Administrators full control, task identity modify, nobody else. The subfolders are
#    created after the access rules are set, so that they inherit them.
if ($PSCmdlet.ShouldProcess($DataPath, "Create the data folder, restricted to SYSTEM, Administrators$(if (-not $runAsSystem) { " and $TaskUser" })")) {
    [void][System.IO.Directory]::CreateDirectory($DataPath)
    Set-FolderAccess -Path $DataPath -Rules $dataRules
}
foreach ($folder in @((Join-Path $DataPath 'config'), (Join-Path $DataPath 'state'), (Join-Path $DataPath 'logs'))) {
    if ($PSCmdlet.ShouldProcess($folder, 'Create data folder')) { [void][System.IO.Directory]::CreateDirectory($folder) }
}

# 5. Configuration file and secret.
if ($configChanged -and $PSCmdlet.ShouldProcess($configFile, 'Write configuration')) {
    [System.IO.File]::WriteAllText($configFile, ($settings | ConvertTo-Json -Depth 16) + "`n", [System.Text.UTF8Encoding]::new($false))
}
if ($secret -and $PSCmdlet.ShouldProcess($authentication.clientSecretPath, 'Store the client secret (DPAPI, machine scope)')) {
    Set-GwmClientSecret -Secret $secret -Path $authentication.clientSecretPath
}
$staleSecret = Join-Path $DataPath 'config\client-secret.dat'
if ($authentication.mode -ne 'ClientSecret' -and (Test-Path -LiteralPath $staleSecret) -and $PSCmdlet.ShouldProcess($staleSecret, 'Remove the unused client secret')) {
    Remove-Item -LiteralPath $staleSecret -Force
}

# 6. Scheduled task: registered when it's missing, when -TaskUser or -IntervalMinutes is passed, or when its command
#    changed (other install or data folder, missing pwsh.exe). Otherwise it's kept as is.
$arguments = '-NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "{0}" -ConfigPath "{1}" -Trigger Scheduled -Quiet' -f (Join-Path $InstallPath 'Invoke-GatewayLogCollection.ps1'), $configFile
$existingExecutable = "$($existingAction.Execute)"
$registerTask = -not $existingTask -or $PSBoundParameters.ContainsKey('IntervalMinutes') -or $PSBoundParameters.ContainsKey('TaskUser') -or
    "$($existingAction.Arguments)" -ne $arguments -or -not $existingExecutable -or -not [System.IO.File]::Exists($existingExecutable)
$taskMessage = "$taskPath$taskName, every $IntervalMinutes minutes as $TaskUser"
if (-not $registerTask) { $taskMessage += ' (kept)' }
elseif ($PSCmdlet.ShouldProcess("$taskPath$taskName", "Register scheduled task (every $IntervalMinutes minutes as $TaskUser)")) {
    $action = New-ScheduledTaskAction -Execute (Join-Path $PSHOME 'pwsh.exe') -Argument $arguments -WorkingDirectory $InstallPath
    $trigger = New-ScheduledTaskTrigger -Once -At ([DateTime]::Now.AddMinutes(2)) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) -RandomDelay (New-TimeSpan -Seconds 120)
    # A group managed service account uses LogonType Password: Windows retrieves its password from Active Directory.
    $taskPrincipal = if ($runAsSystem) { New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest }
    else { New-ScheduledTaskPrincipal -UserId $TaskUser -LogonType Password -RunLevel Highest }
    $taskSettings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 60) `
        -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Compatibility Win8
    $null = Register-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Action $action -Trigger $trigger -Principal $taskPrincipal -Settings $taskSettings `
        -Description 'Uploads on-premises data gateway logs to Microsoft Fabric OneLake (ODGO agent).' -Force
}
if ($WhatIfPreference) { return }

Write-Host ''
Write-Host 'ODGO agent installed.' -ForegroundColor Green
Write-Host "  Agent files    : $InstallPath"
Write-Host "  Configuration  : $configFile"
Write-Host "  Agent logs     : $(Join-Path $DataPath 'logs')"
Write-Host "  Scheduled task : $taskMessage"
if ($previousInstallPath -and $previousInstallPath -ine $InstallPath) {
    Write-Warning "The agent now runs from '$InstallPath'. The previous agent folder '$previousInstallPath' isn't used anymore: you can delete it."
}
if ($previousDataPath -and $previousDataPath -ine $DataPath) {
    Write-Warning "The agent now uses the data folder '$DataPath'. The previous one, '$previousDataPath', isn't used anymore: delete it once the agent works."
}

# 7. Connection test (as the current administrator; the scheduled task runs as $TaskUser).
if (-not $SkipTest) {
    Write-Host ''
    Write-Host 'Testing the configuration, authentication and OneLake write access...'
    & (Join-Path $InstallPath 'Invoke-GatewayLogCollection.ps1') -Test -ConfigPath $configFile
    if ($LASTEXITCODE -ne 0) {
        $testCommand = "& '$(Join-Path $InstallPath 'Invoke-GatewayLogCollection.ps1')' -Test"
        if ($configFile -ine [System.IO.Path]::GetFullPath((Join-Path $env:ProgramData 'ODGO\config\config.json'))) { $testCommand += " -ConfigPath '$configFile'" }
        Write-Warning "The test failed: fix the issues above, then run: $testCommand"
        exit 1
    }
}
