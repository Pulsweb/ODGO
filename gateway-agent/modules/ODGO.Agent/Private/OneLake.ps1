# Upload targets. OneLake uses the ADLS Gen2 (DFS) API; LocalFolder mirrors the same layout on disk (tests, air-gapped staging).
# Every object is written to a staging path first and renamed into place, so readers never see partial files.

$script:GwmDfsApiVersion = '2023-11-03'

function New-GwmTarget {
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Configuration, [Parameter(Mandatory)][string] $AgentInstanceId)
    $target = $Configuration.target
    [pscustomobject]@{
        Type               = $target.type
        Endpoint           = if ($target.endpoint) { ([string]$target.endpoint).TrimEnd('/') } else { $null }
        WorkspaceId        = $target.workspaceId
        LakehouseId        = $target.lakehouseId
        RootFolder         = if ($target.rootFolder) { ([string]$target.rootFolder).Trim('/') } else { $null }
        LocalPath          = $target.localPath
        Authentication     = $Configuration.authentication
        Network            = $Configuration.network
        StagingFolder      = "_staging/$AgentInstanceId"
        CreatedDirectories = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    }
}

function Get-GwmTargetDisplayName {
    param([Parameter(Mandatory)] $Target)
    if ($Target.Type -eq 'LocalFolder') { return $Target.LocalPath }
    return '{0}/{1}/{2}/{3}' -f $Target.Endpoint, $Target.WorkspaceId, $Target.LakehouseId, $Target.RootFolder
}

function Get-GwmOneLakePathSegments {
    param([Parameter(Mandatory)] $Target, [string] $RelativePath)
    $segments = @($Target.WorkspaceId, $Target.LakehouseId) + @($Target.RootFolder -split '/') + @($RelativePath -split '/')
    return @($segments | Where-Object { -not [string]::IsNullOrEmpty($_) } | ForEach-Object { [uri]::EscapeDataString($_) })
}

function Get-GwmOneLakeUrl {
    [OutputType([string])]
    param([Parameter(Mandatory)] $Target, [string] $RelativePath)
    return '{0}/{1}' -f $Target.Endpoint, ((Get-GwmOneLakePathSegments -Target $Target -RelativePath $RelativePath) -join '/')
}

function Invoke-GwmOneLakeRequest {
    <# One DFS call with authentication, API version, retries for transient errors and a single token refresh on 401. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Parameters are used inside the retried script block.')]
    param(
        [Parameter(Mandatory)] $Target,
        [Parameter(Mandatory)][string] $Method,
        [Parameter(Mandatory)][string] $Uri,
        [hashtable] $Headers = @{},
        [AllowNull()] $Body = $null,
        [string] $ContentType,
        [string] $Operation,
        [int[]] $AllowedStatusCodes = @()
    )
    $network = $Target.Network
    Invoke-GwmWithRetry -Operation $Operation -MaxRetries ([int]$network.maxRetries) -BaseDelaySeconds ([int]$network.retryBaseDelaySeconds) -MaxDelaySeconds ([int]$network.retryMaxDelaySeconds) -ScriptBlock {
        $refreshed = $false
        while ($true) {
            $requestHeaders = @{
                'x-ms-version'           = $script:GwmDfsApiVersion
                'x-ms-client-request-id' = [guid]::NewGuid().ToString()
            }
            foreach ($key in $Headers.Keys) { $requestHeaders[$key] = $Headers[$key] }
            $token = Get-GwmAccessToken -Authentication $Target.Authentication -Network $network -ForceRefresh:$refreshed
            if ($token) { $requestHeaders['Authorization'] = "Bearer $token" }
            $response = Invoke-GwmHttpRequest -Method $Method -Uri $Uri -Headers $requestHeaders -Body $Body -ContentType $ContentType -TimeoutSeconds ([int]$network.timeoutSeconds) -Network $network
            if ($response.StatusCode -eq 401 -and -not $refreshed) { $refreshed = $true; continue }
            if ($response.StatusCode -eq 403) {
                Assert-GwmHttpSuccess -Response $response -Operation "$Operation (the identity needs Contributor on the workspace or a OneLake security ReadWrite role on the landing folder)"
            }
            Assert-GwmHttpSuccess -Response $response -Operation $Operation -AllowedStatusCodes $AllowedStatusCodes
            return $response
        }
    }
}

