# Unattended authentication:
#   ClientSecret    - app registration secret stored with DPAPI (machine scope) by Install-Agent.ps1 / Set-GwmClientSecret;
#   ManagedIdentity - Azure Arc-enabled server (HIMDS, detected automatically) or Azure VM (IMDS).
# Tokens are cached in memory only and never logged. Secrets and tokens are never passed to a command as a string
# parameter or as pipeline input: PowerShell module logging (event 4103) records those values.

$script:GwmAadHints = @{
    'AADSTS700016'  = 'The application (client) id was not found in the tenant: check authentication.clientId and authentication.tenantId.'
    'AADSTS7000215' = 'The client secret is not valid: create a new secret on the app registration and run Install-Agent.ps1 -UpdateSecret.'
    'AADSTS7000222' = 'The client secret has expired: create a new secret on the app registration and run Install-Agent.ps1 -UpdateSecret.'
    'AADSTS90002'   = 'The tenant was not found: check authentication.tenantId and authentication.authorityHost.'
    'AADSTS500011'  = 'The resource principal was not found: check authentication.resource (OneLake requires https://storage.azure.com/).'
}
$script:GwmSecretEntropy = [System.Text.Encoding]::UTF8.GetBytes('ODGO.ClientSecret.v1')
$script:GwmBroadReaders = @{
    'S-1-1-0' = 'Everyone'; 'S-1-5-11' = 'Authenticated Users'; 'S-1-5-32-545' = 'Users'; 'S-1-5-32-546' = 'Guests'
    'S-1-5-4' = 'Interactive'; 'S-1-5-2' = 'Network'; 'S-1-5-7' = 'Anonymous Logon'
}

function Protect-GwmSecret {
    <# DPAPI machine scope: any process of this server can decrypt the result, so the file ACL is what protects it. #>
    [OutputType([byte[]])]
    param([Parameter(Mandatory)][securestring] $Secret)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes([System.Net.NetworkCredential]::new('', $Secret).Password.Trim())
    try {
        if ($bytes.Length -eq 0) { throw 'The client secret is empty.' }
        return , [System.Security.Cryptography.ProtectedData]::Protect($bytes, $script:GwmSecretEntropy, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
    }
    finally { [Array]::Clear($bytes, 0, $bytes.Length) }
}

function Assert-GwmPrivateFolder {
    <# Throws when files created in the folder would be readable by broad groups such as Users or Everyone. #>
    param([Parameter(Mandatory)][string] $Path)
    $acl = [System.IO.FileSystemAclExtensions]::GetAccessControl([System.IO.DirectoryInfo]::new($Path))
    foreach ($rule in $acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])) {
        $sid = $rule.IdentityReference.Value
        if ($rule.AccessControlType -ne 'Allow' -or -not $script:GwmBroadReaders.ContainsKey($sid)) { continue }
        if (-not ($rule.InheritanceFlags -band [System.Security.AccessControl.InheritanceFlags]::ObjectInherit)) { continue }
        # ReadData (0x1), GenericAll (0x10000000) or GenericRead (0x80000000, the sign bit).
        $mask = [int]$rule.FileSystemRights
        if (($mask -band 1) -or ($mask -band 0x10000000) -or $mask -lt 0) {
            throw "Files in '$Path' can be read by $($script:GwmBroadReaders[$sid]): the client secret can't be stored there. Run Install-Agent.ps1, which restricts the folder to SYSTEM, Administrators and the task identity."
        }
    }
}

function Read-GwmClientSecret {
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [System.IO.File]::Exists($Path)) {
        throw (New-GwmException -Message "Client secret file '$Path' not found: run Install-Agent.ps1 -UpdateSecret.")
    }
    try {
        $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect([System.IO.File]::ReadAllBytes($Path), $script:GwmSecretEntropy, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
    }
    catch {
        throw (New-GwmException -Message "Cannot read the client secret '$Path' (only SYSTEM, Administrators and the task identity on the server where it was stored can): $($_.Exception.Message) Run Install-Agent.ps1 -UpdateSecret.")
    }
    try { return [System.Text.Encoding]::UTF8.GetString($bytes) }
    finally { [Array]::Clear($bytes, 0, $bytes.Length) }
}

