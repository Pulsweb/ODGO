#Requires -Version 5.1
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if ($PSVersionTable.PSEdition -eq 'Desktop') {
    # Windows PowerShell 5.1 (.NET Framework) doesn't load these assemblies by default: HttpClient, DPAPI, JSON parser.
    Add-Type -AssemblyName System.Net.Http, System.Security, System.Web.Extensions
    # Microsoft Entra ID and OneLake require TLS 1.2, which older .NET Framework defaults don't offer. SystemDefault (0)
    # lets Windows choose and already includes it.
    $protocols = [System.Net.ServicePointManager]::SecurityProtocol
    if ([int]$protocols -ne 0 -and -not ($protocols -band [System.Net.SecurityProtocolType]::Tls12)) {
        [System.Net.ServicePointManager]::SecurityProtocol = $protocols -bor [System.Net.SecurityProtocolType]::Tls12
    }
}

$script:GwmModuleRoot = $PSScriptRoot
$script:GwmIsWindows = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
# Agent folder: the module is installed in <agent folder>\modules\ODGO.Agent. The default paths of the configuration,
# client secret, state and logs are in this folder.
$script:GwmAgentRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$script:GwmAgentVersion = $null
$script:GwmLog = $null
$script:GwmTokenCache = @{}

foreach ($folder in @('Private', 'Public')) {
    $path = Join-Path $PSScriptRoot $folder
    if (-not (Test-Path -LiteralPath $path)) { continue }
    foreach ($file in Get-ChildItem -LiteralPath $path -Filter '*.ps1' -File | Sort-Object Name) {
        . $file.FullName
    }
}

$manifestPath = Join-Path $PSScriptRoot 'ODGO.Agent.psd1'
$script:GwmAgentVersion = (Import-PowerShellDataFile -LiteralPath $manifestPath).ModuleVersion

Export-ModuleMember -Function @('Get-GwmConfiguration', 'Invoke-GwmCollection', 'Set-GwmClientSecret', 'Test-GwmAgent')
