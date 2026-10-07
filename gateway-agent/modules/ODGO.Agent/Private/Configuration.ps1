# Configuration: defaults, JSON loading, deep merge, overrides and validation.

$script:GwmLogTypeNames = @(
    'gateway-info', 'gateway-errors', 'gateway-network', 'mashup', 'mashup-container-profiles',
    'query-start-report', 'query-execution-report', 'query-execution-aggregation-report',
    'system-counter-aggregation-report', 'gateway-properties', 'gateway-clusters', 'gateway-configuration'
)
$script:GwmGuidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

function Get-GwmDefaultConfiguration {
    <# Default configuration. The state, logs and client secret are in the agent folder (AgentRoot). #>
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([string] $AgentRoot = $script:GwmAgentRoot)
    [ordered]@{
        schemaVersion  = '1.0'
        environment    = 'prod'
        agent          = [ordered]@{
            stateDirectory          = Join-Path $AgentRoot 'state'
            logDirectory            = Join-Path $AgentRoot 'logs'
            logLevel                = 'Information'
            logRetentionDays        = 30
            maxRunMinutes           = 45
            checkpointRetentionDays = 30
            outboxMaxFiles          = 100
        }
        server         = [ordered]@{
            name = $null
            id   = $null
        }
        target         = [ordered]@{
            type        = 'OneLake'
            endpoint    = 'https://onelake.dfs.fabric.microsoft.com'
            workspaceId = $null
            lakehouseId = $null
            rootFolder  = 'Files/gateway-monitor/landing'
            localPath   = $null
        }
        authentication = [ordered]@{
            mode                    = 'ClientSecret'
            tenantId                = $null
            clientId                = $null
            clientSecretPath        = Join-Path $AgentRoot 'config\client-secret.dat'
            managedIdentityClientId = $null
            authorityHost           = 'https://login.microsoftonline.com'
            resource                = 'https://storage.azure.com/'
        }
        network        = [ordered]@{
            proxyUrl                   = $null
            proxyUseDefaultCredentials = $true
            timeoutSeconds             = 100
            maxRetries                 = 5
            retryBaseDelaySeconds      = 2
            retryMaxDelaySeconds       = 60
            uploadChunkBytes           = 4194304
        }
        collection     = [ordered]@{
            initialBackfillDays        = 7
            minSegmentBytes            = 262144
            maxSegmentBytes            = 33554432
            maxSegmentAgeMinutes       = 60
            settleSeconds              = 300
            maxBytesPerRun             = 1073741824
            maxSegmentsPerRun          = 2000
            lockRetryCount             = 3
            lockRetryDelayMilliseconds = 500
            metadataRefreshHours       = 24
            logTypes                   = [ordered]@{}
        }
        sources        = @()
    }
}

function Get-GwmDefaultSource {
    [ordered]@{
        name        = 'default'
        enabled     = $true
        logPath     = $null
        reportPath  = $null
        serviceName = 'PBIEgwService'
        gatewayId   = $null
        gatewayName = $null
        clusterId   = $null
        clusterName = $null
        logTypes    = $null
    }
}

function ConvertTo-GwmDictionary {
    <# Recursively converts PSCustomObject/IDictionary graphs into case-insensitive ordered dictionaries. #>
    param([AllowNull()] $InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in @($InputObject.Keys)) { $result[[string]$key] = ConvertTo-GwmDictionary $InputObject[$key] }
        return $result
    }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $result = [ordered]@{}
        foreach ($property in $InputObject.PSObject.Properties) { $result[$property.Name] = ConvertTo-GwmDictionary $property.Value }
        return $result
    }
    if ($InputObject -is [System.Collections.IList]) {
        $items = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $InputObject) { $items.Add((ConvertTo-GwmDictionary $item)) }
        return , $items.ToArray()
    }
    return $InputObject
}

function ConvertFrom-GwmJson {
    <# ConvertFrom-Json that returns a JSON array as one array, in Windows PowerShell 5.1 and PowerShell 7 (which would
       enumerate it): a nested array is never enumerated. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Json)
    if ([string]::IsNullOrWhiteSpace($Json)) { return $null }
    return , ('{"value":' + $Json + '}' | ConvertFrom-Json).value
}

