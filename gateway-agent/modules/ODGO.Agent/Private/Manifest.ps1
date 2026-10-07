# Manifest, run telemetry and agent-metadata documents (read by the nb_gwmon_ingest notebook).

function ConvertTo-GwmJsonBytes {
    [OutputType([byte[]])]
    param([Parameter(Mandatory)] $Document)
    $json = $Document | ConvertTo-Json -Depth 16 -WarningAction SilentlyContinue
    return , ([System.Text.UTF8Encoding]::new($false).GetBytes($json))
}

function New-GwmAgentBlock {
    param([Parameter(Mandatory)] $Server, [Parameter(Mandatory)][string] $InstanceId)
    [ordered]@{
        instanceId       = $InstanceId
        version          = $script:GwmAgentVersion
        serverName       = $Server.PartitionName
        serverFqdn       = $Server.Fqdn
        serverId         = $Server.Id
        timeZoneId       = $Server.TimeZoneId
        utcOffsetMinutes = $Server.UtcOffsetMinutes
    }
}

function Format-GwmUtcOrNull {
    param([AllowNull()] $Value)
    $date = ConvertTo-GwmDateTime $Value
    if ($null -eq $date) { return $null }
    return Format-GwmUtc $date
}

function New-GwmManifestSegment {
    <# Manifest entry of an uploaded item (journal item with Sha256/ByteCount/UploadedUtc filled). #>
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Item)
    [ordered]@{
        segmentId          = $Item.segmentId
        path               = $Item.rawPath
        logType            = $Item.logType
        format             = $Item.format
        uploadMode         = $Item.uploadMode
        sourceName         = $Item.sourceName
        sourceFileName     = $Item.fileName
        sourceFilePath     = $Item.filePath
        sourceFingerprint  = $Item.fingerprint
        sourceCreationUtc  = Format-GwmUtcOrNull $Item.sourceCreationUtc
        sourceLastWriteUtc = Format-GwmUtcOrNull $Item.sourceLastWriteUtc
        sourceSizeBytes    = $Item.sourceSizeBytes
        offsetStart        = [long]$Item.offsetStart
        offsetEnd          = [long]$Item.offsetEnd
        byteCount          = [long]$Item.byteCount
        headerBytes        = [long]$Item.headerBytes
        sha256             = $Item.sha256
        uploadedUtc        = Format-GwmUtcOrNull $Item.uploadedUtc
        gatewayId          = $Item.gatewayId
        gatewayName        = $Item.gatewayName
        clusterId          = $Item.clusterId
        clusterName        = $Item.clusterName
    }
}

function New-GwmManifestDocument {
    param(
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][string] $Environment,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Agent,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Items,
        [datetime] $CreatedUtc = [DateTime]::UtcNow
    )
    [ordered]@{
        schemaVersion = '1.0'
        documentType  = 'gwmon.manifest'
        runId         = $RunId
        createdUtc    = Format-GwmUtc $CreatedUtc
        environment   = $Environment
        agent         = $Agent
        segments      = @($Items | ForEach-Object { New-GwmManifestSegment -Item $_ })
    }
}

function New-GwmAgentMetadataDocument {
    <# Successor of the original GatewayProperties.json: gateway and server facts discovered by the agent. #>
    param(
        [Parameter(Mandatory)] $Source,
        [Parameter(Mandatory)] $Server,
        [Parameter(Mandatory)][string] $Environment,
        [Parameter(Mandatory)][string] $InstanceId,
        [datetime] $CollectedUtc = [DateTime]::UtcNow
    )
    [ordered]@{
        schemaVersion = '1.0'
        documentType  = 'gwmon.agent-metadata'
        collectedUtc  = Format-GwmUtc $CollectedUtc
        environment   = $Environment
        agent         = [ordered]@{ instanceId = $InstanceId; version = $script:GwmAgentVersion }
        gateway       = [ordered]@{
            sourceName      = $Source.Name
            gatewayId       = $Source.GatewayId
            gatewayName     = $Source.GatewayName
            clusterId       = $Source.ClusterId
            clusterName     = $Source.ClusterName
            version         = $Source.GatewayVersion
            serviceName     = $Source.ServiceName
            serviceStatus   = $Source.ServiceStatus
            installPath     = $Source.InstallPath
            logPath         = $Source.LogPath
            reportPath      = $Source.ReportPath
            gatewayIdSource = $Source.GatewayIdSource
            clusterSource   = $Source.ClusterSource
        }
        server        = [ordered]@{
            serverName                = $Server.PartitionName
            serverFqdn                = $Server.Fqdn
            serverId                  = $Server.Id
            domain                    = $Server.Domain
            numberOfCores             = $Server.NumberOfCores
            numberOfLogicalProcessors = $Server.LogicalProcessors
            totalMemoryMB             = $Server.TotalMemoryMB
            osVersion                 = $Server.OsVersion
            osArchitecture            = $Server.OsArchitecture
            timeZoneId                = $Server.TimeZoneId
            utcOffsetMinutes          = $Server.UtcOffsetMinutes
        }
    }
}

function New-GwmTelemetryDocument {
    param(
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][string] $Environment,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Agent,
        [Parameter(Mandatory)][datetime] $StartedUtc,
        [Parameter(Mandatory)][datetime] $EndedUtc,
        [Parameter(Mandatory)][ValidateSet('Succeeded', 'PartiallySucceeded', 'Failed')][string] $Status,
        [Parameter(Mandatory)][ValidateSet('Scheduled', 'Manual', 'Validation', 'Test')][string] $Trigger,
        [AllowNull()][string] $AuthMode,
        [AllowNull()][string] $TargetType,
        [AllowNull()][string] $ConfigHash,
        [AllowNull()][string] $ManifestPath,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Counts,
        [AllowEmptyCollection()][object[]] $Gateways = @(),
        [AllowEmptyCollection()][object[]] $Issues = @()
    )
    $issueList = foreach ($issue in @($Issues | Select-Object -First 50)) {
        $message = Protect-GwmText ([string]$issue.Message)
        if ($message.Length -gt 2000) { $message = $message.Substring(0, 1997) + '...' }
        $code = [string]$issue.Code
        if ($code.Length -gt 64) { $code = $code.Substring(0, 64) }
        [ordered]@{ level = [string]$issue.Level; code = $code; message = $message; sourceName = $issue.SourceName; fileName = $issue.FileName }
    }
    [ordered]@{
        schemaVersion     = '1.0'
        documentType      = 'gwmon.run'
        runId             = $RunId
        environment       = $Environment
        agent             = $Agent
        startedUtc        = Format-GwmUtc $StartedUtc
        endedUtc          = Format-GwmUtc $EndedUtc
        durationMs        = [long][Math]::Max(0, ($EndedUtc - $StartedUtc).TotalMilliseconds)
        status            = $Status
        trigger           = $Trigger
        authMode          = $AuthMode
        targetType        = $TargetType
        configHash        = $ConfigHash
        powershellVersion = $PSVersionTable.PSVersion.ToString()
        osVersion         = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
        manifestPath      = $ManifestPath
        counts            = $Counts
        gateways          = @($Gateways | Select-Object -First 64)
        issues            = @($issueList)
    }
}
