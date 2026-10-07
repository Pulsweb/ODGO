#Requires -Version 7.2
<#
.SYNOPSIS
    Removes the ODGO agent: scheduled task and agent files. Configuration, client secret, state and logs are removed
    only with -RemoveData.

.PARAMETER InstallPath
    Folder of the agent files. Default: the folder used by the scheduled task, or %ProgramFiles%\ODGO.

.PARAMETER DataPath
    Folder of the configuration, client secret, state and logs. Default: the folder used by the scheduled task, or
    %ProgramData%\ODGO.

.PARAMETER RemoveData
    Also removes the data folder.

.EXAMPLE
    & "$env:ProgramFiles\ODGO\Uninstall-Agent.ps1"
.EXAMPLE
    & "$env:ProgramFiles\ODGO\Uninstall-Agent.ps1" -RemoveData
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $InstallPath = (Join-Path $env:ProgramFiles 'ODGO'),
    [string] $DataPath = (Join-Path $env:ProgramData 'ODGO'),
    [string] $TaskPath = '\ODGO\',
    [string] $TaskName = 'Collect Gateway Logs',
    [switch] $RemoveData
)
$ErrorActionPreference = 'Stop'

function Assert-AgentFolder {
    <# Only folders that contain ODGO files are removed: a wrong path must never delete anything else. #>
    param([string] $Path, [string] $Name, [string[]] $Markers)
    foreach ($marker in $Markers) { if (Test-Path -LiteralPath (Join-Path $Path $marker)) { return } }
    throw "$Name '$Path' doesn't look like an ODGO folder: nothing was removed. Pass the right -$Name."
}

$task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
$action = if ($task) { @($task.Actions)[0] } else { $null }
if ($action -and "$($action.WorkingDirectory)" -and -not $PSBoundParameters.ContainsKey('InstallPath')) { $InstallPath = "$($action.WorkingDirectory)" }
if ($action -and "$($action.Arguments)" -match '-ConfigPath "([^"]+)\\config\\config\.json"' -and -not $PSBoundParameters.ContainsKey('DataPath')) { $DataPath = $Matches[1] }

$removeFiles = Test-Path -LiteralPath $InstallPath
$removeData = $RemoveData -and (Test-Path -LiteralPath $DataPath)
if ($removeFiles) { Assert-AgentFolder -Path $InstallPath -Name 'InstallPath' -Markers @('Invoke-GatewayLogCollection.ps1', 'modules\ODGO.Agent') }
if ($removeData) { Assert-AgentFolder -Path $DataPath -Name 'DataPath' -Markers @('config', 'state', 'logs') }

if ($task -and $PSCmdlet.ShouldProcess("$TaskPath$TaskName", 'Unregister scheduled task')) {
    Unregister-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -Confirm:$false
}
if ($removeFiles -and $PSCmdlet.ShouldProcess($InstallPath, 'Remove agent files')) {
    Remove-Item -LiteralPath $InstallPath -Recurse -Force
}
if ($removeData -and $PSCmdlet.ShouldProcess($DataPath, 'Remove configuration, client secret, state and logs')) {
    Remove-Item -LiteralPath $DataPath -Recurse -Force
}
$message = 'ODGO agent removed.'
if (-not $RemoveData) { $message += " Configuration, client secret and state kept in '$DataPath' (remove them with -RemoveData)." }
Write-Host $message
