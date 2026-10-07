# Thin HTTP wrapper around Invoke-WebRequest: no exceptions for HTTP status codes, proxy support, safe URIs in messages.

function Get-GwmSafeUri {
    <# Strips query strings (which may carry SAS-like secrets) from a URI before it is logged. #>
    param([string] $Uri)
    $index = $Uri.IndexOf('?')
    if ($index -ge 0) { return $Uri.Substring(0, $index) }
    return $Uri
}

function Get-GwmHeaderValue {
    param($Headers, [string] $Name)
    if ($null -eq $Headers) { return $null }
    foreach ($key in @($Headers.Keys)) {
        if ($key -ieq $Name) {
            $value = $Headers[$key]
            if ($value -is [System.Collections.IEnumerable] -and $value -isnot [string]) { return (@($value) -join ',') }
            return [string]$value
        }
    }
    return $null
}

function ConvertTo-GwmRetryAfterSeconds {
    param([AllowNull()][string] $Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $seconds = 0
    if ([int]::TryParse($Value.Trim(), [ref]$seconds)) { return $seconds }
    $date = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse($Value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$date)) {
        return [Math]::Max(0, [int]($date - [DateTimeOffset]::UtcNow).TotalSeconds)
    }
    return $null
}

function Invoke-GwmHttpRequest {
    <# Sends one HTTP request. Returns StatusCode/Headers/Content; throws only for network-level failures (transient). #>
    param(
        [Parameter(Mandatory)][string] $Method,
        [Parameter(Mandatory)][string] $Uri,
        [hashtable] $Headers = @{},
        [AllowNull()] $Body = $null,
        [string] $ContentType,
        [int] $TimeoutSeconds = 100,
        [AllowNull()][System.Collections.IDictionary] $Network = $null,
        [switch] $NoProxy
    )
    $parameters = @{
        Method             = $Method
        Uri                = $Uri
        Headers            = $Headers
        TimeoutSec         = $TimeoutSeconds
        SkipHttpErrorCheck = $true
        ErrorAction        = 'Stop'
    }
    if ($null -ne $Body) { $parameters.Body = $Body }
    if ($ContentType) { $parameters.ContentType = $ContentType }
    if ($NoProxy) { $parameters.NoProxy = $true }
    elseif ($Network -and $Network.proxyUrl) {
        $parameters.Proxy = $Network.proxyUrl
        if ($Network.proxyUseDefaultCredentials) { $parameters.ProxyUseDefaultCredentials = $true }
    }
    try {
        $response = Invoke-WebRequest @parameters -Verbose:$false -Debug:$false
    }
    catch {
        throw (New-GwmException -Message "$Method $(Get-GwmSafeUri $Uri) failed: $($_.Exception.Message)" -Transient $true -InnerException $_.Exception)
    }
    $result = [pscustomobject]@{
        StatusCode = [int]$response.StatusCode
        Headers    = $response.Headers
        Content    = $response.Content
    }
    # Rendered as "HTTP <status>" when passed to a command: module logging would otherwise record the content (tokens).
    $result.PSObject.Methods.Add([System.Management.Automation.PSScriptMethod]::new('ToString', { 'HTTP {0}' -f $this.StatusCode }))
    return $result
}

function Get-GwmResponseErrorCode {
    param($Response)
    $code = Get-GwmHeaderValue $Response.Headers 'x-ms-error-code'
    if ($code) { return $code }
    $content = $Response.Content
    if ($content -is [byte[]]) { $content = [System.Text.Encoding]::UTF8.GetString($content) }
    if ($content -is [string] -and $content.TrimStart().StartsWith('{')) {
        try {
            $json = $content | ConvertFrom-Json -Depth 8
            if ($json.PSObject.Properties['error']) {
                $errorValue = $json.error
                if ($errorValue -is [string]) { return $errorValue }
                if ($errorValue.PSObject.Properties['code']) { return [string]$errorValue.code }
            }
        }
        catch { $null = $_ }
    }
    return $null
}

function Get-GwmResponseErrorMessage {
    param($Response)
    $content = $Response.Content
    if ($content -is [byte[]]) { $content = [System.Text.Encoding]::UTF8.GetString($content) }
    if ($content -isnot [string] -or [string]::IsNullOrWhiteSpace($content)) { return '' }
    $text = $content
    try {
        $json = $content | ConvertFrom-Json -Depth 8
        if ($json.PSObject.Properties['error_description']) { $text = [string]$json.error_description }
        elseif ($json.PSObject.Properties['error'] -and $json.error -isnot [string] -and $json.error.PSObject.Properties['message']) { $text = [string]$json.error.message }
    }
    catch { $null = $_ }
    $text = Protect-GwmText $text
    if ($text.Length -gt 600) { $text = $text.Substring(0, 600) + '...' }
    return $text
}

function Assert-GwmHttpSuccess {
    <# Throws a Gwm exception (transient for 408/429/5xx) unless the status code is 2xx or explicitly allowed. #>
    param($Response, [string] $Operation, [int[]] $AllowedStatusCodes = @())
    $status = [int]$Response.StatusCode
    if (($status -ge 200 -and $status -lt 300) -or $status -in $AllowedStatusCodes) { return }
    $errorCode = Get-GwmResponseErrorCode $Response
    $details = Get-GwmResponseErrorMessage $Response
    $retryAfter = ConvertTo-GwmRetryAfterSeconds (Get-GwmHeaderValue $Response.Headers 'Retry-After')
    $transient = $status -in $script:GwmTransientStatusCodes
    $message = "$Operation failed with HTTP $status"
    if ($errorCode) { $message += " ($errorCode)" }
    if ($details) { $message += ": $details" }
    throw (New-GwmException -Message $message -StatusCode $status -Transient $transient -RetryAfterSeconds $retryAfter -ErrorCode $errorCode)
}
