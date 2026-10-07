# Record-boundary detection and segment planning. Segments always end on a record boundary, so the processing layer
# never sees a partial record; a CSV segment that does not start at offset 0 is prefixed with the file's header line.

$script:GwmNewLine = [byte]10
$script:GwmQuote = [byte]34

function Find-GwmLineCut {
    <# Index just after the last LF in Buffer[0..Length), or -1. #>
    [OutputType([int])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]] $Buffer, [int] $Length = -1)
    if ($Length -lt 0) { $Length = $Buffer.Length }
    if ($Length -le 0) { return -1 }
    $index = [Array]::LastIndexOf($Buffer, $script:GwmNewLine, $Length - 1, $Length)
    if ($index -lt 0) { return -1 }
    return $index + 1
}

function Find-GwmTraceCut {
    <# Start of the last line beginning with 'DM.' (a trace record header) after position 0, or -1.
       Everything before it is made of complete records (header line + continuation lines). #>
    [OutputType([int])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]] $Buffer, [int] $Length = -1)
    if ($Length -lt 0) { $Length = $Buffer.Length }
    $position = $Length - 1
    while ($position -ge 0) {
        $index = [Array]::LastIndexOf($Buffer, $script:GwmNewLine, $position, $position + 1)
        if ($index -lt 0) { return -1 }
        $start = $index + 1
        if ($start + 2 -lt $Length -and $Buffer[$start] -eq 68 -and $Buffer[$start + 1] -eq 77 -and $Buffer[$start + 2] -eq 46) {
            return $start
        }
        $position = $index - 1
    }
    return -1
}

function Get-GwmQuoteCount {
    <# Number of '"' bytes in Buffer[Offset..Offset+Count). Latin-1 maps bytes 1:1 to chars, so string operations stay native. #>
    [OutputType([long])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]] $Buffer, [int] $Offset = 0, [int] $Count = -1)
    if ($Count -lt 0) { $Count = $Buffer.Length - $Offset }
    $total = 0L
    $chunk = 4MB
    $end = $Offset + $Count
    for ($position = $Offset; $position -lt $end; $position += $chunk) {
        $length = [Math]::Min($chunk, $end - $position)
        $text = [System.Text.Encoding]::Latin1.GetString($Buffer, $position, $length)
        $total += $text.Length - $text.Replace('"', '').Length
    }
    return $total
}

function Find-GwmCsvCut {
    <# Index just after the last LF that is outside double quotes (quoted CSV fields may contain line breaks), or -1.
       Buffer[0] must be the start of a record. Scans backwards at most MaxLines lines. #>
    [OutputType([int])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]] $Buffer, [int] $Length = -1, [int] $MaxLines = 10000)
    if ($Length -lt 0) { $Length = $Buffer.Length }
    if ($Length -le 0) { return -1 }
    $newline = [Array]::LastIndexOf($Buffer, $script:GwmNewLine, $Length - 1, $Length)
    if ($newline -lt 0) { return -1 }
    $parity = (Get-GwmQuoteCount -Buffer $Buffer -Offset 0 -Count $newline) % 2
    $lines = 0
    while ($parity -ne 0) {
        if ($newline -le 0 -or ++$lines -gt $MaxLines) { return -1 }
        $previous = [Array]::LastIndexOf($Buffer, $script:GwmNewLine, $newline - 1, $newline)
        if ($previous -lt 0) { return -1 }
        $parity = ($parity + (Get-GwmQuoteCount -Buffer $Buffer -Offset $previous -Count ($newline - $previous))) % 2
        $newline = $previous
    }
    return $newline + 1
}

function Get-GwmCutPoint {
    <# Releasable length of a window that starts on a record boundary. #>
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]] $Buffer,
        [Parameter(Mandatory)][ValidateSet('trace', 'jsonl', 'csv')][string] $Format,
        [bool] $IsTail,
        [bool] $Settled,
        [bool] $Closed,
        [bool] $Force
    )
    $length = $Buffer.Length
    $cut = switch ($Format) {
        'trace' { Find-GwmTraceCut -Buffer $Buffer -Length $length }
        'jsonl' { Find-GwmLineCut -Buffer $Buffer -Length $length }
        'csv' {
            $csvCut = Find-GwmCsvCut -Buffer $Buffer -Length $length
            # Unbalanced quotes (malformed row): fall back to the last line break once the data is old enough.
            if ($csvCut -lt 0 -and ($Force -or $Settled -or -not $IsTail)) { $csvCut = Find-GwmLineCut -Buffer $Buffer -Length $length }
            $csvCut
        }
    }
    if ($IsTail -and $Settled) {
        # The writer is idle: the last complete line also ends the last record.
        $lineCut = Find-GwmLineCut -Buffer $Buffer -Length $length
        if ($lineCut -gt $cut) { $cut = $lineCut }
        # A closed file may end without a final line break.
        if ($Closed -and $length -gt 0 -and $Buffer[$length - 1] -ne $script:GwmNewLine) { $cut = $length }
    }
    return [int]$cut
}