function Get-GwmTokenFromResponse {
    param($Response, [string] $Source)
    $content = $Response.Content
    if ($content -is [byte[]]) { $content = [System.Text.Encoding]::UTF8.GetString($content) }
    # System.Text.Json rather than ConvertFrom-Json, whose input (the token) module logging would record.
    $values = @{}
    try { $document = [System.Text.Json.JsonDocument]::Parse([string]$content) }
    catch { throw "$Source returned a response that isn't JSON." }
    try {
        if ($document.RootElement.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
            foreach ($property in $document.RootElement.EnumerateObject()) {
                $isString = $property.Value.ValueKind -eq [System.Text.Json.JsonValueKind]::String
                $values[$property.Name] = if ($isString) { $property.Value.GetString() } else { $property.Value.GetRawText() }
            }
        }
    }
    finally { $document.Dispose() }
    if ([string]::IsNullOrEmpty($values['access_token'])) { throw "$Source returned no access token." }
    $expires = [DateTime]::UtcNow.AddMinutes(30)
    if ("$($values['expires_on'])" -match '^[0-9]+$') {
        $expires = [DateTimeOffset]::FromUnixTimeSeconds([long]$values['expires_on']).UtcDateTime
    }
    elseif ("$($values['expires_in'])" -match '^[0-9]+$') {
        $expires = [DateTime]::UtcNow.AddSeconds([int]$values['expires_in'])
    }
    return [pscustomobject]@{ Token = [string]$values['access_token']; ExpiresUtc = $expires }
}

function Get-GwmClientSecretToken {
    param([System.Collections.IDictionary] $Authentication, [AllowNull()][System.Collections.IDictionary] $Network)
    $tokenEndpoint = '{0}/{1}/oauth2/v2.0/token' -f $Authentication.authorityHost.TrimEnd('/'), $Authentication.tenantId
    $scope = $Authentication.resource.TrimEnd('/') + '/.default'
    $timeout = if ($Network) { [int]$Network.timeoutSeconds } else { 100 }
    $retries = if ($Network) { [int]$Network.maxRetries } else { 3 }
    # The form is sent as a stream: module logging records the type of a stream parameter, not its content.
    $form = 'client_id={0}&scope={1}&grant_type=client_credentials&client_secret={2}' -f @(
        [uri]::EscapeDataString($Authentication.clientId), [uri]::EscapeDataString($scope),
        [uri]::EscapeDataString((Read-GwmClientSecret -Path $Authentication.clientSecretPath)))
    $response = Invoke-GwmWithRetry -Operation 'Token request' -MaxRetries $retries -ScriptBlock {
        $body = [System.IO.MemoryStream]::new([System.Text.Encoding]::UTF8.GetBytes($form), $false)
        $result = Invoke-GwmHttpRequest -Method Post -Uri $tokenEndpoint -Body $body -ContentType 'application/x-www-form-urlencoded' -TimeoutSeconds $timeout -Network $Network
        if ($result.StatusCode -ge 400) {
            $message = Get-GwmResponseErrorMessage $result
            foreach ($code in $script:GwmAadHints.Keys) { if ($message -match "\b$code\b") { $message = "$message $($script:GwmAadHints[$code])" } }
            $transient = $result.StatusCode -in $script:GwmTransientStatusCodes
            throw (New-GwmException -Message "Token request failed with HTTP $($result.StatusCode): $message" -StatusCode $result.StatusCode -Transient $transient -RetryAfterSeconds (ConvertTo-GwmRetryAfterSeconds (Get-GwmHeaderValue $result.Headers 'Retry-After')))
        }
        $result
    }
    return Get-GwmTokenFromResponse -Response $response -Source 'Microsoft Entra ID'
}

function Get-GwmArcIdentityEndpoint {
    <# The Azure Connected Machine agent sets IDENTITY_ENDPOINT and IMDS_ENDPOINT as machine environment variables. #>
    [OutputType([string])]
    param()
    foreach ($scope in @('Process', 'Machine')) {
        $endpoint = [Environment]::GetEnvironmentVariable('IDENTITY_ENDPOINT', $scope)
        if ($endpoint -and [Environment]::GetEnvironmentVariable('IMDS_ENDPOINT', $scope)) { return $endpoint }
    }
    return $null
}