function Get-GwmObjectInfo {
    <# Returns @{ Length } of an existing object or $null. #>
    param([Parameter(Mandatory)] $Target, [Parameter(Mandatory)][string] $RelativePath)
    if ($Target.Type -eq 'LocalFolder') {
        $path = Join-Path $Target.LocalPath ($RelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        if (-not [System.IO.File]::Exists($path)) { return $null }
        return [pscustomobject]@{ Length = ([System.IO.FileInfo]::new($path)).Length }
    }
    $response = Invoke-GwmOneLakeRequest -Target $Target -Method Head -Uri (Get-GwmOneLakeUrl -Target $Target -RelativePath $RelativePath) -Operation "HEAD $RelativePath" -AllowedStatusCodes @(404)
    if ($response.StatusCode -eq 404) { return $null }
    $length = Get-GwmHeaderValue $response.Headers 'Content-Length'
    return [pscustomobject]@{ Length = if ($length) { [long]$length } else { -1L } }
}

function Remove-GwmObject {
    param([Parameter(Mandatory)] $Target, [Parameter(Mandatory)][string] $RelativePath)
    if ($Target.Type -eq 'LocalFolder') {
        $path = Join-Path $Target.LocalPath ($RelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        if ([System.IO.File]::Exists($path)) { [System.IO.File]::Delete($path) }
        return
    }
    $null = Invoke-GwmOneLakeRequest -Target $Target -Method Delete -Uri (Get-GwmOneLakeUrl -Target $Target -RelativePath $RelativePath) -Operation "DELETE $RelativePath" -AllowedStatusCodes @(404)
}

function Initialize-GwmOneLakeDirectory {
    param([Parameter(Mandatory)] $Target, [Parameter(Mandatory)][string] $RelativeDirectory, [switch] $Force)
    if (-not $Force -and $Target.CreatedDirectories.Contains($RelativeDirectory)) { return }
    $null = Invoke-GwmOneLakeRequest -Target $Target -Method Put -Uri ((Get-GwmOneLakeUrl -Target $Target -RelativePath $RelativeDirectory) + '?resource=directory') -Body ([byte[]]::new(0)) -Operation "Create directory $RelativeDirectory"
    [void]$Target.CreatedDirectories.Add($RelativeDirectory)
}

function Publish-GwmOneLakeObject {
    param([Parameter(Mandatory)] $Target, [Parameter(Mandatory)][string] $RelativePath, [Parameter(Mandatory)][AllowEmptyCollection()][byte[]] $Content)
    $stagingPath = '{0}/{1}.part' -f $Target.StagingFolder, [guid]::NewGuid().ToString('n')
    $stagingUrl = Get-GwmOneLakeUrl -Target $Target -RelativePath $stagingPath
    $null = Invoke-GwmOneLakeRequest -Target $Target -Method Put -Uri "$($stagingUrl)?resource=file" -Body ([byte[]]::new(0)) -Operation "Create $stagingPath"
    $chunkSize = [int]$Target.Network.uploadChunkBytes
    for ($position = 0; $position -lt $Content.Length; $position += $chunkSize) {
        $length = [Math]::Min($chunkSize, $Content.Length - $position)
        $chunk = [byte[]]::new($length)
        [Array]::Copy($Content, $position, $chunk, 0, $length)
        $null = Invoke-GwmOneLakeRequest -Target $Target -Method Patch -Uri "$($stagingUrl)?action=append&position=$position" -Body $chunk -ContentType 'application/octet-stream' -Operation "Append $stagingPath"
    }
    $null = Invoke-GwmOneLakeRequest -Target $Target -Method Patch -Uri "$($stagingUrl)?action=flush&position=$($Content.Length)" -Body ([byte[]]::new(0)) -Operation "Flush $stagingPath"

    $directory = $RelativePath.Substring(0, $RelativePath.LastIndexOf('/'))
    Initialize-GwmOneLakeDirectory -Target $Target -RelativeDirectory $directory
    $destinationUrl = Get-GwmOneLakeUrl -Target $Target -RelativePath $RelativePath
    $renameSource = '/' + ((Get-GwmOneLakePathSegments -Target $Target -RelativePath $stagingPath) -join '/')
    $rename = {
        param([bool] $Overwrite)
        $headers = @{ 'x-ms-rename-source' = $renameSource }
        if (-not $Overwrite) { $headers['If-None-Match'] = '*' }
        Invoke-GwmOneLakeRequest -Target $Target -Method Put -Uri $destinationUrl -Headers $headers -Body ([byte[]]::new(0)) -Operation "Rename to $RelativePath" -AllowedStatusCodes @(404, 409, 412)
    }
    $response = & $rename $false
    if ($response.StatusCode -eq 404 -and (Get-GwmResponseErrorCode $response) -match 'Parent') {
        Initialize-GwmOneLakeDirectory -Target $Target -RelativeDirectory $directory -Force
        $response = & $rename $false
    }
    if ($response.StatusCode -in @(409, 412)) {
        $existing = Get-GwmObjectInfo -Target $Target -RelativePath $RelativePath
        if ($existing -and $existing.Length -eq $Content.Length) {
            try { Remove-GwmObject -Target $Target -RelativePath $stagingPath } catch { $null = $_ }
            return 'AlreadyExists'
        }
        $response = & $rename $true
        Assert-GwmHttpSuccess -Response $response -Operation "Rename to $RelativePath"
        return 'Replaced'
    }
    Assert-GwmHttpSuccess -Response $response -Operation "Rename to $RelativePath"
    return 'Uploaded'
}

function Publish-GwmLocalObject {
    param([Parameter(Mandatory)] $Target, [Parameter(Mandatory)][string] $RelativePath, [Parameter(Mandatory)][AllowEmptyCollection()][byte[]] $Content)
    $separator = [System.IO.Path]::DirectorySeparatorChar
    $destination = Join-Path $Target.LocalPath ($RelativePath -replace '/', $separator)
    $staging = Join-Path $Target.LocalPath (('{0}/{1}.part' -f $Target.StagingFolder, [guid]::NewGuid().ToString('n')) -replace '/', $separator)
    [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $staging))
    [System.IO.File]::WriteAllBytes($staging, $Content)
    [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
    if ([System.IO.File]::Exists($destination)) {
        if (([System.IO.FileInfo]::new($destination)).Length -eq $Content.Length) {
            [System.IO.File]::Delete($staging)
            return 'AlreadyExists'
        }
        [System.IO.File]::Replace($staging, $destination, [NullString]::Value)
        return 'Replaced'
    }
    [System.IO.File]::Move($staging, $destination)
    return 'Uploaded'
}

function Publish-GwmObject {
    <#
    Uploads Content to RelativePath (below the landing root) through staging + rename.
    Returns Uploaded, AlreadyExists (identical size already present: deterministic names make it the same object) or Replaced.
    With -CheckExisting a HEAD request avoids re-uploading objects that are already in place (journal replay).
    #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] $Target,
        [Parameter(Mandatory)][string] $RelativePath,
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]] $Content,
        [switch] $CheckExisting
    )
    if ($CheckExisting) {
        $existing = Get-GwmObjectInfo -Target $Target -RelativePath $RelativePath
        if ($existing -and $existing.Length -eq $Content.Length) { return 'AlreadyExists' }
    }
    if ($Target.Type -eq 'LocalFolder') { return Publish-GwmLocalObject -Target $Target -RelativePath $RelativePath -Content $Content }
    return Publish-GwmOneLakeObject -Target $Target -RelativePath $RelativePath -Content $Content
}
