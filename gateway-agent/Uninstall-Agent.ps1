#Requires -Version 7.2
<#
.SYNOPSIS
    Removes the ODGO agent: scheduled task and agent files. The configuration, client secret, state and logs are
    removed only with -RemoveData.

.PARAMETER InstallPath
    Agent folder. Default: the folder used by the scheduled task, or %ProgramFiles%\ODGO.

.PARAMETER RemoveData
    Also removes the configuration, client secret, state and logs, then the folder itself.

.EXAMPLE
    pwsh -File "$env:ProgramFiles\ODGO\Uninstall-Agent.ps1"
.EXAMPLE
    pwsh -File "$env:ProgramFiles\ODGO\Uninstall-Agent.ps1" -RemoveData
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $InstallPath = (Join-Path $env:ProgramFiles 'ODGO'),
    [string] $TaskPath = '\ODGO\',
    [string] $TaskName = 'Collect Gateway Logs',
    [switch] $RemoveData
)
$ErrorActionPreference = 'Stop'

$task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
$action = if ($task) { @($task.Actions)[0] } else { $null }
if ($action -and "$($action.WorkingDirectory)" -and -not $PSBoundParameters.ContainsKey('InstallPath')) { $InstallPath = "$($action.WorkingDirectory)" }

# Only a folder that contains ODGO files is touched: a wrong path must never delete anything else.
$folderExists = Test-Path -LiteralPath $InstallPath
if ($folderExists -and -not @('Invoke-GatewayLogCollection.ps1', 'modules\ODGO.Agent', 'config\config.json').Where({ Test-Path -LiteralPath (Join-Path $InstallPath $_) })) {
    throw "InstallPath '$InstallPath' doesn't look like an ODGO folder: nothing was removed. Pass the right -InstallPath."
}

if ($task -and $PSCmdlet.ShouldProcess("$TaskPath$TaskName", 'Unregister scheduled task')) {
    Unregister-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -Confirm:$false
}
if ($folderExists -and $RemoveData) {
    if ($PSCmdlet.ShouldProcess($InstallPath, 'Remove the agent folder with its configuration, client secret, state and logs')) {
        Remove-Item -LiteralPath $InstallPath -Recurse -Force
    }
}
elseif ($folderExists) {
    foreach ($name in @('Install-Agent.ps1', 'Invoke-GatewayLogCollection.ps1', 'Uninstall-Agent.ps1', 'modules')) {
        $path = Join-Path $InstallPath $name
        if ((Test-Path -LiteralPath $path) -and $PSCmdlet.ShouldProcess($path, 'Remove agent file')) { Remove-Item -LiteralPath $path -Recurse -Force }
    }
}
$message = 'ODGO agent removed.'
if ($folderExists -and -not $RemoveData) { $message += " Configuration, client secret, state and logs kept in '$InstallPath' (remove them with -RemoveData)." }
Write-Host $message