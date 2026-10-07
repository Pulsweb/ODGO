# Run orchestration helpers: planning, uploads, commit (manifest + checkpoint) and journal replay.

function Add-GwmIssue {
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)][ValidateSet('Warning', 'Error')][string] $Level,
        [Parameter(Mandatory)][string] $Code,
        [Parameter(Mandatory)][string] $Message,
        [string] $SourceName,
        [string] $FileName
    )
    $Context.Issues.Add([pscustomobject]@{ Level = $Level; Code = $Code; Message = (Protect-GwmText $Message); SourceName = $SourceName; FileName = $FileName })
    Write-GwmLog -Level $Level -EventName $Code -Message $Message -Data ([ordered]@{ sourceName = $SourceName; fileName = $FileName })
}

function New-GwmRunContext {
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Configuration, [string] $Trigger, [switch] $PlanOnly)
    $now = [DateTime]::UtcNow
    [pscustomobject]@{
        RunId          = [guid]::NewGuid().ToString()
        StartedUtc     = $now
        Now            = $now
        Deadline       = $now.AddMinutes([int]$Configuration.agent.maxRunMinutes)
        Trigger        = $Trigger
        PlanOnly       = [bool]$PlanOnly
        Configuration  = $Configuration
        StateDirectory = $Configuration.agent.stateDirectory
        Issues         = [System.Collections.Generic.List[object]]::new()
        Counts         = [ordered]@{
            sourcesScanned = 0; sourcesSkipped = 0; filesScanned = 0; filesChanged = 0; filesDeferred = 0
            segmentsPlanned = 0; segmentsUploaded = 0; segmentsSkipped = 0; segmentsReplayed = 0; bytesUploaded = 0L
            errors = 0; warnings = 0
        }
        Gateways       = [ordered]@{}
        InstanceId     = $null
        Server         = $null
        Agent          = $null
        Target         = $null
        Checkpoint     = $null
        ManifestPath   = $null
        TelemetryPath  = $null
        Fatal          = $null
        UploadAborted  = $false
        Plan           = $null
    }
}

function Get-GwmGatewayStats {
    param($Context, $Source)
    if (-not $Context.Gateways.Contains($Source.Name)) {
        $Context.Gateways[$Source.Name] = [ordered]@{
            sourceName = $Source.Name; gatewayId = $Source.GatewayId; gatewayName = $Source.GatewayName
            clusterId = $Source.ClusterId; clusterName = $Source.ClusterName; gatewayVersion = $Source.GatewayVersion
            serviceStatus = $Source.ServiceStatus; filesScanned = 0; segmentsUploaded = 0; bytesUploaded = 0L
        }
    }
    return $Context.Gateways[$Source.Name]
}

function New-GwmPlanItem {
    <# Journal item describing one object to upload. #>
    param($Context, $Source, [string] $Kind, [string] $LogType, [string] $Format, [string] $UploadMode, [string] $FileName,
        [AllowNull()][string] $FilePath, [string] $Fingerprint, [long] $OffsetStart, [long] $OffsetEnd, [long] $HeaderBytes,
        [AllowNull()] $CreationUtc, [AllowNull()] $LastWriteUtc, [AllowNull()] $SizeBytes, [string] $Key)
    $snapshot = $UploadMode -eq 'snapshot'
    $segmentFile = Get-GwmSegmentFileName -SourceFileName $FileName -Fingerprint $Fingerprint -OffsetStart $OffsetStart -OffsetEnd $OffsetEnd -Snapshot:$snapshot
    [ordered]@{
        kind               = $Kind
        key                = $Key
        sequence           = 0
        sourceName         = $Source.Name
        logType            = $LogType
        format             = $Format
        uploadMode         = $UploadMode
        fileName           = $FileName
        filePath           = $FilePath
        fingerprint        = $Fingerprint
        prefixHash         = $null
        prefixLength       = 0
        offsetStart        = $OffsetStart
        offsetEnd          = $OffsetEnd
        headerBytes        = $HeaderBytes
        sourceCreationUtc  = Format-GwmUtcOrNull $CreationUtc
        sourceLastWriteUtc = Format-GwmUtcOrNull $LastWriteUtc
        sourceSizeBytes    = $SizeBytes
        gatewayId          = $Source.GatewayId
        gatewayName        = $Source.GatewayName
        clusterId          = $Source.ClusterId
        clusterName        = $Source.ClusterName
        segmentId          = Get-GwmSegmentId -ServerId $Context.Server.Id -ServerName $Context.Server.PartitionName -GatewayId $Source.GatewayId -LogType $LogType -SourceFingerprint $Fingerprint -OffsetStart $OffsetStart -OffsetEnd $OffsetEnd
        rawPath            = Get-GwmRawPath -Environment $Context.Configuration.environment -ClusterId $Source.PathClusterId -GatewayId $Source.GatewayId -ServerName $Context.Server.PartitionName -LogType $LogType -Date $Context.Now -FileName $segmentFile
        expectedSha256     = $null
        content            = $null
        contentHash        = $null
        pendingAfterCommit = $null
        status             = 'Planned'
        sha256             = $null
        byteCount          = $null
        uploadedUtc        = $null
        result             = $null
        error              = $null
    }
}

