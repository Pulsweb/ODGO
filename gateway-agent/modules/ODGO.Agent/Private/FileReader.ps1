# Shared-read file access: files being written by the gateway are opened with FileShare.ReadWrite | Delete.

function Open-GwmSharedFile {
    <# Opens a file for reading without blocking the writer. Sharing violations are retried; missing files are rethrown. #>
    [OutputType([System.IO.FileStream])]
    param(
        [Parameter(Mandatory)][string] $Path,
        [int] $RetryCount = 3,
        [int] $RetryDelayMilliseconds = 500
    )
    $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    for ($attempt = 0; ; $attempt++) {
        try {
            return [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share, 65536, [System.IO.FileOptions]::SequentialScan)
        }
        catch [System.IO.FileNotFoundException], [System.IO.DirectoryNotFoundException], [System.UnauthorizedAccessException] {
            throw
        }
        catch [System.IO.IOException] {
            if ($attempt -ge $RetryCount) { throw }
            Start-Sleep -Milliseconds $RetryDelayMilliseconds
        }
    }
}

function Read-GwmFileRange {
    <# Reads up to Count bytes at Offset. Returns a byte[] (possibly shorter when the file is shorter). #>
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory)][System.IO.Stream] $Stream,
        [long] $Offset,
        [long] $Count
    )
    if ($Count -le 0) { return , ([byte[]]::new(0)) }
    if ($Count -gt [int]::MaxValue - 64) { throw "Range of $Count bytes is too large." }
    $buffer = [byte[]]::new([int]$Count)
    $null = $Stream.Seek($Offset, [System.IO.SeekOrigin]::Begin)
    $total = 0
    while ($total -lt $Count) {
        $read = $Stream.Read($buffer, $total, [int]$Count - $total)
        if ($read -le 0) { break }
        $total += $read
    }
    if ($total -lt $Count) { [Array]::Resize([ref]$buffer, $total) }
    return , $buffer
}

function Get-GwmFileSnapshotInfo {
    <# Accurate size and timestamps of a file (the size comes from the open handle, not from the directory entry). #>
    param([Parameter(Mandatory)][System.IO.FileStream] $Stream, [Parameter(Mandatory)][string] $Path)
    [pscustomobject]@{
        Length           = $Stream.Length
        LastWriteTimeUtc = [System.IO.File]::GetLastWriteTimeUtc($Path)
        CreationTimeUtc  = [System.IO.File]::GetCreationTimeUtc($Path)
    }
}

function Get-GwmTextEncodingIssue {
    <# Returns a description when the file uses an encoding the segmenter cannot cut safely (UTF-16/UTF-32). #>
    param([byte[]] $Prefix)
    if ($null -eq $Prefix -or $Prefix.Length -lt 2) { return $null }
    if (($Prefix[0] -eq 0xFF -and $Prefix[1] -eq 0xFE) -or ($Prefix[0] -eq 0xFE -and $Prefix[1] -eq 0xFF)) { return 'UTF-16/UTF-32 byte order mark' }
    return $null
}
