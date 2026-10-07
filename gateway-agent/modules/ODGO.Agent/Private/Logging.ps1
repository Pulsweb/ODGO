# Structured JSONL logging with secret redaction. Logging failures never stop a run.

$script:GwmLogLevels = @{ Debug = 0; Information = 1; Warning = 2; Error = 3 }
$script:GwmRedactionRules = @(
    # Authorization headers (Bearer / Basic / SharedKey)
    @{ Pattern = '(?i)(authorization["'']?\s*[:=]\s*["'']?)(bearer|basic|sharedkey)\s+[^\s"'',;]+'; Replacement = '$1$2 ***' }
    # OAuth parameters and common secret names in query strings, form bodies, JSON and connection strings
    @{ Pattern = '(?i)\b(client_assertion|access_token|refresh_token|id_token|client_secret|password|pwd|accountkey|sharedaccesskey|sig)(["'']?\s*[:=]\s*["'']?)[^"''&\s,;}]+'; Replacement = '$1$2***' }
    # Any JSON Web Token
    @{ Pattern = 'eyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]*'; Replacement = '***' }
)

function Protect-GwmText {
    <# Removes tokens, assertions and secrets from a text before it is logged or uploaded as telemetry. #>
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string] $Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $result = $Text
    foreach ($rule in $script:GwmRedactionRules) { $result = [regex]::Replace($result, $rule.Pattern, $rule.Replacement) }
    return $result
}

function Initialize-GwmLog {
    param(
        [AllowNull()][string] $Directory,
        [ValidateSet('Debug', 'Information', 'Warning', 'Error')][string] $Level = 'Information',
        [string] $RunId,
        [switch] $Console
    )
    $script:GwmLog = [pscustomobject]@{
        Directory = $null
        Level     = $Level
        RunId     = $RunId
        Console   = [bool]$Console
    }
    if ([string]::IsNullOrWhiteSpace($Directory)) { return }
    try {
        [void][System.IO.Directory]::CreateDirectory($Directory)
        $script:GwmLog.Directory = $Directory
    }
    catch {
        if ($Console) { Write-Warning "Cannot create log directory '$Directory': $($_.Exception.Message)" }
    }
}

function Write-GwmLog {
    param(
        [ValidateSet('Debug', 'Information', 'Warning', 'Error')][string] $Level = 'Information',
        [Parameter(Mandatory)][string] $EventName,
        [string] $Message = '',
        [System.Collections.IDictionary] $Data
    )
    $log = $script:GwmLog
    if ($null -eq $log) { return }
    if ($script:GwmLogLevels[$Level] -lt $script:GwmLogLevels[$log.Level]) { return }
    $now = [DateTime]::UtcNow
    $entry = [ordered]@{
        timestamp = $now.ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [System.Globalization.CultureInfo]::InvariantCulture)
        level     = $Level
        runId     = $log.RunId
        event     = $EventName
        message   = $Message
    }
    if ($Data) { $entry.data = $Data }
    $line = $null
    try { $line = Protect-GwmText ($entry | ConvertTo-Json -Depth 6 -Compress -WarningAction SilentlyContinue) }
    catch { $line = Protect-GwmText ("{""timestamp"":""$($entry.timestamp)"",""level"":""$Level"",""event"":""$EventName"",""message"":""unserializable log entry""}") }
    if ($log.Directory) {
        $path = Join-Path $log.Directory ('agent-{0}.jsonl' -f $now.ToString('yyyyMMdd', [System.Globalization.CultureInfo]::InvariantCulture))
        try { [System.IO.File]::AppendAllText($path, $line + "`n", [System.Text.UTF8Encoding]::new($false)) } catch { $null = $_ }
    }
    if ($log.Console) {
        $text = '{0} {1,-11} {2} {3}' -f $now.ToString('HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture), $Level, $EventName, (Protect-GwmText $Message)
        switch ($Level) {
            'Error' { Write-Host $text -ForegroundColor Red }
            'Warning' { Write-Host $text -ForegroundColor Yellow }
            'Debug' { Write-Host $text -ForegroundColor DarkGray }
            default { Write-Host $text }
        }
    }
}

function Remove-GwmOldLog {
    param([AllowNull()][string] $Directory, [int] $RetentionDays)
    if ([string]::IsNullOrWhiteSpace($Directory) -or -not (Test-Path -LiteralPath $Directory)) { return 0 }
    $limit = [DateTime]::UtcNow.AddDays(-$RetentionDays)
    $removed = 0
    foreach ($file in Get-ChildItem -LiteralPath $Directory -Filter 'agent-*.jsonl' -File -ErrorAction SilentlyContinue) {
        if ($file.LastWriteTimeUtc -lt $limit) {
            try { Remove-Item -LiteralPath $file.FullName -Force; $removed++ } catch { $null = $_ }
        }
    }
    return $removed
}
