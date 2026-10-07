# Log-type catalog and file enumeration.

function Get-GwmLogTypeCatalog {
    <# Built-in catalog (classification order matters: specific types before generic ones) merged with collection.logTypes overrides. #>
    param([AllowNull()][System.Collections.IDictionary] $Overrides)
    $catalog = [ordered]@{
        'gateway-errors'                     = [ordered]@{ location = 'LogRoot'; patterns = @('GatewayError*.log'); exclude = @(); format = 'trace'; mode = 'incremental'; enabled = $true; priority = 10 }
        'gateway-info'                       = [ordered]@{ location = 'LogRoot'; patterns = @('GatewayInfo*.log'); exclude = @(); format = 'trace'; mode = 'incremental'; enabled = $true; priority = 30 }
        'gateway-network'                    = [ordered]@{ location = 'LogRoot'; patterns = @('GatewayNetwork*.log'); exclude = @(); format = 'trace'; mode = 'incremental'; enabled = $false; priority = 50 }
        'mashup-container-profiles'          = [ordered]@{ location = 'LogRoot'; patterns = @('MashupContainerProfiles*.log'); exclude = @(); format = 'profile'; mode = 'snapshot'; enabled = $true; priority = 5 }
        'mashup'                             = [ordered]@{ location = 'LogRoot'; patterns = @('Mashup*.log'); exclude = @('MashupContainerProfiles*'); format = 'jsonl'; mode = 'incremental'; enabled = $true; priority = 40 }
        'query-execution-report'             = [ordered]@{ location = 'Report'; patterns = @('QueryExecutionReport*.log'); exclude = @(); format = 'csv'; mode = 'incremental'; enabled = $true; priority = 20 }
        'query-start-report'                 = [ordered]@{ location = 'Report'; patterns = @('QueryStartReport*.log'); exclude = @(); format = 'csv'; mode = 'incremental'; enabled = $true; priority = 21 }
        'query-execution-aggregation-report' = [ordered]@{ location = 'Report'; patterns = @('QueryExecutionAggregationReport*.log'); exclude = @(); format = 'csv'; mode = 'incremental'; enabled = $true; priority = 22 }
        'system-counter-aggregation-report'  = [ordered]@{ location = 'Report'; patterns = @('SystemCounterAggregationReport*.log'); exclude = @(); format = 'csv'; mode = 'incremental'; enabled = $true; priority = 23 }
        'gateway-properties'                 = [ordered]@{ location = 'LogRoot'; patterns = @('GatewayProperties.txt'); exclude = @(); format = 'json'; mode = 'snapshot'; enabled = $true; priority = 1 }
        'gateway-clusters'                   = [ordered]@{ location = 'LogRoot'; patterns = @('GatewayClusters.txt'); exclude = @(); format = 'json'; mode = 'snapshot'; enabled = $true; priority = 2 }
        'gateway-configuration'              = [ordered]@{ location = 'LogRoot'; patterns = @('*ConfigurationProperties.json'); exclude = @(); format = 'json'; mode = 'snapshot'; enabled = $true; priority = 3 }
    }
    if ($Overrides) {
        foreach ($logType in $Overrides.Keys) {
            if (-not $catalog.Contains($logType)) { continue }
            $override = $Overrides[$logType]
            if ($override.Contains('enabled')) { $catalog[$logType].enabled = [bool]$override.enabled }
            if ($override.Contains('patterns')) { $catalog[$logType].patterns = @($override.patterns) }
            if ($override.Contains('exclude')) { $catalog[$logType].exclude = @($override.exclude) }
        }
    }
    return $catalog
}

function Get-GwmFileLogType {
    <# Classifies a file name for a location (LogRoot/Report); returns the log type or $null. #>
    param(
        [Parameter(Mandatory)][string] $FileName,
        [Parameter(Mandatory)][ValidateSet('LogRoot', 'Report')][string] $Location,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Catalog,
        [AllowNull()][string[]] $AllowedLogTypes
    )
    foreach ($logType in $Catalog.Keys) {
        $definition = $Catalog[$logType]
        if ($definition.location -ne $Location -or -not $definition.enabled) { continue }
        if ($AllowedLogTypes -and $logType -notin $AllowedLogTypes) { continue }
        $matched = $false
        foreach ($pattern in $definition.patterns) { if ($FileName -like $pattern) { $matched = $true; break } }
        if (-not $matched) { continue }
        $excluded = $false
        foreach ($pattern in $definition.exclude) { if ($FileName -like $pattern) { $excluded = $true; break } }
        if ($excluded) { continue }
        return $logType
    }
    return $null
}

function Get-GwmSourceFile {
    <# Enumerates the classified files of a source (top-level files of the log root and of the report folder). #>
    param(
        [Parameter(Mandatory)] $Source,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Catalog,
        [System.Collections.Generic.List[object]] $Issues
    )
    $allowed = if ($null -ne $Source.LogTypes) { [string[]]@($Source.LogTypes) } else { $null }
    $locations = [ordered]@{ LogRoot = $Source.LogPath; Report = $Source.ReportPath }
    $files = [System.Collections.Generic.List[object]]::new()
    foreach ($location in $locations.Keys) {
        $directory = $locations[$location]
        $expected = @($Catalog.Keys | Where-Object { $Catalog[$_].location -eq $location -and $Catalog[$_].enabled -and (-not $allowed -or $_ -in $allowed) })
        if ($expected.Count -eq 0) { continue }
        if ([string]::IsNullOrWhiteSpace($directory) -or -not [System.IO.Directory]::Exists($directory)) {
            if ($null -ne $Issues -and $location -eq 'Report') {
                $Issues.Add([pscustomobject]@{ Level = 'Warning'; Code = 'ReportFolderMissing'; Message = "Report folder '$directory' not found; query and counter reports are not collected (enable 'additional logging' / reports on the gateway)."; SourceName = $Source.Name; FileName = $null })
            }
            continue
        }
        try {
            $entries = [System.IO.DirectoryInfo]::new($directory).GetFiles()
        }
        catch {
            if ($null -ne $Issues) { $Issues.Add([pscustomobject]@{ Level = 'Error'; Code = 'FolderInaccessible'; Message = "Cannot list '$directory': $($_.Exception.Message)"; SourceName = $Source.Name; FileName = $null }) }
            continue
        }
        foreach ($entry in $entries) {
            $logType = Get-GwmFileLogType -FileName $entry.Name -Location $location -Catalog $Catalog -AllowedLogTypes $allowed
            if (-not $logType) { continue }
            $definition = $Catalog[$logType]
            $files.Add([pscustomobject]@{
                    Path             = $entry.FullName
                    Name             = $entry.Name
                    LogType          = $logType
                    Format           = $definition.format
                    Mode             = $definition.mode
                    Priority         = $definition.priority
                    Length           = $entry.Length
                    LastWriteTimeUtc = $entry.LastWriteTimeUtc
                    CreationTimeUtc  = $entry.CreationTimeUtc
                })
        }
    }
    return , $files.ToArray()
}
