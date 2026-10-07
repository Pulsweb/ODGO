# Discovery of the server identity, the gateway installation, log folders and gateway/cluster identity.

$script:GwmDefaultLogRootSuffix = 'AppData\Local\Microsoft\On-premises data gateway'
$script:GwmHardwareInventory = $null

function Get-GwmHardwareInventory {
    <# Processor, memory and OS facts (CIM). Cached for the lifetime of the process; CIM failures are tolerated. #>
    if ($script:GwmHardwareInventory) { return $script:GwmHardwareInventory }
    $inventory = [pscustomobject]@{
        NumberOfCores     = $null
        LogicalProcessors = [Environment]::ProcessorCount
        TotalMemoryMB     = $null
        OsVersion         = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
        OsArchitecture    = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    }
    if ($IsWindows) {
        try {
            $processors = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop -Verbose:$false)
            $inventory.NumberOfCores = [int](($processors | Measure-Object -Property NumberOfCores -Sum).Sum)
            $inventory.LogicalProcessors = [int](($processors | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum)
            $system = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop -Verbose:$false
            $inventory.TotalMemoryMB = [long][Math]::Round($system.TotalPhysicalMemory / 1MB)
            $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop -Verbose:$false
            $inventory.OsVersion = '{0} ({1})' -f $os.Caption.Trim(), $os.Version
            $inventory.OsArchitecture = $os.OSArchitecture
        }
        catch {
            Write-GwmLog -Level Warning -EventName 'DiscoveryWarning' -Message "Hardware/OS inventory incomplete: $($_.Exception.Message)"
            return $inventory
        }
    }
    $script:GwmHardwareInventory = $inventory
    return $inventory
}

function Get-GwmMachineGuid {
    if ($IsWindows) {
        try {
            $value = Get-ItemPropertyValue -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name 'MachineGuid' -ErrorAction Stop
            if ($value) { return [pscustomobject]@{ Value = [string]$value; Source = 'MachineGuid' } }
        }
        catch { $null = $_ }
    }
    foreach ($path in @('/etc/machine-id', '/var/lib/dbus/machine-id')) {
        if (Test-Path -LiteralPath $path) {
            $value = (Get-Content -LiteralPath $path -Raw).Trim()
            if ($value) { return [pscustomobject]@{ Value = $value; Source = 'machine-id' } }
        }
    }
    return [pscustomobject]@{ Value = [Environment]::MachineName; Source = 'HostName' }
}

function Get-GwmServerIdentity {
    <# Server identity and hardware/OS facts (CIM failures are tolerated). #>
    param([AllowNull()][System.Collections.IDictionary] $ServerConfiguration)
    $name = if ($ServerConfiguration -and $ServerConfiguration.name) { [string]$ServerConfiguration.name } else { [Environment]::MachineName }
    $machine = Get-GwmMachineGuid
    $serverId = if ($ServerConfiguration -and $ServerConfiguration.id) { [string]$ServerConfiguration.id } else { Get-GwmServerIdFromMachineGuid $machine.Value }
    $fqdn = $null
    $domain = $null
    try {
        $properties = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
        $domain = if ($properties.DomainName) { $properties.DomainName } else { $null }
        $fqdn = if ($domain) { '{0}.{1}' -f $properties.HostName, $domain } else { $properties.HostName }
    }
    catch { $null = $_ }
    if ($ServerConfiguration -and $ServerConfiguration.name) { $fqdn = $null }
    $inventory = Get-GwmHardwareInventory
    $timeZone = [TimeZoneInfo]::Local
    [pscustomobject]@{
        Name              = $name
        PartitionName     = ConvertTo-GwmPartitionValue $name
        Id                = $serverId
        IdSource          = if ($ServerConfiguration -and $ServerConfiguration.id) { 'Configuration' } else { $machine.Source }
        Fqdn              = $fqdn
        Domain            = $domain
        NumberOfCores     = $inventory.NumberOfCores
        LogicalProcessors = $inventory.LogicalProcessors
        TotalMemoryMB     = $inventory.TotalMemoryMB
        OsVersion         = $inventory.OsVersion
        OsArchitecture    = $inventory.OsArchitecture
        TimeZoneId        = $timeZone.Id
        UtcOffsetMinutes  = [int]$timeZone.GetUtcOffset([DateTime]::UtcNow).TotalMinutes
    }
}

