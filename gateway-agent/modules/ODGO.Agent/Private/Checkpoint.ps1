# Local state: agent instance id, checkpoint (committed offsets), journal (in-flight run), telemetry outbox, run lock.
# Files are written atomically (write-through temp file + File.Replace with backup).

$script:GwmPrefixBytes = 1024

function Save-GwmJsonFile {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)] $InputObject, [switch] $NoBackup)
    $directory = Split-Path -Parent $Path
    if ($directory) { [void][System.IO.Directory]::CreateDirectory($directory) }
    $json = $InputObject | ConvertTo-Json -Depth 32 -WarningAction SilentlyContinue
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($json)
    $temp = "$Path.tmp"
    $stream = [System.IO.FileStream]::new($temp, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None, 4096, [System.IO.FileOptions]::WriteThrough)
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally { $stream.Dispose() }
    if ([System.IO.File]::Exists($Path)) {
        $backup = if ($NoBackup) { [NullString]::Value } else { "$Path.bak" }
        [System.IO.File]::Replace($temp, $Path, $backup)
    }
    else {
        [System.IO.File]::Move($temp, $Path)
    }
}

function Read-GwmJsonFile {
    <# Reads a JSON state file; with -UseBackup a corrupt/missing file is restored from <file>.bak. #>
    param([Parameter(Mandatory)][string] $Path, [switch] $UseBackup)
    $candidates = @($Path)
    if ($UseBackup) { $candidates += "$Path.bak" }
    foreach ($candidate in $candidates) {
        if (-not [System.IO.File]::Exists($candidate)) { continue }
        try {
            $text = [System.IO.File]::ReadAllText($candidate)
            if ([string]::IsNullOrWhiteSpace($text)) { throw 'file is empty' }
            $parsed = $text | ConvertFrom-Json -Depth 64
            if ($parsed -isnot [System.Management.Automation.PSCustomObject]) { throw 'root is not a JSON object' }
            return [pscustomobject]@{ Value = (ConvertTo-GwmDictionary $parsed); Path = $candidate; Restored = ($candidate -ne $Path) }
        }
        catch {
            Write-GwmLog -Level Warning -EventName 'StateFileInvalid' -Message "State file '$candidate' is unreadable: $($_.Exception.Message)"
        }
    }
    return $null
}

function Get-GwmAgentInstanceId {
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $StateDirectory)
    $path = Join-Path $StateDirectory 'agent-instance.json'
    $existing = Read-GwmJsonFile -Path $path -UseBackup
    if ($existing -and "$($existing.Value.instanceId)" -match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
        return [string]$existing.Value.instanceId
    }
    $instanceId = [guid]::NewGuid().ToString()
    Save-GwmJsonFile -Path $path -InputObject ([ordered]@{ instanceId = $instanceId; createdUtc = (Format-GwmUtc ([DateTime]::UtcNow)) })
    return $instanceId
}

function New-GwmCheckpoint {
    param([string] $AgentInstanceId)
    [ordered]@{
        schemaVersion   = '1.0'
        agentInstanceId = $AgentInstanceId
        updatedUtc      = $null
        files           = [ordered]@{}
        snapshots       = [ordered]@{}
    }
}

function Read-GwmCheckpoint {
    <# Loads the checkpoint; restores from backup when corrupt; rebuilds an empty one when both are corrupt (Silver deduplicates). #>
    param(
        [Parameter(Mandatory)][string] $StateDirectory,
        [string] $AgentInstanceId,
        [System.Collections.Generic.List[object]] $Issues
    )
    $path = Join-Path $StateDirectory 'checkpoint.json'
    $result = Read-GwmJsonFile -Path $path -UseBackup
    if (-not $result) {
        if (([System.IO.File]::Exists($path) -or [System.IO.File]::Exists("$path.bak")) -and $null -ne $Issues) {
            $Issues.Add([pscustomobject]@{ Level = 'Warning'; Code = 'CheckpointRebuilt'; Message = 'Checkpoint and backup are unreadable; offsets restart at 0 (duplicates are removed by the Silver layer).'; SourceName = $null; FileName = $null })
        }
        return New-GwmCheckpoint -AgentInstanceId $AgentInstanceId
    }
    if ($result.Restored -and $null -ne $Issues) {
        $Issues.Add([pscustomobject]@{ Level = 'Warning'; Code = 'CheckpointRestored'; Message = 'Checkpoint was unreadable and has been restored from its backup.'; SourceName = $null; FileName = $null })
    }
    $checkpoint = $result.Value
    if ($checkpoint.files -isnot [System.Collections.IDictionary]) { $checkpoint.files = [ordered]@{} }
    if ($checkpoint.snapshots -isnot [System.Collections.IDictionary]) { $checkpoint.snapshots = [ordered]@{} }
    return $checkpoint
}

