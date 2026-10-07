# HTTP requests through System.Net.Http.HttpClient, the same in Windows PowerShell 5.1 and PowerShell 7: no exceptions
# for HTTP status codes, proxy support, connection reuse within a run, safe URIs in messages.

$script:GwmHttpClients = @{}

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

function New-GwmHttpHandler {
    <# Proxy settings: none (-NoProxy), network.proxyUrl, or the proxy of the system. No cookies: every request stands alone. #>
    param([AllowNull()][System.Collections.IDictionary] $Network, [switch] $NoProxy)
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.UseCookies = $false
    if ($NoProxy) { $handler.UseProxy = $false }
    elseif ($Network -and $Network.proxyUrl) {
        $proxy = [System.Net.WebProxy]::new([string]$Network.proxyUrl)
        $proxy.UseDefaultCredentials = [bool]$Network.proxyUseDefaultCredentials
        $handler.Proxy = $proxy
    }
    return $handler
}

function Get-GwmHttpClient {
    <# One client per proxy setting, kept for the lifetime of the module so that connections are reused. #>
    param([AllowNull()][System.Collections.IDictionary] $Network, [switch] $NoProxy)
    $key = if ($NoProxy) { 'none' }
    elseif ($Network -and $Network.proxyUrl) { 'proxy|{0}|{1}' -f $Network.proxyUrl, [bool]$Network.proxyUseDefaultCredentials }
    else { 'system' }
    if (-not $script:GwmHttpClients.ContainsKey($key)) {
        $client = [System.Net.Http.HttpClient]::new((New-GwmHttpHandler -Network $Network -NoProxy:$NoProxy))
        # Each request has its own timeout.
        $client.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan
        [void]$client.DefaultRequestHeaders.TryAddWithoutValidation('User-Agent', "ODGO-Agent/$script:GwmAgentVersion")
        $script:GwmHttpClients[$key] = $client
    }
    return $script:GwmHttpClients[$key]
}

function Get-GwmExceptionText {
    <# Messages of an exception and of its inner exceptions, without the wrapper that PowerShell adds to .NET method calls. #>
    [OutputType([string])]
    param([System.Exception] $Exception)
    $messages = [System.Collections.Generic.List[string]]::new()
    for ($current = $Exception; $null -ne $current; $current = $current.InnerException) {
        if ($current -is [System.Management.Automation.MethodInvocationException]) { continue }
        $message = $current.Message.Trim()
        if (-not $message.EndsWith('.') -and -not $message.EndsWith(')')) { $message += '.' }
        if (-not @($messages | Where-Object { $_.Contains($message.TrimEnd('.')) })) { $messages.Add($message) }
    }
    return ($messages -join ' ')
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
    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($Method.ToUpperInvariant()), $Uri)
    $timeout = [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSeconds))
    try {
        if ($null -ne $Body) {
            $request.Content = if ($Body -is [byte[]]) { [System.Net.Http.ByteArrayContent]::new($Body) }
            elseif ($Body -is [System.IO.Stream]) { [System.Net.Http.StreamContent]::new($Body) }
            else { [System.Net.Http.StringContent]::new([string]$Body, [System.Text.UTF8Encoding]::new($false)) }
            if ($ContentType) { $request.Content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse($ContentType) }
        }
        # Otherwise .NET Framework waits for a "100 Continue" answer before it sends each body.
        $request.Headers.ExpectContinue = $false
        foreach ($key in $Headers.Keys) {
            if (-not $request.Headers.TryAddWithoutValidation([string]$key, [string]$Headers[$key]) -and $request.Content) {
                [void]$request.Content.Headers.TryAddWithoutValidation([string]$key, [string]$Headers[$key])
            }
        }
        $client = Get-GwmHttpClient -Network $Network -NoProxy:$NoProxy
        try {
            $response = $client.SendAsync($request, $timeout.Token).GetAwaiter().GetResult()
        }
        catch {
            $reason = if ($timeout.IsCancellationRequested) { "no response within $TimeoutSeconds seconds." } else { Get-GwmExceptionText $_.Exception }
            throw (New-GwmException -Message "$Method $(Get-GwmSafeUri $Uri) failed: $reason" -Transient $true -InnerException $_.Exception)
        }
        try {
            $responseHeaders = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
            $headerGroups = @($response.Headers)
            if ($response.Content) { $headerGroups += @($response.Content.Headers) }
            foreach ($header in $headerGroups) { $responseHeaders[$header.Key] = @($header.Value) -join ',' }
            $content = if ($response.Content) { $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() } else { '' }
            $result = [pscustomobject]@{
                StatusCode = [int]$response.StatusCode
                Headers    = $responseHeaders
                Content    = $content
            }
        }
        finally { $response.Dispose() }
    }
    finally {
        $request.Dispose()
        $timeout.Dispose()
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
            $json = $content | ConvertFrom-Json
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
        $json = $content | ConvertFrom-Json
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