function Get-GwmMetadataPlanItem {
    <# agent-metadata snapshot: uploaded when its content changes or every collection.metadataRefreshHours. #>
    param($Context, $Source)
    $document = New-GwmAgentMetadataDocument -Source $Source -Server $Context.Server -Environment $Context.Configuration.environment -InstanceId $Context.InstanceId -CollectedUtc $Context.Now
    $stable = [ordered]@{ gateway = $document.gateway; server = $document.server; agent = $document.agent }
    $contentHash = Get-GwmStringSha256Hex ($stable | ConvertTo-Json -Depth 8 -Compress)
    $key = '{0}|agent-metadata' -f $Source.Name
    $entry = $Context.Checkpoint.snapshots[$key]
    if ($entry) {
        $entry.lastSeenUtc = Format-GwmUtc $Context.Now
        $uploaded = ConvertTo-GwmDateTime $entry.uploadedUtc
        $fresh = $uploaded -and ($Context.Now - $uploaded).TotalHours -lt [int]$Context.Configuration.collection.metadataRefreshHours
        if ($entry.contentHash -eq $contentHash -and $fresh) { return $null }
    }
    $bytes = ConvertTo-GwmJsonBytes $document
    $sha = Get-GwmSha256Hex -Bytes $bytes
    $item = New-GwmPlanItem -Context $Context -Source $Source -Kind 'generated' -LogType 'agent-metadata' -Format 'json' -UploadMode 'snapshot' `
        -FileName 'agent-metadata.json' -FilePath $null -Fingerprint $sha -OffsetStart 0 -OffsetEnd $bytes.Length -HeaderBytes 0 `
        -CreationUtc $null -LastWriteUtc $Context.Now -SizeBytes $bytes.Length -Key $key
    $item.content = [System.Text.Encoding]::UTF8.GetString($bytes)
    $item.contentHash = $contentHash
    $item.expectedSha256 = $sha
    return $item
}

function Get-GwmSnapshotPlanItem {
    param($Context, $Source, $File, $Definition)
    $collection = $Context.Configuration.collection
    $key = '{0}|{1}|{2}' -f $Source.Name, $File.LogType, $File.Name.ToLowerInvariant()
    $entry = $Context.Checkpoint.snapshots[$key]
    try { $stream = Open-GwmSharedFile -Path $File.Path -RetryCount ([int]$collection.lockRetryCount) -RetryDelayMilliseconds ([int]$collection.lockRetryDelayMilliseconds) }
    catch [System.IO.FileNotFoundException], [System.IO.DirectoryNotFoundException] { return $null }
    catch {
        Add-GwmIssue -Context $Context -Level Warning -Code 'FileLocked' -Message "Cannot open '$($File.Path)': $($_.Exception.Message)" -SourceName $Source.Name -FileName $File.Name
        $Context.Counts.filesDeferred++
        return $null
    }
    try {
        $length = $stream.Length
        if ($length -le 0) { return $null }
        if ($length -gt [long]$collection.maxSegmentBytes) {
            Add-GwmIssue -Context $Context -Level Warning -Code 'SnapshotTooLarge' -Message "Snapshot file '$($File.Name)' ($length bytes) exceeds collection.maxSegmentBytes and is not uploaded." -SourceName $Source.Name -FileName $File.Name
            return $null
        }
        $lastWrite = [System.IO.File]::GetLastWriteTimeUtc($File.Path)
        if ($entry) {
            $entry.lastSeenUtc = Format-GwmUtc $Context.Now
            $uploaded = ConvertTo-GwmDateTime $entry.uploadedUtc
            $settling = ($Context.Now - $lastWrite).TotalSeconds -lt [int]$collection.settleSeconds
            if ($settling -and $uploaded -and ($Context.Now - $uploaded).TotalMinutes -lt [int]$collection.maxSegmentAgeMinutes) { return $null }
        }
        $content = Read-GwmFileRange -Stream $stream -Offset 0 -Count $length
        $sha = Get-GwmSha256Hex -Bytes $content
        if ($entry -and $entry.sha256 -eq $sha) { return $null }
        $Context.Counts.filesChanged++
        $item = New-GwmPlanItem -Context $Context -Source $Source -Kind 'snapshot' -LogType $File.LogType -Format $Definition.format -UploadMode 'snapshot' `
            -FileName $File.Name -FilePath $File.Path -Fingerprint $sha -OffsetStart 0 -OffsetEnd $content.Length -HeaderBytes 0 `
            -CreationUtc ([System.IO.File]::GetCreationTimeUtc($File.Path)) -LastWriteUtc $lastWrite -SizeBytes $content.Length -Key $key
        $item.expectedSha256 = $sha
        return $item
    }
    finally { $stream.Dispose() }
}