function Test-GwmArcKeyPath {
    <# Only key files issued by the Azure Connected Machine agent may be read (protects against a spoofed endpoint). #>
    [OutputType([bool])]
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $programData = if ($env:ProgramData) { $env:ProgramData } else { 'C:\ProgramData' }
    $expectedFolder = [System.IO.Path]::GetFullPath((Join-Path $programData 'AzureConnectedMachineAgent\Tokens')).TrimEnd('\') + '\'
    try { $full = [System.IO.Path]::GetFullPath($Path) } catch { return $false }
    return $full.StartsWith($expectedFolder, [StringComparison]::OrdinalIgnoreCase) -and $full.EndsWith('.key', [StringComparison]::OrdinalIgnoreCase)
}

function Get-GwmArcManagedIdentityToken {
    <# Azure Arc-enabled server managed identity (HIMDS challenge/response). #>
    param([System.Collections.IDictionary] $Authentication, [string] $Endpoint, [int] $MaxRetries)
    $parsed = $null
    if (-not [uri]::TryCreate($Endpoint, [UriKind]::Absolute, [ref]$parsed) -or -not $parsed.IsLoopback) {
        throw (New-GwmException -Message "IDENTITY_ENDPOINT '$Endpoint' is not a local Azure Arc endpoint; refusing to use it.")
    }
    $uri = '{0}?api-version=2020-06-01&resource={1}' -f $Endpoint, [uri]::EscapeDataString($Authentication.resource)
    $response = Invoke-GwmWithRetry -Operation 'Managed identity token request (Azure Arc)' -MaxRetries $MaxRetries -ScriptBlock {
        $challenge = Invoke-GwmHttpRequest -Method Get -Uri $uri -Headers @{ Metadata = 'true' } -TimeoutSeconds 30 -NoProxy
        if ($challenge.StatusCode -ne 401) {
            Assert-GwmHttpSuccess -Response $challenge -Operation 'Managed identity challenge (Azure Arc)'
            throw (New-GwmException -Message "The Azure Arc identity endpoint did not return the expected 401 challenge (HTTP $($challenge.StatusCode)).")
        }
        $header = Get-GwmHeaderValue $challenge.Headers 'WWW-Authenticate'
        $keyPath = if ($header -match 'realm=(.+)$') { $Matches[1].Trim().Trim('"') } else { $null }
        if (-not (Test-GwmArcKeyPath $keyPath)) { throw (New-GwmException -Message 'The Azure Arc challenge returned an unexpected key path; refusing to read it.') }
        try { $secret = [System.IO.File]::ReadAllText($keyPath).Trim() }
        catch { throw (New-GwmException -Message "Cannot read the Azure Arc challenge file (the agent must run as SYSTEM, an administrator or a member of 'Hybrid agent extension applications'): $($_.Exception.Message)") }
        $result = Invoke-GwmHttpRequest -Method Get -Uri $uri -Headers @{ Metadata = 'true'; Authorization = "Basic $secret" } -TimeoutSeconds 30 -NoProxy
        Assert-GwmHttpSuccess -Response $result -Operation 'Managed identity token request (Azure Arc)'
        $result
    }
    return Get-GwmTokenFromResponse -Response $response -Source 'Azure Arc identity endpoint'
}

function Get-GwmManagedIdentityToken {
    <# Azure Arc-enabled server when its identity endpoint is configured, otherwise the Azure VM Instance Metadata Service. #>
    param([System.Collections.IDictionary] $Authentication, [AllowNull()][System.Collections.IDictionary] $Network)
    $retries = if ($Network) { [int]$Network.maxRetries } else { 3 }
    $arcEndpoint = Get-GwmArcIdentityEndpoint
    if ($arcEndpoint) { return Get-GwmArcManagedIdentityToken -Authentication $Authentication -Endpoint $arcEndpoint -MaxRetries $retries }
    $uri = 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource={0}' -f [uri]::EscapeDataString($Authentication.resource)
    if ($Authentication.managedIdentityClientId) { $uri += '&client_id=' + [uri]::EscapeDataString($Authentication.managedIdentityClientId) }
    try {
        $response = Invoke-GwmWithRetry -Operation 'Managed identity token request' -MaxRetries ([Math]::Min($retries, 2)) -ScriptBlock {
            $result = Invoke-GwmHttpRequest -Method Get -Uri $uri -Headers @{ Metadata = 'true' } -TimeoutSeconds 10 -NoProxy
            Assert-GwmHttpSuccess -Response $result -Operation 'Managed identity token request (IMDS)'
            $result
        }
    }
    catch {
        throw (New-GwmException -Message "Managed identity token request failed (managed identities exist only on Azure VMs and Azure Arc-enabled servers): $($_.Exception.Message)" -InnerException $_.Exception)
    }
    return Get-GwmTokenFromResponse -Response $response -Source 'Azure Instance Metadata Service'
}

function Get-GwmAccessToken {
    <# Returns a bearer token for the configured resource (cached in memory until 5 minutes before expiry). #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Authentication,
        [AllowNull()][System.Collections.IDictionary] $Network,
        [switch] $ForceRefresh
    )
    if ($Authentication.mode -eq 'None') { return $null }
    $key = '{0}|{1}|{2}|{3}' -f $Authentication.mode, $Authentication.resource, $Authentication.clientId, $Authentication.managedIdentityClientId
    $cached = $script:GwmTokenCache[$key]
    if (-not $ForceRefresh -and $cached -and $cached.ExpiresUtc -gt [DateTime]::UtcNow.AddMinutes(5)) { return $cached.Token }
    $token = switch ($Authentication.mode) {
        'ClientSecret' { Get-GwmClientSecretToken -Authentication $Authentication -Network $Network }
        'ManagedIdentity' { Get-GwmManagedIdentityToken -Authentication $Authentication -Network $Network }
        default { throw "Unsupported authentication mode '$($Authentication.mode)'." }
    }
    $script:GwmTokenCache[$key] = $token
    Write-GwmLog -Level Debug -EventName 'TokenAcquired' -Message "Access token acquired ($($Authentication.mode)); expires $($token.ExpiresUtc.ToString('u'))."
    return $token.Token
}

function Clear-GwmTokenCache {
    $script:GwmTokenCache = @{}
}