function ConvertTo-GwmJson {
    <# ConvertTo-Json indented with two spaces in Windows PowerShell 5.1 too, whose own layout aligns nested values far to
       the right. For small documents that people read, such as config.json. #>
    [OutputType([string])]
    param([AllowNull()] $InputObject, [int] $Depth = 16)
    $compact = ConvertTo-Json -InputObject $InputObject -Depth $Depth -Compress -WarningAction SilentlyContinue
    $tokens = [regex]::Matches($compact, '"(?:[^"\\]|\\.)*"|[{}\[\],:]|[^{}\[\],:"\s]+')
    $builder = [System.Text.StringBuilder]::new()
    $level = 0
    for ($index = 0; $index -lt $tokens.Count; $index++) {
        $token = $tokens[$index].Value
        $next = if ($index + 1 -lt $tokens.Count) { $tokens[$index + 1].Value } else { '' }
        if (($token -eq '{' -and $next -eq '}') -or ($token -eq '[' -and $next -eq ']')) { [void]$builder.Append($token + $next); $index++ }
        elseif ($token -eq '{' -or $token -eq '[') { $level++; [void]$builder.Append($token).Append("`n").Append('  ' * $level) }
        elseif ($token -eq '}' -or $token -eq ']') { $level--; [void]$builder.Append("`n").Append('  ' * $level).Append($token) }
        elseif ($token -eq ',') { [void]$builder.Append(",`n").Append('  ' * $level) }
        elseif ($token -eq ':') { [void]$builder.Append(': ') }
        else { [void]$builder.Append($token) }
    }
    return $builder.ToString()
}

function Merge-GwmDictionary {
    <# Deep merge: dictionaries merge recursively, every other value (arrays included) replaces. Unknown keys are kept so validation can report them. #>
    param([System.Collections.IDictionary] $Base, [System.Collections.IDictionary] $Override)
    $result = [ordered]@{}
    foreach ($key in @($Base.Keys)) { $result[$key] = $Base[$key] }
    if ($null -eq $Override) { return $result }
    foreach ($key in @($Override.Keys)) {
        $existingKey = @($result.Keys | Where-Object { $_ -ieq $key }) | Select-Object -First 1
        $targetKey = if ($existingKey) { $existingKey } else { $key }
        $baseValue = if ($existingKey) { $result[$existingKey] } else { $null }
        $value = $Override[$key]
        if ($baseValue -is [System.Collections.IDictionary] -and $value -is [System.Collections.IDictionary]) {
            $result[$targetKey] = Merge-GwmDictionary -Base $baseValue -Override $value
        }
        else {
            $result[$targetKey] = $value
        }
    }
    return $result
}

function Set-GwmConfigurationValue {
    <# Applies a dotted-path override such as 'agent.logLevel' = 'Debug'. #>
    param([System.Collections.IDictionary] $Configuration, [string] $Path, $Value)
    $parts = $Path.Split('.')
    $node = $Configuration
    for ($i = 0; $i -lt $parts.Count - 1; $i++) {
        if (-not ($node[$parts[$i]] -is [System.Collections.IDictionary])) { $node[$parts[$i]] = [ordered]@{} }
        $node = $node[$parts[$i]]
    }
    $node[$parts[-1]] = $Value
}