function Get-GwmCsvHeaderBytes {
    param([System.IO.Stream] $Stream, [byte[]] $Prefix)
    $length = Get-GwmCsvHeaderLength -Prefix $Prefix
    if ($length -gt 0 -or $Prefix.Length -lt $script:GwmPrefixBytes) { return $length }
    $head = Read-GwmFileRange -Stream $Stream -Offset 0 -Count ([Math]::Min($Stream.Length, 65536))
    return Get-GwmCsvHeaderLength -Prefix $head
}

function Add-GwmIncrementalPlanItems {
    <# Plans record-aligned segments for the files of one source and log type. #>
    param($Context, $Source, [string] $LogType, $Definition, [object[]] $Files, [System.Collections.Generic.List[object]] $Items, $Budget)
    $collection = $Context.Configuration.collection
    $checkpoint = $Context.Checkpoint
    $now = $Context.Now
    $backfillLimit = $now.AddDays(-[int]$collection.initialBackfillDays)
    $opened = [System.Collections.Generic.List[object]]::new()
    try {
        foreach ($file in ($Files | Sort-Object LastWriteTimeUtc, Name)) {
            try { $stream = Open-GwmSharedFile -Path $file.Path -RetryCount ([int]$collection.lockRetryCount) -RetryDelayMilliseconds ([int]$collection.lockRetryDelayMilliseconds) }
            catch [System.IO.FileNotFoundException], [System.IO.DirectoryNotFoundException] { continue }
            catch {
                Add-GwmIssue -Context $Context -Level Warning -Code 'FileLocked' -Message "Cannot open '$($file.Path)': $($_.Exception.Message)" -SourceName $Source.Name -FileName $file.Name
                $Context.Counts.filesDeferred++
                continue
            }
            $length = $stream.Length
            if ($length -le 0) { $stream.Dispose(); continue }
            $prefix = Read-GwmFileRange -Stream $stream -Offset 0 -Count ([Math]::Min($length, $script:GwmPrefixBytes))
            $encodingIssue = Get-GwmTextEncodingIssue -Prefix $prefix
            if ($encodingIssue) {
                Add-GwmIssue -Context $Context -Level Warning -Code 'UnsupportedEncoding' -Message "'$($file.Name)' uses an unsupported encoding ($encodingIssue) and is skipped." -SourceName $Source.Name -FileName $file.Name
                $stream.Dispose()
                continue
            }
            $opened.Add([pscustomobject]@{
                    File = $file; Name = $file.Name; Stream = $stream; Length = $length; Prefix = $prefix; PrefixHashes = @{}
                    LastWriteUtc = [System.IO.File]::GetLastWriteTimeUtc($file.Path); CreationUtc = [System.IO.File]::GetCreationTimeUtc($file.Path)
                    Key = $null; Entry = $null; Match = $null; NewFingerprint = $null; NewPrefixHash = $null
                })
        }
        if ($opened.Count -eq 0) { return }
        Resolve-GwmFileIdentity -Checkpoint $checkpoint -SourceName $Source.Name -LogType $LogType -Items $opened.ToArray()

        foreach ($item in $opened) {
            $entry = $item.Entry
            $isNew = $false
            if ($entry -and $item.Length -lt [long]$entry.committedOffset) {
                Add-GwmIssue -Context $Context -Level Warning -Code 'FileTruncated' -Message "'$($item.Name)' is shorter ($($item.Length) bytes) than its committed offset ($($entry.committedOffset)); it is collected again as a new file." -SourceName $Source.Name -FileName $item.Name
                $checkpoint.files.Remove($item.Key)
                # A fresh fingerprint keeps the new generation's segment names distinct from the previous generation.
                $prefixHash = Get-GwmSha256Hex -Bytes $item.Prefix
                $salt = 0
                do {
                    $salt++
                    $fingerprint = Get-GwmStringSha256Hex ('{0}|generation|{1}|{2}' -f $prefixHash, $now.Ticks, $salt)
                } while ($checkpoint.files.Contains((Get-GwmFileKey $Source.Name $LogType $fingerprint)))
                $item.Key = Get-GwmFileKey $Source.Name $LogType $fingerprint
                $item.NewFingerprint = $fingerprint
                $item.NewPrefixHash = $prefixHash
                $item.Match = 'New'
                $item.Entry = $null
                $entry = $null
            }
            if ($item.Match -eq 'New' -or -not $entry) {
                $isNew = $true
                $entry = [ordered]@{
                    sourceName = $Source.Name; logType = $LogType; fileName = $item.Name; filePath = $item.File.Path
                    fingerprint = $item.NewFingerprint; prefixHash = $item.NewPrefixHash; prefixLength = $item.Prefix.Length
                    committedOffset = 0L; headerBytes = 0L; observedSize = $item.Length; sizeChangedUtc = Format-GwmUtc $now
                    pendingSinceUtc = $null; firstSeenUtc = Format-GwmUtc $now; lastSeenUtc = Format-GwmUtc $now
                    lastCommitUtc = $null; baseline = $false
                }
                if ($item.LastWriteUtc -lt $backfillLimit) {
                    $entry.committedOffset = $item.Length
                    $entry.baseline = $true
                    Write-GwmLog -Level Debug -EventName 'BackfillSkipped' -Message "'$($item.Name)' last written $($item.LastWriteUtc.ToString('u')) is older than collection.initialBackfillDays." -Data ([ordered]@{ sourceName = $Source.Name; fileName = $item.Name })
                }
                $checkpoint.files[$item.Key] = $entry
            }
            else {
                $entry.fileName = $item.Name
                $entry.filePath = $item.File.Path
                $entry.lastSeenUtc = Format-GwmUtc $now
                if ([int]$entry.prefixLength -lt $item.Prefix.Length) {
                    $entry.prefixHash = Get-GwmSha256Hex -Bytes $item.Prefix
                    $entry.prefixLength = $item.Prefix.Length
                }
            }

            $size = [long]$item.Length
            $committed = [long]$entry.committedOffset
            $previousSize = [long]$entry.observedSize
            if (-not $isNew -and $previousSize -ne $size) {
                $entry.observedSize = $size
                $entry.sizeChangedUtc = Format-GwmUtc $now
            }
            if ($size -le $committed) { $entry.pendingSinceUtc = $null; continue }

            $Context.Counts.filesChanged++
            if (-not $entry.pendingSinceUtc) { $entry.pendingSinceUtc = Format-GwmUtc $now }
            $pendingSince = ConvertTo-GwmDateTime $entry.pendingSinceUtc
            $lastWriteAge = ($now - $item.LastWriteUtc).TotalSeconds
            $stableFor = if ($isNew) { $lastWriteAge } elseif ($previousSize -eq $size) { ($now - (ConvertTo-GwmDateTime $entry.sizeChangedUtc)).TotalSeconds } else { 0 }
            $settled = $lastWriteAge -ge [int]$collection.settleSeconds -and $stableFor -ge [int]$collection.settleSeconds
            $closed = $settled -and $lastWriteAge -ge [Math]::Max(3600, 60 * [int]$collection.maxSegmentAgeMinutes)
            $force = ($now - $pendingSince).TotalMinutes -ge [int]$collection.maxSegmentAgeMinutes

            if ($Budget.Bytes -le 0 -or $Budget.Segments -le 0) { $Context.Counts.filesDeferred++; continue }
            $headerBytes = 0
            if ($Definition.format -eq 'csv') {
                $headerBytes = Get-GwmCsvHeaderBytes -Stream $item.Stream -Prefix $item.Prefix
                if ($headerBytes -eq 0) { $Context.Counts.filesDeferred++; continue }
            }
            $warnings = [System.Collections.Generic.List[object]]::new()
            $segments = Get-GwmSegmentPlan -Stream $item.Stream -Format $Definition.format -CommittedOffset $committed -Size $size -HeaderBytes $headerBytes `
                -Settled $settled -Closed $closed -Force $force -MinSegmentBytes ([long]$collection.minSegmentBytes) -MaxSegmentBytes ([long]$collection.maxSegmentBytes) `
                -ByteBudget $Budget.Bytes -SegmentBudget $Budget.Segments -Warnings $warnings
            foreach ($warning in $warnings) { Add-GwmIssue -Context $Context -Level Warning -Code 'OversizedRecord' -Message "$($item.Name): $warning" -SourceName $Source.Name -FileName $item.Name }
            if ($segments.Count -eq 0) { $Context.Counts.filesDeferred++; continue }
            $sequence = 0
            foreach ($segment in $segments) {
                $planItem = New-GwmPlanItem -Context $Context -Source $Source -Kind 'segment' -LogType $LogType -Format $Definition.format -UploadMode 'incremental' `
                    -FileName $item.Name -FilePath $item.File.Path -Fingerprint $entry.fingerprint -OffsetStart $segment.OffsetStart -OffsetEnd $segment.OffsetEnd `
                    -HeaderBytes $segment.HeaderBytes -CreationUtc $item.CreationUtc -LastWriteUtc $item.LastWriteUtc -SizeBytes $size -Key $item.Key
                $planItem.sequence = $sequence++
                $planItem.prefixHash = $entry.prefixHash
                $planItem.prefixLength = [int]$entry.prefixLength
                $planItem.pendingAfterCommit = if ($segment.OffsetEnd -ge $size) { $null } else { Format-GwmUtc $now }
                $Items.Add($planItem)
                $Budget.Bytes -= ($segment.OffsetEnd - $segment.OffsetStart + $segment.HeaderBytes)
                $Budget.Segments--
                $Context.Counts.segmentsPlanned++
            }
        }
    }
    finally {
        foreach ($item in $opened) { $item.Stream.Dispose() }
    }
}

