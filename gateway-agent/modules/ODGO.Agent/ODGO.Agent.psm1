#Requires -Version 7.2
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:GwmModuleRoot = $PSScriptRoot
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