function Find-GwmGatewayLogRoot {
    <# Default service profile first, then any service/user profile that contains gateway logs (most recently written wins). #>
    [OutputType([string])]
    param()
    if (-not $IsWindows) { return $null }
    $windows = if ($env:windir) { $env:windir } else { 'C:\Windows' }
    $default = Join-Path $windows "ServiceProfiles\PBIEgwService\$script:GwmDefaultLogRootSuffix"
    if (Test-Path -LiteralPath $default) { return $default }
    $candidates = [System.Collections.Generic.List[object]]::new()
    $roots = @((Join-Path $windows 'ServiceProfiles'), (Join-Path ($env:SystemDrive + '\') 'Users'))
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($userProfile in Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue) {
            $path = Join-Path $userProfile.FullName $script:GwmDefaultLogRootSuffix
            if (-not (Test-Path -LiteralPath $path)) { continue }
            $latest = Get-ChildItem -LiteralPath $path -Filter 'Gateway*.log' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
            if ($latest) { $candidates.Add([pscustomobject]@{ Path = $path; LastWrite = $latest.LastWriteTimeUtc }) }
        }
    }
    $best = $candidates | Sort-Object LastWrite -Descending | Select-Object -First 1
    if ($best) { return $best.Path }
    return $null
}

function Get-GwmGatewayService {
    <# Gateway Windows service state, executable path and product version. #>
    param([string] $ServiceName = 'PBIEgwService')
    if (-not $IsWindows -or [string]::IsNullOrWhiteSpace($ServiceName)) { return $null }
    try {
        $escaped = $ServiceName.Replace("'", "\'")
        $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='$escaped'" -ErrorAction Stop -Verbose:$false
    }
    catch { return $null }
    if (-not $service) { return $null }
    $exePath = $null
    if ($service.PathName -match '^\s*"([^"]+)"') { $exePath = $Matches[1] }
    elseif ($service.PathName -match '^\s*(\S+\.exe)') { $exePath = $Matches[1] }
    $version = $null
    if ($exePath -and (Test-Path -LiteralPath $exePath)) {
        try { $version = (Get-Item -LiteralPath $exePath).VersionInfo.ProductVersion } catch { $null = $_ }
    }
    [pscustomobject]@{
        Name        = $service.Name
        Status      = [string]$service.State
        StartName   = $service.StartName
        ExePath     = $exePath
        InstallPath = if ($exePath) { Split-Path -Parent $exePath } else { $null }
        Version     = if ($version) { $version.Trim() } else { $null }
    }
}

function Read-GwmJsonDocument {
    <# Tolerant JSON reader for gateway metadata files (shared read, BOM aware). Returns $null when missing or invalid. #>
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [System.IO.File]::Exists($Path)) { return $null }
    try {
        $stream = Open-GwmSharedFile -Path $Path -RetryCount 1
        try { $bytes = Read-GwmFileRange -Stream $stream -Offset 0 -Count ([Math]::Min($stream.Length, 16MB)) } finally { $stream.Dispose() }
        $text = [System.Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF)
        return , ($text | ConvertFrom-Json -Depth 32 -NoEnumerate)
    }
    catch {
        Write-GwmLog -Level Warning -EventName 'MetadataFileInvalid' -Message "Cannot read '$Path': $($_.Exception.Message)"
        return $null
    }
}

function ConvertTo-GwmGuid {
    [OutputType([string])]
    param([AllowNull()] $Value)
    if ($null -eq $Value) { return $null }
    $text = ([string]$Value).Trim().Trim('{', '}').ToLowerInvariant()
    if ($text -match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' -and $text -ne '00000000-0000-0000-0000-000000000000') { return $text }
    return $null
}

function Get-GwmGatewayIdFromReport {
    <# Reads GatewayObjectId from the first data row of the most recent report file (same approach as pbigtwmonitor). #>
    param([string] $ReportPath)
    if ([string]::IsNullOrWhiteSpace($ReportPath) -or -not [System.IO.Directory]::Exists($ReportPath)) { return $null }
    # Directory entries of files held open by the gateway can report a stale length: read every candidate.
    $files = Get-ChildItem -LiteralPath $ReportPath -Filter '*Report*.log' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending
    foreach ($file in $files) {
        try {
            $stream = Open-GwmSharedFile -Path $file.FullName -RetryCount 1
            try { $bytes = Read-GwmFileRange -Stream $stream -Offset 0 -Count ([Math]::Min($stream.Length, 65536)) } finally { $stream.Dispose() }
            $lines = @(([System.Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF)) -split "`r?`n" | Where-Object { $_ -ne '' } | Select-Object -First 2)
            if ($lines.Count -lt 2) { continue }
            $row = @($lines | ConvertFrom-Csv) | Select-Object -First 1
            if ($row -and $row.PSObject.Properties['GatewayObjectId']) {
                $id = ConvertTo-GwmGuid $row.GatewayObjectId
                if ($id) { return $id }
            }
        }
        catch { continue }
    }
    return $null
}

function Resolve-GwmSource {
    <# Resolves folders, service facts and gateway/cluster identity of a configured source. #>
    param([Parameter(Mandatory)][System.Collections.IDictionary] $SourceConfiguration)
    $logPath = $SourceConfiguration.logPath
    if (-not $logPath) { $logPath = Find-GwmGatewayLogRoot }
    $reportPath = $SourceConfiguration.reportPath
    if (-not $reportPath -and $logPath) { $reportPath = Join-Path $logPath 'Report' }
    $service = Get-GwmGatewayService -ServiceName $SourceConfiguration.serviceName
    $properties = if ($logPath) { Read-GwmJsonDocument (Join-Path $logPath 'GatewayProperties.txt') } else { $null }
    $clusters = if ($logPath) { Read-GwmJsonDocument (Join-Path $logPath 'GatewayClusters.txt') } else { $null }

    $gatewayId = ConvertTo-GwmGuid $SourceConfiguration.gatewayId
    $gatewayIdSource = if ($gatewayId) { 'Configuration' } else { $null }
    if (-not $gatewayId -and $properties -and $properties.PSObject.Properties['GatewayObjectId']) {
        $gatewayId = ConvertTo-GwmGuid $properties.GatewayObjectId
        if ($gatewayId) { $gatewayIdSource = 'GatewayProperties' }
    }
    if (-not $gatewayId) {
        $gatewayId = Get-GwmGatewayIdFromReport -ReportPath $reportPath
        if ($gatewayId) { $gatewayIdSource = 'ReportFile' }
    }

    $gatewayName = $SourceConfiguration.gatewayName
    if (-not $gatewayName -and $properties -and $properties.PSObject.Properties['GatewayName']) { $gatewayName = [string]$properties.GatewayName }

    $clusterId = ConvertTo-GwmGuid $SourceConfiguration.clusterId
    $clusterName = $SourceConfiguration.clusterName
    $clusterSource = if ($clusterId -or $clusterName) { 'Configuration' } else { $null }
    if ($gatewayId -and $clusters -and (-not $clusterId -or -not $clusterName)) {
        $list = if ($clusters -is [array]) { $clusters } elseif ($clusters.PSObject.Properties['value']) { @($clusters.value) } else { @() }
        foreach ($cluster in $list) {
            $members = if ($cluster.PSObject.Properties['gateways']) { @($cluster.gateways) } else { @() }
            $isMember = @($members | Where-Object { $_ -and $_.PSObject.Properties['gatewayObjectId'] -and (ConvertTo-GwmGuid $_.gatewayObjectId) -eq $gatewayId }).Count -gt 0
            if (-not $isMember) { continue }
            if (-not $clusterName -and $cluster.PSObject.Properties['name']) { $clusterName = [string]$cluster.name }
            if (-not $clusterId) {
                foreach ($property in @('id', 'objectId', 'clusterObjectId')) {
                    if ($cluster.PSObject.Properties[$property]) { $clusterId = ConvertTo-GwmGuid $cluster.$property; if ($clusterId) { break } }
                }
            }
            if (-not $clusterSource) { $clusterSource = 'GatewayClusters' }
            break
        }
    }
    if (-not $clusterName -and $properties -and $properties.PSObject.Properties['GatewayCluster'] -and $properties.GatewayCluster) {
        $clusterName = [string]$properties.GatewayCluster
        if (-not $clusterSource) { $clusterSource = 'GatewayProperties' }
    }
    if (-not $clusterSource) { $clusterSource = 'Default' }

    $version = if ($service) { $service.Version } else { $null }
    if (-not $version -and $properties -and $properties.PSObject.Properties['LocalVersionNumber'] -and $properties.LocalVersionNumber) {
        $version = ([string]$properties.LocalVersionNumber -split ': ')[-1].Trim()
    }

    [pscustomobject]@{
        Name            = $SourceConfiguration.name
        LogPath         = $logPath
        ReportPath      = $reportPath
        LogTypes        = $SourceConfiguration.logTypes
        ServiceName     = $SourceConfiguration.serviceName
        ServiceStatus   = if ($service) { $service.Status } else { $null }
        InstallPath     = if ($service) { $service.InstallPath } else { $null }
        GatewayVersion  = $version
        GatewayId       = $gatewayId
        GatewayIdSource = $gatewayIdSource
        GatewayName     = if ($gatewayName) { $gatewayName } else { $null }
        ClusterId       = $clusterId
        ClusterName     = if ($clusterName) { $clusterName } else { $null }
        ClusterSource   = $clusterSource
        PathClusterId   = if ($clusterId) { $clusterId } elseif ($gatewayId) { $gatewayId } else { $null }
    }
}