function New-GwmCollectionPlan {
    <# Discovers sources and returns the list of journal items to upload (segments, snapshots, agent metadata). #>
    param($Context)
    $configuration = $Context.Configuration
    $catalog = Get-GwmLogTypeCatalog -Overrides $configuration.collection.logTypes
    $items = [System.Collections.Generic.List[object]]::new()
    $budget = [pscustomobject]@{ Bytes = [long]$configuration.collection.maxBytesPerRun; Segments = [int]$configuration.collection.maxSegmentsPerRun }
    $enabledSources = 0
    foreach ($sourceConfiguration in @($configuration.sources)) {
        if (-not $sourceConfiguration.enabled) { $Context.Counts.sourcesSkipped++; continue }
        $enabledSources++
        $source = Resolve-GwmSource -SourceConfiguration $sourceConfiguration
        Write-GwmLog -Level Information -EventName 'SourceDiscovered' -Message "Source '$($source.Name)': gateway $($source.GatewayId) ($($source.GatewayIdSource)), cluster '$($source.ClusterName)', logs '$($source.LogPath)'." -Data ([ordered]@{ sourceName = $source.Name; gatewayVersion = $source.GatewayVersion; serviceStatus = $source.ServiceStatus })
        if ([string]::IsNullOrWhiteSpace($source.LogPath) -or -not [System.IO.Directory]::Exists($source.LogPath)) {
            Add-GwmIssue -Context $Context -Level Error -Code 'LogFolderMissing' -Message "Gateway log folder '$($source.LogPath)' not found for source '$($source.Name)'. Set sources[].logPath." -SourceName $source.Name
            $Context.Counts.sourcesSkipped++
            continue
        }
        if (-not $source.GatewayId) {
            Add-GwmIssue -Context $Context -Level Error -Code 'GatewayIdNotFound' -Message "Gateway id of source '$($source.Name)' could not be discovered (no GatewayProperties.txt and no report file yet). Set sources[].gatewayId or wait until the gateway writes its first report." -SourceName $source.Name
            $Context.Counts.sourcesSkipped++
            continue
        }
        $Context.Counts.sourcesScanned++
        $stats = Get-GwmGatewayStats -Context $Context -Source $source
        $metadataItem = Get-GwmMetadataPlanItem -Context $Context -Source $source
        if ($metadataItem) { $items.Add($metadataItem); $Context.Counts.segmentsPlanned++ }

        $files = Get-GwmSourceFile -Source $source -Catalog $catalog -Issues $Context.Issues
        foreach ($issue in @($Context.Issues | Where-Object { $_.SourceName -eq $source.Name -and $_.Code -in @('ReportFolderMissing', 'FolderInaccessible') })) {
            Write-GwmLog -Level $issue.Level -EventName $issue.Code -Message $issue.Message
        }
        $stats.filesScanned += $files.Count
        $Context.Counts.filesScanned += $files.Count
        $groups = $files | Group-Object LogType | Sort-Object { $catalog[$_.Name].priority }
        foreach ($group in $groups) {
            $definition = $catalog[$group.Name]
            if ($definition.mode -eq 'snapshot') {
                foreach ($file in $group.Group) {
                    $snapshotItem = Get-GwmSnapshotPlanItem -Context $Context -Source $source -File $file -Definition $definition
                    if ($snapshotItem) { $items.Add($snapshotItem); $Context.Counts.segmentsPlanned++ }
                }
            }
            else {
                Add-GwmIncrementalPlanItems -Context $Context -Source $source -LogType $group.Name -Definition $definition -Files @($group.Group) -Items $items -Budget $budget
            }
        }
    }
    if ($enabledSources -eq 0) {
        Add-GwmIssue -Context $Context -Level Error -Code 'NoSourceEnabled' -Message 'No enabled source in the configuration.'
    }
    return , $items.ToArray()
}

