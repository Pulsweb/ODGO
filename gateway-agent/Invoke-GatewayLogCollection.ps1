#Requires -Version 7.2
<#
.SYNOPSIS
    Collects on-premises data gateway logs and uploads new data to Microsoft Fabric OneLake (one run).

.DESCRIPTION
    Entry point used by the scheduled task "\ODGO\Collect Gateway Logs".
    Exit codes: 0 succeeded, 1 partially succeeded, 2 failed, 3 configuration error, 4 another run is in progress.
    With -Test: 0 when every check passed (warnings allowed), 1 otherwise.

.PARAMETER ConfigPath
    Agent configuration file. Default: config\config.json in the agent folder (the folder of this script).

.PARAMETER Test
    Checks the configuration, gateway discovery, authentication and OneLake write access (a small file is written and
    deleted in the staging folder) without uploading log data.

.PARAMETER Trigger
    Reported in run telemetry. The scheduled task uses Scheduled; interactive runs default to Manual.

.PARAMETER LogLevel
    Overrides agent.logLevel for this run.

.PARAMETER PlanOnly
    Shows what would be uploaded without uploading or changing local state.

.PARAMETER Quiet
    No console output (the JSONL log in agent.logDirectory is always written).

.EXAMPLE
    pwsh -File "C:\Program Files\ODGO\Invoke-GatewayLogCollection.ps1" -Test
.EXAMPLE
    pwsh -File "C:\Program Files\ODGO\Invoke-GatewayLogCollection.ps1"
#>
[CmdletBinding()]
param(
    [string] $ConfigPath = (Join-Path $PSScriptRoot 'config\config.json'),
    [switch] $Test,
    [ValidateSet('Scheduled', 'Manual', 'Test')][string] $Trigger = 'Manual',
    [ValidateSet('Debug', 'Information', 'Warning', 'Error')][string] $LogLevel,
    [switch] $PlanOnly,
    [switch] $Quiet
)
$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot 'modules\ODGO.Agent\ODGO.Agent.psd1'
try {
    Get-Module ODGO.Agent | Remove-Module -Force
    Import-Module $modulePath -Force
}
catch {
    if (-not $Quiet) { Write-Error "Cannot load the agent module '$modulePath': $($_.Exception.Message)" -ErrorAction Continue }
    exit 2
}

if ($Test) {
    try {
        $configuration = Get-GwmConfiguration -Path $ConfigPath -SkipValidation
        $results = Test-GwmAgent -Configuration $configuration -WriteTest
    }
    catch {
        $results = @([pscustomobject]@{ Name = 'Configuration'; Status = 'Fail'; Message = $_.Exception.Message; Remediation = 'Run Install-Agent.ps1 again or fix the configuration file.' })
    }
    foreach ($result in $results) {
        $color = switch ($result.Status) { 'Pass' { 'Green' } 'Warning' { 'Yellow' } 'Fail' { 'Red' } default { 'Gray' } }
        Write-Host ('[{0,-7}] {1}: {2}' -f $result.Status.ToUpperInvariant(), $result.Name, $result.Message) -ForegroundColor $color
        if ($result.Remediation -and $result.Status -in @('Fail', 'Warning')) { Write-Host ('          -> {0}' -f $result.Remediation) -ForegroundColor DarkGray }
    }
    exit ([int](@($results | Where-Object Status -eq 'Fail').Count -gt 0))
}

try {
    $override = @{}
    if ($LogLevel) { $override['agent.logLevel'] = $LogLevel }
    $configuration = Get-GwmConfiguration -Path $ConfigPath -Override $override
}
catch {
    if (-not $Quiet) { Write-Error "Configuration error: $($_.Exception.Message)" -ErrorAction Continue }
    exit 3
}

try {
    $showProgress = (-not $Quiet) -and [Environment]::UserInteractive
    $result = Invoke-GwmCollection -Configuration $configuration -Trigger $Trigger -PlanOnly:$PlanOnly -ShowProgress:$showProgress
}
catch {
    if ($_.Exception.Data['GwmConfigurationError']) {
        if (-not $Quiet) { Write-Error $_.Exception.Message -ErrorAction Continue }
        exit 3
    }
    if (-not $Quiet) { Write-Error "Collection failed: $($_.Exception.Message)" -ErrorAction Continue }
    exit 2
}

if (-not $Quiet) {
    $counts = $result.Counts
    Write-Host ''
    Write-Host ("Run {0}: {1}" -f $result.RunId, $result.Status)
    Write-Host ("  Sources scanned: {0}, files scanned: {1}, changed: {2}, deferred: {3}" -f $counts.sourcesScanned, $counts.filesScanned, $counts.filesChanged, $counts.filesDeferred)
    Write-Host ("  Segments planned: {0}, uploaded: {1} ({2:N0} bytes), skipped: {3}, replayed: {4}" -f $counts.segmentsPlanned, $counts.segmentsUploaded, $counts.bytesUploaded, $counts.segmentsSkipped, $counts.segmentsReplayed)
    if ($result.ManifestPath) { Write-Host "  Manifest: $($result.ManifestPath)" }
    foreach ($issue in $result.Issues) {
        $color = if ($issue.Level -eq 'Error') { 'Red' } else { 'Yellow' }
        Write-Host ("  [{0}] {1}: {2}" -f $issue.Level, $issue.Code, $issue.Message) -ForegroundColor $color
    }
    if ($PlanOnly -and $result.Plan) {
        $result.Plan | ForEach-Object { [pscustomobject]@{ LogType = $_.logType; File = $_.fileName; Start = $_.offsetStart; End = $_.offsetEnd; Path = $_.rawPath } } | Format-Table -AutoSize | Out-Host
    }
}
exit $result.ExitCode
