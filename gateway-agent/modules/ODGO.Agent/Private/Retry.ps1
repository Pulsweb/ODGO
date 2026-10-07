# Retry with exponential back-off, jitter and Retry-After support.

$script:GwmTransientStatusCodes = @(408, 429, 500, 502, 503, 504)

function New-GwmException {
    <# Creates an exception carrying HTTP/transient metadata in Exception.Data (keys prefixed with Gwm). #>
    param(
        [Parameter(Mandatory)][string] $Message,
        [int] $StatusCode = 0,
        [bool] $Transient = $false,
        [AllowNull()] $RetryAfterSeconds = $null,
        [AllowNull()][string] $ErrorCode = $null,
        [AllowNull()][System.Exception] $InnerException = $null
    )
    $exception = if ($InnerException) { [System.Exception]::new($Message, $InnerException) } else { [System.Exception]::new($Message) }
    $exception.Data['GwmStatusCode'] = $StatusCode
    $exception.Data['GwmTransient'] = $Transient
    $exception.Data['GwmRetryAfterSeconds'] = $RetryAfterSeconds
    $exception.Data['GwmErrorCode'] = $ErrorCode
    return $exception
}

function Test-GwmTransientError {
    [OutputType([bool])]
    param([System.Exception] $Exception)
    $current = $Exception
    $depth = 0
    while ($null -ne $current -and $depth -lt 8) {
        if ($current.Data.Contains('GwmTransient')) { return [bool]$current.Data['GwmTransient'] }
        $isNetworkError = $current -is [System.Net.Http.HttpRequestException] -or
            $current -is [System.Threading.Tasks.TaskCanceledException] -or
            $current -is [System.TimeoutException] -or
            $current -is [System.Net.Sockets.SocketException]
        $isIoError = ($current -is [System.IO.IOException]) -and
            ($current -isnot [System.IO.FileNotFoundException]) -and
            ($current -isnot [System.IO.DirectoryNotFoundException])
        if ($isNetworkError -or $isIoError) {
            return $true
        }
        $current = $current.InnerException
        $depth++
    }
    return $false
}

function Get-GwmRetryDelayMilliseconds {
    [OutputType([int])]
    param([int] $Attempt, [int] $BaseDelaySeconds = 2, [int] $MaxDelaySeconds = 60, [AllowNull()] $RetryAfterSeconds = $null)
    $exponential = [Math]::Min([double]$MaxDelaySeconds, $BaseDelaySeconds * [Math]::Pow(2, $Attempt))
    $jittered = $exponential * (0.5 + (Get-Random -Minimum 0.0 -Maximum 0.5))
    if ($null -ne $RetryAfterSeconds -and [double]$RetryAfterSeconds -gt 0) {
        $jittered = [Math]::Max($jittered, [Math]::Min([double]$RetryAfterSeconds, 300))
    }
    return [int][Math]::Round($jittered * 1000)
}

function Invoke-GwmWithRetry {
    <# Runs a script block, retrying transient failures (HTTP 408/429/5xx, network errors). Non-transient errors are rethrown immediately. #>
    param(
        [Parameter(Mandatory)][scriptblock] $ScriptBlock,
        [string] $Operation = 'operation',
        [int] $MaxRetries = 5,
        [int] $BaseDelaySeconds = 2,
        [int] $MaxDelaySeconds = 60
    )
    $attempt = 0
    while ($true) {
        try {
            return & $ScriptBlock
        }
        catch {
            $exception = $_.Exception
            if (-not (Test-GwmTransientError $exception) -or $attempt -ge $MaxRetries) { throw }
            $retryAfter = $null
            $inspect = $exception
            while ($null -ne $inspect -and $null -eq $retryAfter) {
                if ($inspect.Data.Contains('GwmRetryAfterSeconds')) { $retryAfter = $inspect.Data['GwmRetryAfterSeconds'] }
                $inspect = $inspect.InnerException
            }
            $delay = Get-GwmRetryDelayMilliseconds -Attempt $attempt -BaseDelaySeconds $BaseDelaySeconds -MaxDelaySeconds $MaxDelaySeconds -RetryAfterSeconds $retryAfter
            Write-GwmLog -Level Warning -EventName 'Retry' -Message "$Operation failed (attempt $($attempt + 1) of $($MaxRetries + 1)); retrying in $([Math]::Round($delay / 1000.0, 1)) s: $($exception.Message)"
            Start-Sleep -Milliseconds $delay
            $attempt++
        }
    }
}