function Get-GwmCsvHeaderLength {
    <# Length of the header line (including its line break) of a CSV file, from its first bytes; 0 when incomplete. #>
    [OutputType([int])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]] $Prefix)
    $index = [Array]::IndexOf($Prefix, $script:GwmNewLine)
    if ($index -lt 0) { return 0 }
    return $index + 1
}

function Find-GwmForwardBoundary {
    <# For records larger than a window: absolute offset just after the next boundary at or after Start, or -1. #>
    [OutputType([long])]
    param(
        [Parameter(Mandatory)][System.IO.Stream] $Stream,
        [long] $Start,
        [long] $Limit,
        [ValidateSet('trace', 'jsonl', 'csv')][string] $Format
    )
    $chunkSize = 4MB
    $position = $Start
    while ($position -lt $Limit) {
        $chunk = Read-GwmFileRange -Stream $Stream -Offset $position -Count ([Math]::Min($chunkSize, $Limit - $position))
        if ($chunk.Length -eq 0) { break }
        $from = 0
        while ($true) {
            $index = [Array]::IndexOf($chunk, $script:GwmNewLine, $from)
            if ($index -lt 0) { break }
            if ($Format -ne 'trace') { return $position + $index + 1 }
            # trace: the boundary is the start of a following 'DM.' line
            $next = $index + 1
            if ($next + 2 -lt $chunk.Length) {
                if ($chunk[$next] -eq 68 -and $chunk[$next + 1] -eq 77 -and $chunk[$next + 2] -eq 46) { return $position + $next }
            }
            elseif ($position + $next + 3 -le $Limit) {
                $peek = Read-GwmFileRange -Stream $Stream -Offset ($position + $next) -Count 3
                if ($peek.Length -eq 3 -and $peek[0] -eq 68 -and $peek[1] -eq 77 -and $peek[2] -eq 46) { return $position + $next }
            }
            $from = $index + 1
        }
        $position += $chunk.Length
    }
    return -1
}

function Get-GwmSegmentPlan {
    <#
    Plans record-aligned byte ranges [OffsetStart, OffsetEnd) for the uncommitted part of an incremental file.
    Rules: windows of at most MaxSegmentBytes (header included); the tail is released only when it reaches
    MinSegmentBytes, when Force is set (pending data older than MaxSegmentAgeMinutes) or when the file is settled.
    #>
    param(
        [Parameter(Mandatory)][System.IO.Stream] $Stream,
        [Parameter(Mandatory)][ValidateSet('trace', 'jsonl', 'csv')][string] $Format,
        [long] $CommittedOffset,
        [long] $Size,
        [int] $HeaderBytes = 0,
        [bool] $Settled,
        [bool] $Closed,
        [bool] $Force,
        [long] $MinSegmentBytes = 262144,
        [long] $MaxSegmentBytes = 33554432,
        [long] $ByteBudget = [long]::MaxValue,
        [int] $SegmentBudget = [int]::MaxValue,
        [System.Collections.Generic.List[object]] $Warnings
    )
    $segments = [System.Collections.Generic.List[object]]::new()
    $position = $CommittedOffset
    $budget = $ByteBudget
    while ($position -lt $Size -and $segments.Count -lt $SegmentBudget -and $budget -gt 0) {
        $header = if ($Format -eq 'csv' -and $position -gt 0) { $HeaderBytes } else { 0 }
        $maxData = [Math]::Max(4096, $MaxSegmentBytes - $header)
        $windowEnd = [Math]::Min($Size, $position + $maxData)
        $buffer = Read-GwmFileRange -Stream $Stream -Offset $position -Count ($windowEnd - $position)
        $isTail = ($position + $buffer.Length) -ge $Size -or $buffer.Length -lt ($windowEnd - $position)
        $cut = Get-GwmCutPoint -Buffer $buffer -Format $Format -IsTail $isTail -Settled $Settled -Closed $Closed -Force $Force
        $end = $position + $cut
        if ($cut -le 0) {
            if ($isTail) { break }
            # A single record is larger than the window: emit it alone.
            $limit = [Math]::Min($Size, $position + 8 * $MaxSegmentBytes)
            $end = Find-GwmForwardBoundary -Stream $Stream -Start ($windowEnd - 1) -Limit $limit -Format $Format
            if ($end -le $position) {
                $end = $windowEnd
                if ($null -ne $Warnings) { $Warnings.Add("No record boundary within $($limit - $position) bytes at offset $position; the record is split.") }
            }
            elseif ($null -ne $Warnings) { $Warnings.Add("Oversized record of $($end - $position) bytes at offset $position uploaded as its own segment.") }
        }
        $length = $end - $position
        if ($isTail -and -not $Force -and -not $Settled -and $length -lt $MinSegmentBytes) { break }
        $segments.Add([pscustomobject]@{ OffsetStart = $position; OffsetEnd = $end; HeaderBytes = $header })
        $budget -= ($length + $header)
        $position = $end
        if ($isTail) { break }
    }
    return , $segments.ToArray()
}