function Save-GwmCheckpoint {
    param([Parameter(Mandatory)][string] $StateDirectory, [Parameter(Mandatory)][System.Collections.IDictionary] $Checkpoint)
    $Checkpoint.updatedUtc = Format-GwmUtc ([DateTime]::UtcNow)
    Save-GwmJsonFile -Path (Join-Path $StateDirectory 'checkpoint.json') -InputObject $Checkpoint
}

function Remove-GwmStaleCheckpointEntry {
    <# Forgets files not seen for RetentionDays (they were deleted by the gateway's own log retention). #>
    param([System.Collections.IDictionary] $Checkpoint, [int] $RetentionDays, [datetime] $Now = [DateTime]::UtcNow)
    $limit = $Now.AddDays(-$RetentionDays)
    $removed = 0
    foreach ($section in @('files', 'snapshots')) {
        foreach ($key in @($Checkpoint[$section].Keys)) {
            $entry = $Checkpoint[$section][$key]
            $seen = ConvertTo-GwmDateTime $(if ($entry.Contains('lastSeenUtc')) { $entry.lastSeenUtc } else { $entry.uploadedUtc })
            if ($null -eq $seen -or $seen -lt $limit) { $Checkpoint[$section].Remove($key); $removed++ }
        }
    }
    return $removed
}

function Get-GwmFileKey {
    param([string] $SourceName, [string] $LogType, [string] $Fingerprint)
    return '{0}|{1}|{2}' -f $SourceName, $LogType, $Fingerprint
}

function Resolve-GwmFileIdentity {
    <#
    Maps files of one source/log type to checkpoint entries.
    Pass 1: same file name and same hash over the entry's recorded prefix length.
    Pass 2: same 1 KiB prefix hash under another name (legacy rename-based rotation).
    Unmatched files get a new identity (fingerprint = SHA-256 of the first 1 KiB, salted on collision).
    Each item needs Name, Prefix (byte[]), PrefixHashes (hashtable) and the properties Key, Entry, Match, NewFingerprint and
    NewPrefixHash (initially $null); the function fills them in.
    #>
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Checkpoint,
        [Parameter(Mandatory)][string] $SourceName,
        [Parameter(Mandatory)][string] $LogType,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Items
    )
    $candidates = @($Checkpoint.files.Keys | Where-Object { $Checkpoint.files[$_].sourceName -eq $SourceName -and $Checkpoint.files[$_].logType -eq $LogType })
    $used = [System.Collections.Generic.HashSet[string]]::new()
    $prefixHash = {
        param($item, [int] $length)
        if (-not $item.PrefixHashes.ContainsKey($length)) { $item.PrefixHashes[$length] = Get-GwmSha256Hex -Bytes $item.Prefix -Offset 0 -Count $length }
        $item.PrefixHashes[$length]
    }
    foreach ($pass in 1, 2) {
        foreach ($item in $Items) {
            if ($item.Key) { continue }
            foreach ($key in $candidates) {
                if ($used.Contains($key)) { continue }
                $entry = $Checkpoint.files[$key]
                $length = [int]$entry.prefixLength
                if ($item.Prefix.Length -lt $length -or $length -le 0) { continue }
                if ($pass -eq 1 -and $entry.fileName -ine $item.Name) { continue }
                if ($pass -eq 2 -and $length -lt $script:GwmPrefixBytes) { continue }
                if ((& $prefixHash $item $length) -ne $entry.prefixHash) { continue }
                $item.Key = $key
                $item.Entry = $entry
                $item.Match = if ($pass -eq 1) { 'SameName' } else { 'Renamed' }
                [void]$used.Add($key)
                break
            }
        }
    }
    foreach ($item in $Items) {
        if ($item.Key) { continue }
        $hash = & $prefixHash $item $item.Prefix.Length
        $fingerprint = $hash
        $salt = 0
        while ($Checkpoint.files.Contains((Get-GwmFileKey $SourceName $LogType $fingerprint)) -or $used.Contains((Get-GwmFileKey $SourceName $LogType $fingerprint))) {
            $salt++
            $fingerprint = Get-GwmStringSha256Hex ('{0}|{1}' -f $hash, $salt)
        }
        $item.Key = Get-GwmFileKey $SourceName $LogType $fingerprint
        $item.Entry = $null
        $item.Match = 'New'
        $item.NewFingerprint = $fingerprint
        $item.NewPrefixHash = $hash
        [void]$used.Add($item.Key)
    }
}