function Get-GwmItemContent {
    <# Reads the bytes of a planned item; returns $null when the file vanished, was replaced or changed (re-planned next run). #>
    param($Context, [System.Collections.IDictionary] $Item)
    if ($Item.kind -eq 'generated') { return , ([System.Text.Encoding]::UTF8.GetBytes([string]$Item.content)) }
    $collection = $Context.Configuration.collection
    try { $stream = Open-GwmSharedFile -Path $Item.filePath -RetryCount ([int]$collection.lockRetryCount) -RetryDelayMilliseconds ([int]$collection.lockRetryDelayMilliseconds) }
    catch [System.IO.FileNotFoundException], [System.IO.DirectoryNotFoundException] { return $null }
    try {
        if ($Item.kind -eq 'snapshot') {
            $content = Read-GwmFileRange -Stream $stream -Offset 0 -Count $stream.Length
            if ((Get-GwmSha256Hex -Bytes $content) -ne $Item.expectedSha256) { return $null }
            return , $content
        }
        $prefixLength = [int]$Item.prefixLength
        if ($stream.Length -lt [long]$Item.offsetEnd -or $stream.Length -lt $prefixLength) { return $null }
        $prefix = Read-GwmFileRange -Stream $stream -Offset 0 -Count $prefixLength
        if ((Get-GwmSha256Hex -Bytes $prefix) -ne $Item.prefixHash) { return $null }
        $data = Read-GwmFileRange -Stream $stream -Offset ([long]$Item.offsetStart) -Count ([long]$Item.offsetEnd - [long]$Item.offsetStart)
        if ($data.Length -ne ([long]$Item.offsetEnd - [long]$Item.offsetStart)) { return $null }
        $headerBytes = [int]$Item.headerBytes
        if ($headerBytes -le 0) { return , $data }
        $header = Read-GwmFileRange -Stream $stream -Offset 0 -Count $headerBytes
        $content = [byte[]]::new($headerBytes + $data.Length)
        [Array]::Copy($header, 0, $content, 0, $headerBytes)
        [Array]::Copy($data, 0, $content, $headerBytes, $data.Length)
        return , $content
    }
    finally { $stream.Dispose() }
}

