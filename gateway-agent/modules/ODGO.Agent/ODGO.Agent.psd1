@{
    RootModule           = 'ODGO.Agent.psm1'
    ModuleVersion        = '1.0.0'
    GUID                 = '4c6f1a52-9d2e-4f0b-8a7e-3b5d1c9e2f60'
    Author               = 'ODGO contributors'
    CompanyName          = 'Community'
    Copyright            = '(c) ODGO contributors. MIT License.'
    Description          = 'Collects on-premises data gateway logs incrementally and uploads them to Microsoft Fabric OneLake with manifests and run telemetry.'
    PowerShellVersion    = '7.2'
    CompatiblePSEditions = @('Core')
    FunctionsToExport    = @('Get-GwmConfiguration', 'Invoke-GwmCollection', 'Set-GwmClientSecret', 'Test-GwmAgent')
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags         = @('PowerBI', 'Fabric', 'OneLake', 'Gateway', 'Monitoring')
            LicenseUri   = 'https://github.com/Pulsweb/ODGO/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/Pulsweb/ODGO'
            ReleaseNotes = 'See CHANGELOG.md'
        }
    }
}