function Expand-GwmPathValue {
    param([AllowNull()][string] $Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    return [Environment]::ExpandEnvironmentVariables($Value.Trim())
}

function Resolve-GwmConfiguration {
    <# Merges defaults + file content + overrides, expands paths, completes sources. Does not validate. #>
    param(
        [AllowNull()][System.Collections.IDictionary] $FileConfiguration,
        [AllowNull()][hashtable] $Overrides,
        [string] $AgentRoot = $script:GwmAgentRoot
    )
    $configuration = Merge-GwmDictionary -Base (Get-GwmDefaultConfiguration -AgentRoot $AgentRoot) -Override $FileConfiguration
    if ($Overrides) {
        foreach ($key in $Overrides.Keys) { Set-GwmConfigurationValue -Configuration $configuration -Path $key -Value $Overrides[$key] }
    }
    $sources = @($configuration.sources | Where-Object { $null -ne $_ })
    if ($sources.Count -eq 0) { $sources = @([ordered]@{}) }
    $resolved = foreach ($source in $sources) {
        if ($source -isnot [System.Collections.IDictionary]) { $source }
        else {
            $merged = Merge-GwmDictionary -Base (Get-GwmDefaultSource) -Override $source
            $merged.logPath = Expand-GwmPathValue $merged.logPath
            $merged.reportPath = Expand-GwmPathValue $merged.reportPath
            $merged
        }
    }
    $configuration.sources = @($resolved)
    if ($configuration.agent -is [System.Collections.IDictionary]) {
        $configuration.agent.stateDirectory = Expand-GwmPathValue $configuration.agent.stateDirectory
        $configuration.agent.logDirectory = Expand-GwmPathValue $configuration.agent.logDirectory
    }
    if ($configuration.target -is [System.Collections.IDictionary]) {
        $configuration.target.localPath = Expand-GwmPathValue $configuration.target.localPath
    }
    if ($configuration.authentication -is [System.Collections.IDictionary]) {
        $configuration.authentication.clientSecretPath = Expand-GwmPathValue $configuration.authentication.clientSecretPath
    }
    if ($configuration.environment -is [string]) { $configuration.environment = $configuration.environment.Trim().ToLowerInvariant() }
    return $configuration
}

function Test-GwmIntRange {
    param($Value, [long] $Minimum, [long] $Maximum)
    if ($Value -isnot [int] -and $Value -isnot [long] -and $Value -isnot [int16] -and $Value -isnot [byte]) { return $false }
    return ([long]$Value -ge $Minimum -and [long]$Value -le $Maximum)
}

function Test-GwmConfigurationObject {
    <# Returns a list of validation errors (JSON-path style). An empty list means the configuration is valid. #>
    [OutputType([string[]])]
    param([System.Collections.IDictionary] $Configuration)
    $errors = [System.Collections.Generic.List[string]]::new()
    $defaults = Get-GwmDefaultConfiguration

    foreach ($key in $Configuration.Keys) {
        if ($key -eq '$schema') { continue }
        if (-not $defaults.Contains($key)) { $errors.Add("$($key): unknown configuration key") }
    }
    foreach ($section in @('agent', 'server', 'target', 'authentication', 'network', 'collection')) {
        $value = $Configuration[$section]
        if ($value -isnot [System.Collections.IDictionary]) { $errors.Add("$($section): must be an object"); continue }
        foreach ($key in $value.Keys) {
            if (-not $defaults[$section].Contains($key)) { $errors.Add("$section.$($key): unknown configuration key") }
        }
    }
    if ($errors.Count -gt 0) { return , $errors.ToArray() }

    if (-not ("$($Configuration.schemaVersion)" -match '^1\.[0-9]+$')) { $errors.Add("schemaVersion: '$($Configuration.schemaVersion)' is not supported (expected 1.x)") }
    $environment = $Configuration.environment
    if ([string]::IsNullOrWhiteSpace($environment)) { $errors.Add('environment: required (for example dev, test or prod)') }
    elseif ($environment -notmatch '^[a-z0-9][a-z0-9._-]{0,62}$') { $errors.Add("environment: '$environment' must match ^[a-z0-9][a-z0-9._-]{0,62}$") }

    $agent = $Configuration.agent
    if ([string]::IsNullOrWhiteSpace($agent.stateDirectory)) { $errors.Add('agent.stateDirectory: required') }
    if ([string]::IsNullOrWhiteSpace($agent.logDirectory)) { $errors.Add('agent.logDirectory: required') }
    if ($agent.logLevel -notin @('Debug', 'Information', 'Warning', 'Error')) { $errors.Add('agent.logLevel: must be Debug, Information, Warning or Error') }
    if (-not (Test-GwmIntRange $agent.logRetentionDays 1 3650)) { $errors.Add('agent.logRetentionDays: integer 1..3650') }
    if (-not (Test-GwmIntRange $agent.maxRunMinutes 1 1440)) { $errors.Add('agent.maxRunMinutes: integer 1..1440') }
    if (-not (Test-GwmIntRange $agent.checkpointRetentionDays 1 3650)) { $errors.Add('agent.checkpointRetentionDays: integer 1..3650') }
    if (-not (Test-GwmIntRange $agent.outboxMaxFiles 0 10000)) { $errors.Add('agent.outboxMaxFiles: integer 0..10000') }

    $server = $Configuration.server
    if ($null -ne $server.name -and ($server.name -isnot [string] -or (ConvertTo-GwmPartitionValue $server.name) -eq '')) { $errors.Add('server.name: must be a non-empty host name or null') }
    if ($null -ne $server.id -and "$($server.id)" -notmatch '^[0-9a-f]{16}$') { $errors.Add('server.id: must be 16 lower-case hexadecimal characters or null') }

    $target = $Configuration.target
    switch ($target.type) {
        'OneLake' {
            if ([string]::IsNullOrWhiteSpace($target.workspaceId)) { $errors.Add('target.workspaceId: required for OneLake (workspace GUID)') }
            if ([string]::IsNullOrWhiteSpace($target.lakehouseId)) { $errors.Add('target.lakehouseId: required for OneLake (lakehouse GUID)') }
            if ("$($target.endpoint)" -notmatch '^https://[A-Za-z0-9.-]+(:[0-9]+)?/?$') { $errors.Add('target.endpoint: must be an https URL such as https://onelake.dfs.fabric.microsoft.com') }
            $root = "$($target.rootFolder)"
            if ($root -notmatch '^Files(/[A-Za-z0-9._ -]+)*$' -or $root -match '(^|/)\.\.?(/|$)') { $errors.Add("target.rootFolder: '$root' must be a path below Files/ without leading or trailing '/'") }
        }
        'LocalFolder' {
            if ([string]::IsNullOrWhiteSpace($target.localPath)) { $errors.Add('target.localPath: required for LocalFolder') }
        }
        default { $errors.Add("target.type: '$($target.type)' must be OneLake or LocalFolder") }
    }

    $auth = $Configuration.authentication
    switch ($auth.mode) {
        'ClientSecret' {
            if ("$($auth.tenantId)" -notmatch '^([0-9a-fA-F-]{36}|[A-Za-z0-9.-]+\.[A-Za-z]{2,})$') { $errors.Add('authentication.tenantId: tenant GUID or verified domain required') }
            if ("$($auth.clientId)" -notmatch $script:GwmGuidPattern) { $errors.Add('authentication.clientId: application (client) id GUID required') }
            if ([string]::IsNullOrWhiteSpace($auth.clientSecretPath)) { $errors.Add('authentication.clientSecretPath: required') }
        }
        'ManagedIdentity' {
            if ($null -ne $auth.managedIdentityClientId -and "$($auth.managedIdentityClientId)" -notmatch $script:GwmGuidPattern) { $errors.Add('authentication.managedIdentityClientId: GUID or null') }
        }
        'None' {
            if ($target.type -eq 'OneLake') { $errors.Add('authentication.mode: None is only allowed with target.type LocalFolder') }
        }
        default { $errors.Add("authentication.mode: '$($auth.mode)' must be ClientSecret, ManagedIdentity or None") }
    }
    if ("$($auth.authorityHost)" -notmatch '^https://') { $errors.Add('authentication.authorityHost: https URL required') }
    if ("$($auth.resource)" -notmatch '^https://') { $errors.Add('authentication.resource: https URL required') }

    $network = $Configuration.network
    if ($null -ne $network.proxyUrl -and "$($network.proxyUrl)" -notmatch '^https?://') { $errors.Add('network.proxyUrl: http(s) URL or null') }
    if ($network.proxyUseDefaultCredentials -isnot [bool]) { $errors.Add('network.proxyUseDefaultCredentials: boolean') }
    if (-not (Test-GwmIntRange $network.timeoutSeconds 5 600)) { $errors.Add('network.timeoutSeconds: integer 5..600') }
    if (-not (Test-GwmIntRange $network.maxRetries 0 20)) { $errors.Add('network.maxRetries: integer 0..20') }
    if (-not (Test-GwmIntRange $network.retryBaseDelaySeconds 0 300)) { $errors.Add('network.retryBaseDelaySeconds: integer 0..300') }
    if (-not (Test-GwmIntRange $network.retryMaxDelaySeconds 0 3600)) { $errors.Add('network.retryMaxDelaySeconds: integer 0..3600') }
    if (-not (Test-GwmIntRange $network.uploadChunkBytes 65536 104857600)) { $errors.Add('network.uploadChunkBytes: integer 65536..104857600') }

    $collection = $Configuration.collection
    if (-not (Test-GwmIntRange $collection.initialBackfillDays 0 3650)) { $errors.Add('collection.initialBackfillDays: integer 0..3650') }
    if (-not (Test-GwmIntRange $collection.maxSegmentBytes 65536 268435456)) { $errors.Add('collection.maxSegmentBytes: integer 65536..268435456') }
    elseif (-not (Test-GwmIntRange $collection.minSegmentBytes 0 $collection.maxSegmentBytes)) { $errors.Add('collection.minSegmentBytes: integer 0..maxSegmentBytes') }
    if (-not (Test-GwmIntRange $collection.maxSegmentAgeMinutes 1 10080)) { $errors.Add('collection.maxSegmentAgeMinutes: integer 1..10080') }
    if (-not (Test-GwmIntRange $collection.settleSeconds 0 86400)) { $errors.Add('collection.settleSeconds: integer 0..86400') }
    if (-not (Test-GwmIntRange $collection.maxBytesPerRun 65536 ([long]::MaxValue))) { $errors.Add('collection.maxBytesPerRun: integer >= 65536') }
    if (-not (Test-GwmIntRange $collection.maxSegmentsPerRun 1 100000)) { $errors.Add('collection.maxSegmentsPerRun: integer 1..100000') }
    if (-not (Test-GwmIntRange $collection.lockRetryCount 0 20)) { $errors.Add('collection.lockRetryCount: integer 0..20') }
    if (-not (Test-GwmIntRange $collection.lockRetryDelayMilliseconds 0 60000)) { $errors.Add('collection.lockRetryDelayMilliseconds: integer 0..60000') }
    if (-not (Test-GwmIntRange $collection.metadataRefreshHours 1 720)) { $errors.Add('collection.metadataRefreshHours: integer 1..720') }
    if ($collection.logTypes -isnot [System.Collections.IDictionary]) { $errors.Add('collection.logTypes: must be an object keyed by log type') }
    else {
        foreach ($logType in $collection.logTypes.Keys) {
            if ($logType -notin $script:GwmLogTypeNames) { $errors.Add("collection.logTypes.$($logType): unknown log type"); continue }
            $override = $collection.logTypes[$logType]
            if ($override -isnot [System.Collections.IDictionary]) { $errors.Add("collection.logTypes.$($logType): must be an object"); continue }
            foreach ($key in $override.Keys) {
                switch ($key) {
                    'enabled' { if ($override[$key] -isnot [bool]) { $errors.Add("collection.logTypes.$logType.enabled: boolean") } }
                    { $_ -in @('patterns', 'exclude') } {
                        $values = @($override[$key])
                        if ($values.Count -eq 0 -and $key -eq 'patterns') { $errors.Add("collection.logTypes.$logType.patterns: at least one pattern") }
                        foreach ($pattern in $values) {
                            if ($pattern -isnot [string] -or $pattern -match '[\\/]') { $errors.Add("collection.logTypes.$logType.$($key): file name patterns without folders") }
                        }
                    }
                    default { $errors.Add("collection.logTypes.$logType.$($key): unknown key (enabled, patterns, exclude)") }
                }
            }
        }
    }

    $names = @{}
    $index = 0
    foreach ($source in @($Configuration.sources)) {
        $prefix = "sources[$index]"
        $index++
        if ($source -isnot [System.Collections.IDictionary]) { $errors.Add("$($prefix): must be an object"); continue }
        $sourceDefaults = Get-GwmDefaultSource
        foreach ($key in $source.Keys) {
            if (-not $sourceDefaults.Contains($key)) { $errors.Add("$prefix.$($key): unknown key") }
        }
        if ("$($source.name)" -notmatch '^[A-Za-z0-9._-]{1,64}$') { $errors.Add("$prefix.name: 1-64 characters [A-Za-z0-9._-]") }
        elseif ($names.ContainsKey("$($source.name)".ToLowerInvariant())) { $errors.Add("$prefix.name: duplicate source name '$($source.name)'") }
        else { $names["$($source.name)".ToLowerInvariant()] = $true }
        if ($source.enabled -isnot [bool]) { $errors.Add("$prefix.enabled: boolean") }
        if ($null -ne $source.gatewayId -and "$($source.gatewayId)" -notmatch $script:GwmGuidPattern) { $errors.Add("$prefix.gatewayId: GUID or null") }
        if ($null -ne $source.clusterId -and "$($source.clusterId)" -notmatch $script:GwmGuidPattern) { $errors.Add("$prefix.clusterId: GUID or null") }
        if ($null -ne $source.logTypes) {
            foreach ($logType in @($source.logTypes)) {
                if ($logType -notin $script:GwmLogTypeNames) { $errors.Add("$prefix.logTypes: unknown log type '$logType'") }
            }
        }
    }
    if ($index -eq 0) { $errors.Add('sources: at least one source is required') }
    return , $errors.ToArray()
}

function Read-GwmConfigurationFile {
    param([Parameter(Mandatory)][string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw [System.IO.FileNotFoundException]::new("Configuration file not found: $Path", $Path) }
    $text = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).ProviderPath)
    try {
        $parsed = $text | ConvertFrom-Json
    }
    catch {
        throw "Configuration file '$Path' is not valid JSON: $($_.Exception.Message)"
    }
    if ($parsed -isnot [System.Management.Automation.PSCustomObject]) { throw "Configuration file '$Path' must contain a JSON object" }
    return ConvertTo-GwmDictionary $parsed
}

function Get-GwmConfigurationHash {
    <# First 16 hex characters of the SHA-256 of the effective configuration (reported in run telemetry). #>
    param([System.Collections.IDictionary] $Configuration)
    return (Get-GwmStringSha256Hex ($Configuration | ConvertTo-Json -Depth 32 -Compress)).Substring(0, 16)
}