function Test-GwmFatalUploadError {
    <# Authentication and authorization failures affect every upload: stop the run instead of failing item by item. #>
    param([System.Exception] $Exception)
    $current = $Exception
    while ($null -ne $current) {
        if ($current.Data.Contains('GwmStatusCode') -and [int]$current.Data['GwmStatusCode'] -in @(401, 403)) { return $true }
        if ($current.Message -match 'Token request|managed identity|client secret') { return $true }
        $current = $current.InnerException
    }
    return $false
}

function Invoke-GwmUploadItems {
    param($Context, [System.Collections.IDictionary] $Journal, [switch] $Replay)
    $failedKeys = [System.Collections.Generic.HashSet[string]]::new()
    $lastSave = [DateTime]::UtcNow
    $pendingSaves = 0
    foreach ($item in @($Journal.items)) {
        if ($item.status -ne 'Planned') {
            if ($item.status -ne 'Uploaded') { [void]$failedKeys.Add($item.key) }
            continue
        }
        if ($Context.UploadAborted) { $item.status = 'Skipped'; $item.error = 'uploads aborted'; $Context.Counts.segmentsSkipped++; continue }
        if ($failedKeys.Contains($item.key)) { $item.status = 'Skipped'; $item.error = 'a previous segment of the file was not uploaded'; $Context.Counts.segmentsSkipped++; continue }
        if ([DateTime]::UtcNow -gt $Context.Deadline) {
            $item.status = 'Skipped'; $item.error = 'agent.maxRunMinutes reached'; $Context.Counts.segmentsSkipped++
            [void]$failedKeys.Add($item.key)
            continue
        }
        try {
            $content = Get-GwmItemContent -Context $Context -Item $item
            if ($null -eq $content) {
                $item.status = 'Skipped'; $item.error = 'source changed or vanished before upload'
                $Context.Counts.segmentsSkipped++
                [void]$failedKeys.Add($item.key)
                Write-GwmLog -Level Warning -EventName 'SegmentSkipped' -Message "$($item.fileName) [$($item.offsetStart)-$($item.offsetEnd)] changed or vanished; it will be planned again."
                continue
            }
            $item.sha256 = Get-GwmSha256Hex -Bytes $content
            $item.byteCount = $content.Length
            $result = Publish-GwmObject -Target $Context.Target -RelativePath $item.rawPath -Content $content -CheckExisting:$Replay
            $item.status = 'Uploaded'
            $item.result = $result
            $item.uploadedUtc = Format-GwmUtc ([DateTime]::UtcNow)
            if ($result -eq 'AlreadyExists') { $Context.Counts.segmentsSkipped++ }
            else {
                $Context.Counts.segmentsUploaded++
                $Context.Counts.bytesUploaded += $content.Length
                if ($Context.Gateways.Contains($item.sourceName)) {
                    $Context.Gateways[$item.sourceName].segmentsUploaded++
                    $Context.Gateways[$item.sourceName].bytesUploaded += $content.Length
                }
            }
            if ($Replay) { $Context.Counts.segmentsReplayed++ }
            Write-GwmLog -Level Debug -EventName 'SegmentUploaded' -Message "$($item.rawPath) ($($content.Length) bytes, $result)"
        }
        catch {
            $item.status = 'Failed'
            $item.error = Protect-GwmText $_.Exception.Message
            [void]$failedKeys.Add($item.key)
            Add-GwmIssue -Context $Context -Level Error -Code 'UploadFailed' -Message "Upload of '$($item.fileName)' [$($item.offsetStart)-$($item.offsetEnd)] failed: $($_.Exception.Message)" -SourceName $item.sourceName -FileName $item.fileName
            if (Test-GwmFatalUploadError $_.Exception) { $Context.UploadAborted = $true }
        }
        $pendingSaves++
        if ($pendingSaves -ge 25 -or ([DateTime]::UtcNow - $lastSave).TotalSeconds -ge 30) {
            Save-GwmJournal -StateDirectory $Context.StateDirectory -Journal $Journal
            $pendingSaves = 0
            $lastSave = [DateTime]::UtcNow
        }
    }
    Save-GwmJournal -StateDirectory $Context.StateDirectory -Journal $Journal
}

