#Requires -Version 7.2
<#
.SYNOPSIS
    Removes the ODGO agent: scheduled task and agent files. Configuration, client secret, state and logs are removed
    only with -RemoveData.

.EXAMPLE
    .\Uninstall-Agent.ps1
.EXAMPLE
    .\Uninstall-Agent.ps1 -RemoveData
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
$task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task -and $PSCmdlet.ShouldProcess("$TaskPath$TaskName", 'Unregister scheduled task')) {
    Unregister-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -Confirm:$false
}
if ((Test-Path -LiteralPath $InstallPath) -and $PSCmdlet.ShouldProcess($InstallPath, 'Remove agent files')) {
    Remove-Item -LiteralPath $InstallPath -Recurse -Force
}
if ($RemoveData -and (Test-Path -LiteralPath $DataPath) -and $PSCmdlet.ShouldProcess($DataPath, 'Remove configuration, client secret, state and logs')) {
    Remove-Item -LiteralPath $DataPath -Recurse -Force
}
$message = 'ODGO agent removed.'
if (-not $RemoveData) { $message += " Configuration, client secret and state kept in '$DataPath' (remove them with -RemoveData)." }
Write-Host $message
