function Invoke-GwmCollection {
    <#
    .SYNOPSIS
        Runs one collection: replays an unfinished run, discovers sources, uploads new log segments, publishes the
        manifest (commit marker), advances the checkpoint and uploads run telemetry.
    .PARAMETER Configuration
        Validated configuration from Get-GwmConfiguration.
    .PARAMETER Trigger
        Reported in run telemetry (Scheduled, Manual, Validation, Test).
    .PARAMETER PlanOnly
        Discovers and plans without uploading or changing local state; the plan is returned in the Plan property.
    .PARAMETER ShowProgress
        Writes log events to the console in addition to the JSONL log.
    .OUTPUTS
        Run result: RunId, Status (Succeeded, PartiallySucceeded, Failed, AlreadyRunning), ExitCode (0, 1, 2, 4), Counts,
        ManifestPath, TelemetryPath, Issues, Plan.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Configuration,
        [ValidateSet('Scheduled', 'Manual', 'Validation', 'Test')][string] $Trigger = 'Manual',
        [switch] $PlanOnly,
        [switch] $ShowProgress,
        [ValidateRange(0, 3600)][int] $LockTimeoutSeconds = 0
    )
    $errors = Test-GwmConfigurationObject -Configuration $Configuration
    if ($errors.Count -gt 0) {
        $exception = [System.ArgumentException]::new("Invalid agent configuration:`n - " + ($errors -join "`n - "))
        $exception.Data['GwmConfigurationError'] = $true
        throw $exception
    }
    $context = New-GwmRunContext -Configuration $Configuration -Trigger $Trigger -PlanOnly:$PlanOnly
    [void][System.IO.Directory]::CreateDirectory($context.StateDirectory)
    Initialize-GwmLog -Directory $Configuration.agent.logDirectory -Level $Configuration.agent.logLevel -RunId $context.RunId -Console:$ShowProgress

    $lock = Enter-GwmRunLock -StateDirectory $context.StateDirectory -TimeoutSeconds $LockTimeoutSeconds
    if (-not $lock) {
        Write-GwmLog -Level Warning -EventName 'AlreadyRunning' -Message 'Another collection run is in progress; this run exits without doing anything.'
        return [pscustomobject]@{
            RunId = $context.RunId; Status = 'AlreadyRunning'; ExitCode = 4; Trigger = $Trigger; StartedUtc = $context.StartedUtc
            EndedUtc = [DateTime]::UtcNow; Counts = $context.Counts; ManifestPath = $null; TelemetryPath = $null; Issues = @(); Plan = $null
        }
    }

    $items = @()
    $status = 'Failed'
    try {
        try {
            Write-GwmLog -Level Information -EventName 'RunStarted' -Message "Agent $script:GwmAgentVersion run $($context.RunId) started (trigger $Trigger$(if ($PlanOnly) { ', plan only' }))."
            $null = Remove-GwmOldLog -Directory $Configuration.agent.logDirectory -RetentionDays ([int]$Configuration.agent.logRetentionDays)
            $context.InstanceId = Get-GwmAgentInstanceId -StateDirectory $context.StateDirectory
            $context.Server = Get-GwmServerIdentity -ServerConfiguration $Configuration.server
            $context.Agent = New-GwmAgentBlock -Server $context.Server -InstanceId $context.InstanceId
            $context.Target = New-GwmTarget -Configuration $Configuration -AgentInstanceId $context.InstanceId
            $context.Checkpoint = Read-GwmCheckpoint -StateDirectory $context.StateDirectory -AgentInstanceId $context.InstanceId -Issues $context.Issues
            if (-not $PlanOnly) {
                Send-GwmOutbox -Context $context
                Invoke-GwmJournalReplay -Context $context
                $pruned = Remove-GwmStaleCheckpointEntry -Checkpoint $context.Checkpoint -RetentionDays ([int]$Configuration.agent.checkpointRetentionDays) -Now $context.Now
                if ($pruned -gt 0) { Write-GwmLog -Level Information -EventName 'CheckpointPruned' -Message "$pruned checkpoint entries of files not seen for $($Configuration.agent.checkpointRetentionDays) days removed." }
            }
            $items = New-GwmCollectionPlan -Context $context
            $context.Plan = $items
            if (-not $PlanOnly) {
                if ($items.Count -gt 0) {
                    $journal = [ordered]@{
                        schemaVersion = '1.0'
                        runId         = $context.RunId
                        createdUtc    = Format-GwmUtc $context.Now
                        agent         = $context.Agent
                        manifestPath  = Get-GwmDocumentPath -Kind manifests -Environment $Configuration.environment -ServerName $context.Server.PartitionName -Date $context.Now -RunId $context.RunId
                        manifestJson  = $null
                        items         = $items
                    }
                    Save-GwmJournal -StateDirectory $context.StateDirectory -Journal $journal
                    Invoke-GwmUploadItems -Context $context -Journal $journal
                    Complete-GwmJournal -Context $context -Journal $journal
                }
                else {
                    Save-GwmCheckpoint -StateDirectory $context.StateDirectory -Checkpoint $context.Checkpoint
                }
            }
        }
        catch {
            $context.Fatal = $_
            Add-GwmIssue -Context $context -Level Error -Code 'RunFailed' -Message $_.Exception.Message
            Write-GwmLog -Level Debug -EventName 'RunFailedDetails' -Message ($_.ScriptStackTrace | Out-String)
            if (-not $PlanOnly -and $context.Checkpoint) {
                # Offsets only move after a published manifest; saving here keeps file observations (settle detection).
                try { Save-GwmCheckpoint -StateDirectory $context.StateDirectory -Checkpoint $context.Checkpoint } catch { $null = $_ }
            }
        }
        $status = Get-GwmRunStatus -Context $context -Items $items
        if (-not $PlanOnly -and $context.Agent) {
            try { $null = Send-GwmRunTelemetry -Context $context -Status $status } catch { Write-GwmLog -Level Warning -EventName 'TelemetryFailed' -Message $_.Exception.Message }
        }
    }
    finally {
        Exit-GwmRunLock -Mutex $lock
    }

    $exitCode = switch ($status) { 'Succeeded' { 0 } 'PartiallySucceeded' { 1 } default { 2 } }
    $level = switch ($status) { 'Succeeded' { 'Information' } 'PartiallySucceeded' { 'Warning' } default { 'Error' } }
    $counts = $context.Counts
    Write-GwmLog -Level $level -EventName 'RunCompleted' -Message ("Run {0} {1}: {2} segments uploaded ({3:N0} bytes), {4} skipped, {5} deferred files, {6} errors, {7} warnings." -f $context.RunId, $status, $counts.segmentsUploaded, $counts.bytesUploaded, $counts.segmentsSkipped, $counts.filesDeferred, $counts.errors, $counts.warnings)
    return [pscustomobject]@{
        RunId         = $context.RunId
        Status        = $status
        ExitCode      = $exitCode
        Trigger       = $Trigger
        StartedUtc    = $context.StartedUtc
        EndedUtc      = [DateTime]::UtcNow
        Counts        = $counts
        ManifestPath  = $context.ManifestPath
        TelemetryPath = $context.TelemetryPath
        Issues        = $context.Issues.ToArray()
        Plan          = if ($PlanOnly) { $items } else { $null }
    }
}