function Complete-GwmJournal {
    <# Publishes the manifest (commit marker), then advances the checkpoint and deletes the journal. #>
    param($Context, [System.Collections.IDictionary] $Journal)
    $uploaded = @($Journal.items | Where-Object { $_.status -eq 'Uploaded' })
    if ($uploaded.Count -gt 0) {
        if (-not $Journal.manifestJson) {
            $document = New-GwmManifestDocument -RunId $Journal.runId -Environment $Context.Configuration.environment -Agent $Journal.agent -Items $uploaded
            $Journal.manifestJson = $document | ConvertTo-Json -Depth 16
            Save-GwmJournal -StateDirectory $Context.StateDirectory -Journal $Journal
        }
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes([string]$Journal.manifestJson)
        $null = Publish-GwmObject -Target $Context.Target -RelativePath $Journal.manifestPath -Content $bytes -CheckExisting
        $Context.ManifestPath = $Journal.manifestPath
        Write-GwmLog -Level Information -EventName 'ManifestPublished' -Message "$($Journal.manifestPath) ($($uploaded.Count) segments)"
    }
    $checkpoint = $Context.Checkpoint
    $commitTime = Format-GwmUtc ([DateTime]::UtcNow)
    foreach ($item in $uploaded) {
        if ($item.kind -eq 'segment') {
            $entry = $checkpoint.files[$item.key]
            if (-not $entry) {
                $entry = [ordered]@{
                    sourceName = $item.sourceName; logType = $item.logType; fileName = $item.fileName; filePath = $item.filePath
                    fingerprint = $item.fingerprint; prefixHash = $item.prefixHash; prefixLength = $item.prefixLength
                    committedOffset = 0L; headerBytes = 0L; observedSize = $item.sourceSizeBytes; sizeChangedUtc = $commitTime
                    pendingSinceUtc = $null; firstSeenUtc = $commitTime; lastSeenUtc = $commitTime; lastCommitUtc = $null; baseline = $false
                }
                $checkpoint.files[$item.key] = $entry
            }
            if ([long]$item.offsetEnd -gt [long]$entry.committedOffset) {
                $entry.committedOffset = [long]$item.offsetEnd
                $entry.pendingSinceUtc = $item.pendingAfterCommit
            }
            if ([long]$item.headerBytes -gt 0) { $entry.headerBytes = [long]$item.headerBytes }
            $entry.lastCommitUtc = $commitTime
        }
        else {
            $checkpoint.snapshots[$item.key] = [ordered]@{
                sha256      = $item.sha256
                contentHash = $item.contentHash
                size        = $item.byteCount
                uploadedUtc = $commitTime
                lastSeenUtc = $commitTime
            }
        }
    }
    Save-GwmCheckpoint -StateDirectory $Context.StateDirectory -Checkpoint $checkpoint
    Remove-GwmJournal -StateDirectory $Context.StateDirectory
}

