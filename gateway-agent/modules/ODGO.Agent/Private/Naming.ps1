# Deterministic names, identifiers and landing paths (must stay compatible with RAW_PATH_RE in nb_gwmon_lib).

function ConvertTo-GwmPartitionValue {
    <# Lower-case, characters outside [a-z0-9._-] replaced by '-', trimmed to 63 characters. #>
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string] $Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $text = $Value.Trim().ToLowerInvariant() -replace '[^a-z0-9._-]+', '-'
    $text = $text.Trim('-', '.', '_')
    if ($text.Length -gt 63) { $text = $text.Substring(0, 63).TrimEnd('-', '.', '_') }
    return $text
}

function ConvertTo-GwmFileNamePart {
    [OutputType([string])]
    param([AllowNull()][string] $Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return 'file' }
    $text = ($Value -replace '[^A-Za-z0-9._-]+', '-').Trim('-')
    if ($text.Length -gt 120) { $text = $text.Substring(0, 120) }
    if ($text -eq '') { return 'file' }
    return $text
}

function Get-GwmSha256Hex {
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]] $Bytes, [int] $Offset = 0, [int] $Count = -1)
    if ($Count -lt 0) { $Count = $Bytes.Length - $Offset }
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $algorithm.ComputeHash($Bytes, $Offset, $Count) } finally { $algorithm.Dispose() }
    return ([System.BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
}

function Get-GwmStringSha256Hex {
    [OutputType([string])]
    param([AllowEmptyString()][string] $Text)
    return Get-GwmSha256Hex -Bytes ([System.Text.Encoding]::UTF8.GetBytes($Text))
}

function Format-GwmUtc {
    [OutputType([string])]
    param([datetime] $Value)
    $utc = if ($Value.Kind -eq [DateTimeKind]::Local) { $Value.ToUniversalTime() } else { [DateTime]::SpecifyKind($Value, [DateTimeKind]::Utc) }
    return $utc.ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-GwmDateTime {
    <# Accepts DateTime (any kind) or ISO-8601 text and returns a UTC DateTime, or $null. #>
    param([AllowNull()] $Value)
    if ($null -eq $Value -or ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value))) { return $null }
    if ($Value -is [datetime]) {
        if ($Value.Kind -eq [DateTimeKind]::Local) { return $Value.ToUniversalTime() }
        return [DateTime]::SpecifyKind($Value, [DateTimeKind]::Utc)
    }
    if ($Value -is [DateTimeOffset]) { return $Value.UtcDateTime }
    $parsed = [DateTime]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
    if ([DateTime]::TryParse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
        return [DateTime]::SpecifyKind($parsed, [DateTimeKind]::Utc)
    }
    return $null
}

function Get-GwmServerIdFromMachineGuid {
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $MachineGuid)
    return (Get-GwmStringSha256Hex $MachineGuid.Trim().ToLowerInvariant()).Substring(0, 16)
}

function Get-GwmSegmentId {
    <# SHA-256 over the identity of a byte range: retried uploads of the same range keep the same id. #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string] $ServerId,
        [Parameter(Mandatory)][string] $ServerName,
        [Parameter(Mandatory)][string] $GatewayId,
        [Parameter(Mandatory)][string] $LogType,
        [Parameter(Mandatory)][string] $SourceFingerprint,
        [long] $OffsetStart,
        [long] $OffsetEnd
    )
    return Get-GwmStringSha256Hex (@($ServerId, $ServerName, $GatewayId, $LogType, $SourceFingerprint, $OffsetStart, $OffsetEnd) -join '|')
}

function Get-GwmSegmentFileName {
    <# <base>__<fingerprint 12 hex>__<start 12 digits>-<end 12 digits><ext> (incremental) or <base>__<sha 12 hex><ext> (snapshot). #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string] $SourceFileName,
        [Parameter(Mandatory)][string] $Fingerprint,
        [long] $OffsetStart = 0,
        [long] $OffsetEnd = 0,
        [switch] $Snapshot
    )
    $extension = [System.IO.Path]::GetExtension($SourceFileName)
    if ($extension -notmatch '^\.[A-Za-z0-9]{1,10}$') { $extension = '' }
    $base = ConvertTo-GwmFileNamePart ([System.IO.Path]::GetFileNameWithoutExtension($SourceFileName))
    $short = $Fingerprint.Substring(0, 12).ToLowerInvariant()
    if ($Snapshot) { return '{0}__{1}{2}' -f $base, $short, $extension }
    return '{0}__{1}__{2:D12}-{3:D12}{4}' -f $base, $short, $OffsetStart, $OffsetEnd, $extension
}

function Get-GwmDatePartition {
    [OutputType([string])]
    param([datetime] $Date)
    $utc = ConvertTo-GwmDateTime $Date
    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    return 'year={0}/month={1}/day={2}' -f $utc.ToString('yyyy', $invariant), $utc.ToString('MM', $invariant), $utc.ToString('dd', $invariant)
}

function Get-GwmRawPath {
    <# Relative path below the landing root: raw/environment=/cluster=/gateway=/server=/log-type=/year=/month=/day=/<file>. #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string] $Environment,
        [Parameter(Mandatory)][string] $ClusterId,
        [Parameter(Mandatory)][string] $GatewayId,
        [Parameter(Mandatory)][string] $ServerName,
        [Parameter(Mandatory)][string] $LogType,
        [Parameter(Mandatory)][datetime] $Date,
        [Parameter(Mandatory)][string] $FileName
    )
    $parts = [ordered]@{
        environment = ConvertTo-GwmPartitionValue $Environment
        cluster     = ConvertTo-GwmPartitionValue $ClusterId
        gateway     = ConvertTo-GwmPartitionValue $GatewayId
        server      = ConvertTo-GwmPartitionValue $ServerName
        'log-type'  = ConvertTo-GwmPartitionValue $LogType
    }
    foreach ($key in $parts.Keys) { if ($parts[$key] -eq '') { throw "Cannot build a landing path: '$key' is empty." } }
    if ($FileName -notmatch '^[A-Za-z0-9._-]+$') { throw "Invalid segment file name '$FileName'." }
    $prefix = ($parts.Keys | ForEach-Object { '{0}={1}' -f $_, $parts[$_] }) -join '/'
    return 'raw/{0}/{1}/{2}' -f $prefix, (Get-GwmDatePartition $Date), $FileName
}

function Get-GwmDocumentPath {
    <# manifests/... or telemetry/... path for a run document. #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidateSet('manifests', 'telemetry')][string] $Kind,
        [Parameter(Mandatory)][string] $Environment,
        [Parameter(Mandatory)][string] $ServerName,
        [Parameter(Mandatory)][datetime] $Date,
        [Parameter(Mandatory)][string] $RunId
    )
    $suffix = if ($Kind -eq 'manifests') { 'manifest.json' } else { 'run.json' }
    return '{0}/environment={1}/server={2}/{3}/{4}.{5}' -f $Kind, (ConvertTo-GwmPartitionValue $Environment), (ConvertTo-GwmPartitionValue $ServerName), (Get-GwmDatePartition $Date), $RunId.ToLowerInvariant(), $suffix
}