function Read-GwmJournal {
    param([Parameter(Mandatory)][string] $StateDirectory, [System.Collections.Generic.List[object]] $Issues)
    $path = Join-Path $StateDirectory 'journal.json'
    if (-not [System.IO.File]::Exists($path)) { return $null }
    $result = Read-GwmJsonFile -Path $path
    if (-not $result) {
        $quarantine = Join-Path $StateDirectory ('journal.corrupt-{0}.json' -f [DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))
        try { [System.IO.File]::Move($path, $quarantine) } catch { $null = $_ }
        if ($null -ne $Issues) { $Issues.Add([pscustomobject]@{ Level = 'Warning'; Code = 'JournalCorrupt'; Message = "Unreadable journal moved to '$quarantine'; its uploads will be re-planned."; SourceName = $null; FileName = $null }) }
        return $null
    }
    return $result.Value
}

function Save-GwmJournal {
    param([Parameter(Mandatory)][string] $StateDirectory, [Parameter(Mandatory)][System.Collections.IDictionary] $Journal)
    Save-GwmJsonFile -Path (Join-Path $StateDirectory 'journal.json') -InputObject $Journal -NoBackup
}

function Remove-GwmJournal {
    param([Parameter(Mandatory)][string] $StateDirectory)
    $path = Join-Path $StateDirectory 'journal.json'
    if ([System.IO.File]::Exists($path)) { [System.IO.File]::Delete($path) }
}

function Add-GwmOutboxItem {
    <# Keeps a document that could not be uploaded (run telemetry) for the next run; oldest items are dropped beyond MaxFiles. #>
    param([string] $StateDirectory, [string] $RelativePath, [string] $Json, [int] $MaxFiles = 100)
    if ($MaxFiles -le 0) { return }
    $outbox = Join-Path $StateDirectory 'outbox'
    [void][System.IO.Directory]::CreateDirectory($outbox)
    $name = '{0}-{1}.json' -f [DateTime]::UtcNow.ToString('yyyyMMddHHmmssfff'), [guid]::NewGuid().ToString('n').Substring(0, 8)
    Save-GwmJsonFile -Path (Join-Path $outbox $name) -InputObject ([ordered]@{ relativePath = $RelativePath; json = $Json }) -NoBackup
    $items = @(Get-ChildItem -LiteralPath $outbox -Filter '*.json' -File | Sort-Object Name)
    if ($items.Count -gt $MaxFiles) {
        foreach ($item in $items[0..($items.Count - $MaxFiles - 1)]) { Remove-Item -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue }
    }
}

function Get-GwmOutboxItem {
    param([string] $StateDirectory)
    $outbox = Join-Path $StateDirectory 'outbox'
    if (-not (Test-Path -LiteralPath $outbox)) { return }
    foreach ($file in Get-ChildItem -LiteralPath $outbox -Filter '*.json' -File | Sort-Object Name) {
        $read = Read-GwmJsonFile -Path $file.FullName
        if ($read -and $read.Value.relativePath -and $read.Value.json) {
            [pscustomobject]@{ File = $file.FullName; RelativePath = [string]$read.Value.relativePath; Json = [string]$read.Value.json }
        }
        else {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}

function Enter-GwmRunLock {
    <# Named mutex per state directory: prevents overlapping runs (scheduled task + manual run). Returns the mutex or $null when busy. #>
    param([Parameter(Mandatory)][string] $StateDirectory, [int] $TimeoutSeconds = 0)
    $suffix = (Get-GwmStringSha256Hex ([System.IO.Path]::GetFullPath($StateDirectory).TrimEnd('\', '/').ToLowerInvariant())).Substring(0, 16)
    $mutex = [System.Threading.Mutex]::new($false, "Global\ODGO.Agent.$suffix")
    $acquired = $false
    try { $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds)) }
    catch [System.Threading.AbandonedMutexException] { $acquired = $true }
    if (-not $acquired) { $mutex.Dispose(); return $null }
    return $mutex
}

function Exit-GwmRunLock {
    param([AllowNull()][System.Threading.Mutex] $Mutex)
    if ($null -eq $Mutex) { return }
    try { $Mutex.ReleaseMutex() } catch { $null = $_ }
    $Mutex.Dispose()
}