function Invoke-GwmJournalReplay {
    <# Finishes a run interrupted after its journal was written: same byte ranges, same names, same manifest path. #>
    param($Context)
    $journal = Read-GwmJournal -StateDirectory $Context.StateDirectory -Issues $Context.Issues
    if (-not $journal) { return }
    $created = ConvertTo-GwmDateTime $journal.createdUtc
    if ($created -and ($Context.Now - $created).TotalDays -gt 7) {
        # A journal that cannot be completed for a week is set aside so collection can continue (ranges are re-planned).
        $path = Join-Path $Context.StateDirectory 'journal.json'
        $abandoned = Join-Path $Context.StateDirectory ('journal.abandoned-{0}.json' -f $Context.Now.ToString('yyyyMMddHHmmss'))
        [System.IO.File]::Move($path, $abandoned)
        Add-GwmIssue -Context $Context -Level Error -Code 'JournalAbandoned' -Message "The unfinished run $($journal.runId) could not be completed for 7 days; its journal was moved to '$abandoned'."
        return
    }
    $journal.items = @($journal.items)
    Write-GwmLog -Level Warning -EventName 'JournalReplay' -Message "Resuming the unfinished run $($journal.runId) ($($journal.items.Count) items)."
    if (-not $journal.manifestJson) {
        Invoke-GwmUploadItems -Context $Context -Journal $journal -Replay
    }
    Complete-GwmJournal -Context $Context -Journal $journal
}

function Send-GwmOutbox {
    param($Context)
    foreach ($entry in @(Get-GwmOutboxItem -StateDirectory $Context.StateDirectory)) {
        try {
            $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($entry.Json)
            $null = Publish-GwmObject -Target $Context.Target -RelativePath $entry.RelativePath -Content $bytes -CheckExisting
            Remove-Item -LiteralPath $entry.File -Force -ErrorAction SilentlyContinue
        }
        catch {
            Write-GwmLog -Level Warning -EventName 'OutboxPending' -Message "Outbox document '$($entry.RelativePath)' still cannot be uploaded: $($_.Exception.Message)"
            break
        }
    }
}

function Get-GwmRunStatus {
    param($Context, [AllowEmptyCollection()][object[]] $Items)
    if ($Context.Fatal) { return 'Failed' }
    if ($Context.Counts.sourcesScanned -eq 0) { return 'Failed' }
    $failed = @($Items | Where-Object { $_.status -in @('Failed') }).Count
    $uploaded = @($Items | Where-Object { $_.status -eq 'Uploaded' }).Count
    if ($failed -gt 0 -and $uploaded -eq 0) { return 'Failed' }
    if ($failed -gt 0 -or @($Context.Issues | Where-Object Level -eq 'Error').Count -gt 0) { return 'PartiallySucceeded' }
    return 'Succeeded'
}

function Send-GwmRunTelemetry {
    <# Heartbeat + run summary; kept in the local outbox when it cannot be uploaded. #>
    param($Context, [string] $Status)
    $Context.Counts.errors = @($Context.Issues | Where-Object Level -eq 'Error').Count
    $Context.Counts.warnings = @($Context.Issues | Where-Object Level -eq 'Warning').Count
    $ended = [DateTime]::UtcNow
    $document = New-GwmTelemetryDocument -RunId $Context.RunId -Environment $Context.Configuration.environment -Agent $Context.Agent `
        -StartedUtc $Context.StartedUtc -EndedUtc $ended -Status $Status -Trigger $Context.Trigger `
        -AuthMode $Context.Configuration.authentication.mode -TargetType $Context.Configuration.target.type `
        -ConfigHash (Get-GwmConfigurationHash $Context.Configuration) -ManifestPath $Context.ManifestPath -Counts $Context.Counts `
        -Gateways @($Context.Gateways.Values) -Issues $Context.Issues.ToArray()
    $json = $document | ConvertTo-Json -Depth 16
    $path = Get-GwmDocumentPath -Kind telemetry -Environment $Context.Configuration.environment -ServerName $Context.Server.PartitionName -Date $Context.Now -RunId $Context.RunId
    $Context.TelemetryPath = $path
    try {
        if (-not $Context.Target) { throw 'no upload target' }
        $null = Publish-GwmObject -Target $Context.Target -RelativePath $path -Content ([System.Text.UTF8Encoding]::new($false).GetBytes($json))
    }
    catch {
        Write-GwmLog -Level Warning -EventName 'TelemetryDeferred' -Message "Run telemetry kept in the outbox: $($_.Exception.Message)"
        try { Add-GwmOutboxItem -StateDirectory $Context.StateDirectory -RelativePath $path -Json $json -MaxFiles ([int]$Context.Configuration.agent.outboxMaxFiles) } catch { $null = $_ }
    }
    return $document
}
