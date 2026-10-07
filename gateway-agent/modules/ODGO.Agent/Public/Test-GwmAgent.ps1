function Test-GwmAgent {
    <#
    .SYNOPSIS
        Validation mode: checks configuration, local folders, gateway discovery, authentication and the upload target
        without uploading log data. -WriteTest additionally writes and deletes a small object in the staging area.
    .OUTPUTS
        One object per check: Name, Status (Pass, Warning, Fail, Info), Message, Remediation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Configuration,
        [switch] $WriteTest
    )
    $results = [System.Collections.Generic.List[object]]::new()
    $add = {
        param([string] $Name, [string] $Status, [string] $Message, [string] $Remediation = $null)
        $results.Add([pscustomobject]@{ Name = $Name; Status = $Status; Message = (Protect-GwmText $Message); Remediation = $Remediation })
    }

    $errors = Test-GwmConfigurationObject -Configuration $Configuration
    if ($errors.Count -gt 0) {
        & $add 'Configuration' 'Fail' ($errors -join '; ') 'Fix the listed keys (see docs/configuration.md).'
        return , $results.ToArray()
    }
    & $add 'Configuration' 'Pass' "Environment '$($Configuration.environment)', target $($Configuration.target.type), authentication $($Configuration.authentication.mode)."
    & $add 'PowerShell' 'Pass' "PowerShell $($PSVersionTable.PSVersion) running as $([Environment]::UserDomainName)\$([Environment]::UserName)."

    foreach ($folder in @(@{ Name = 'State directory'; Path = $Configuration.agent.stateDirectory }, @{ Name = 'Log directory'; Path = $Configuration.agent.logDirectory })) {
        try {
            [void][System.IO.Directory]::CreateDirectory($folder.Path)
            $probe = Join-Path $folder.Path ('.write-test-{0}' -f [guid]::NewGuid().ToString('n'))
            [System.IO.File]::WriteAllText($probe, 'ok')
            [System.IO.File]::Delete($probe)
            & $add $folder.Name 'Pass' "$($folder.Path) is writable."
        }
        catch {
            & $add $folder.Name 'Fail' "$($folder.Path): $($_.Exception.Message)" 'Run Install-Agent.ps1 or grant Modify to the task identity.'
        }
    }
    $stateDirectory = $Configuration.agent.stateDirectory
    if ([System.IO.File]::Exists((Join-Path $stateDirectory 'journal.json'))) {
        & $add 'Pending run' 'Warning' 'An unfinished run journal exists; the next collection run completes it first.'
    }
    $outbox = Join-Path $stateDirectory 'outbox'
    if ((Test-Path -LiteralPath $outbox) -and @(Get-ChildItem -LiteralPath $outbox -File).Count -gt 0) {
        & $add 'Telemetry outbox' 'Warning' 'Run telemetry documents are waiting to be uploaded (previous upload failures).'
    }

    $server = Get-GwmServerIdentity -ServerConfiguration $Configuration.server
    & $add 'Server identity' 'Pass' "Server '$($server.PartitionName)' id $($server.Id) ($($server.IdSource)), $($server.LogicalProcessors) logical processors, time zone $($server.TimeZoneId)."

    $catalog = Get-GwmLogTypeCatalog -Overrides $Configuration.collection.logTypes
    foreach ($sourceConfiguration in @($Configuration.sources)) {
        $name = "Source '$($sourceConfiguration.name)'"
        if (-not $sourceConfiguration.enabled) { & $add $name 'Info' 'Disabled.'; continue }
        $source = Resolve-GwmSource -SourceConfiguration $sourceConfiguration
        if (-not $source.LogPath -or -not [System.IO.Directory]::Exists($source.LogPath)) {
            & $add $name 'Fail' "Gateway log folder '$($source.LogPath)' not found." 'Set sources[].logPath to the gateway log folder (gateway app > Diagnostics > Export logs shows it).'
            continue
        }
        if ($source.GatewayId) {
            & $add "$name gateway" 'Pass' "Gateway $($source.GatewayId) ($($source.GatewayIdSource)), name '$($source.GatewayName)', cluster '$($source.ClusterName)' ($($source.ClusterSource)), version $($source.GatewayVersion)."
        }
        else {
            & $add "$name gateway" 'Fail' 'Gateway id not found (no GatewayProperties.txt, no report file).' 'Set sources[].gatewayId (gateway app > Status) or wait until the gateway writes its first report file.'
        }
        if ($source.ServiceStatus -and $source.ServiceStatus -ne 'Running') {
            & $add "$name service" 'Warning' "Service '$($source.ServiceName)' is $($source.ServiceStatus)." 'Start the gateway service.'
        }
        $issues = [System.Collections.Generic.List[object]]::new()
        $files = Get-GwmSourceFile -Source $source -Catalog $catalog -Issues $issues
        foreach ($issue in $issues) { & $add "$name files" $(if ($issue.Level -eq 'Error') { 'Fail' } else { 'Warning' }) $issue.Message }
        $summary = ($files | Group-Object LogType | Sort-Object Name | ForEach-Object { '{0}={1}' -f $_.Name, $_.Count }) -join ', '
        if ($files.Count -gt 0) { & $add "$name files" 'Pass' "$($files.Count) files: $summary." }
        else { & $add "$name files" 'Warning' "No log files found in '$($source.LogPath)'." 'Check sources[].logPath and collection.logTypes.' }
    }

    $authentication = $Configuration.authentication
    if ($authentication.mode -eq 'ClientSecret') {
        try {
            $null = Read-GwmClientSecret -Path $authentication.clientSecretPath
            & $add 'Client secret' 'Pass' "Stored encrypted in '$($authentication.clientSecretPath)'."
        }
        catch { & $add 'Client secret' 'Fail' $_.Exception.Message 'Run Install-Agent.ps1 -UpdateSecret from an elevated PowerShell 7 session.' }
    }
    $tokenOk = $true
    if ($authentication.mode -ne 'None') {
        try {
            $null = Get-GwmAccessToken -Authentication $authentication -Network $Configuration.network -ForceRefresh
            & $add 'Authentication' 'Pass' "Token acquired with $($authentication.mode) for $($authentication.resource)."
        }
        catch {
            $tokenOk = $false
            & $add 'Authentication' 'Fail' $_.Exception.Message 'Check the tenant id, client id and secret of the app registration (docs/setup.md).'
        }
    }

    $instanceId = try { Get-GwmAgentInstanceId -StateDirectory $stateDirectory } catch { [guid]::Empty.ToString() }
    $target = New-GwmTarget -Configuration $Configuration -AgentInstanceId $instanceId
    if ($target.Type -eq 'LocalFolder') {
        try {
            [void][System.IO.Directory]::CreateDirectory($target.LocalPath)
            & $add 'Target' 'Pass' "Local folder '$($target.LocalPath)' is available."
        }
        catch { & $add 'Target' 'Fail' "Local folder '$($target.LocalPath)': $($_.Exception.Message)" }
    }
    elseif ($tokenOk) {
        try {
            $response = Invoke-GwmOneLakeRequest -Target $target -Method Head -Uri (Get-GwmOneLakeUrl -Target $target -RelativePath '') -Operation 'HEAD landing root' -AllowedStatusCodes @(404)
            if ($response.StatusCode -eq 404) {
                & $add 'Target' 'Fail' "Landing folder '$(Get-GwmTargetDisplayName $target)' does not exist." 'Run the ODGO_Setup notebook in the workspace first (it creates the folder) or check the workspace and lakehouse ids.'
            }
            else {
                & $add 'Target' 'Pass' "Landing folder '$(Get-GwmTargetDisplayName $target)' is reachable."
                $serverDate = Get-GwmHeaderValue $response.Headers 'Date'
                $parsed = [DateTimeOffset]::MinValue
                if ($serverDate -and [DateTimeOffset]::TryParse($serverDate, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) {
                    $skew = [Math]::Abs(([DateTimeOffset]::UtcNow - $parsed).TotalSeconds)
                    if ($skew -gt 120) { & $add 'Clock' 'Warning' "Local clock differs from the service clock by $([int]$skew) seconds." 'Synchronize the clock (w32tm /resync).' }
                    else { & $add 'Clock' 'Pass' "Clock skew $([int]$skew) s." }
                }
            }
        }
        catch {
            & $add 'Target' 'Fail' $_.Exception.Message 'Add the identity as Contributor in the workspace (Manage access) and enable the Fabric tenant settings listed in docs/setup.md.'
        }
    }
    if ($WriteTest -and ($target.Type -eq 'LocalFolder' -or $tokenOk)) {
        $probePath = '{0}/validation-{1}.txt' -f $target.StagingFolder, [guid]::NewGuid().ToString('n')
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes("ODGO write test $(Format-GwmUtc ([DateTime]::UtcNow))")
            $null = Publish-GwmObject -Target $target -RelativePath $probePath -Content $bytes
            Remove-GwmObject -Target $target -RelativePath $probePath
            & $add 'Write test' 'Pass' 'A test object was written, renamed and deleted in the staging area.'
        }
        catch {
            & $add 'Write test' 'Fail' $_.Exception.Message 'The identity needs write access to the landing folder.'
        }
    }
    return , $results.ToArray()
}
