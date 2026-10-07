function Get-GwmConfiguration {
    <#
    .SYNOPSIS
        Loads, merges (defaults + file + overrides) and validates the agent configuration.
    .PARAMETER Path
        JSON configuration file written by Install-Agent.ps1 (keys: docs/configuration.md).
    .PARAMETER InputObject
        Configuration as a hashtable/dictionary (tests, automation).
    .PARAMETER Override
        Dotted-path overrides, for example @{ 'agent.logLevel' = 'Debug'; environment = 'test' }.
    .PARAMETER SkipValidation
        Returns the merged configuration without validating it (Invoke-GatewayLogCollection.ps1 -Test reports the errors itself).
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path', Position = 0)][string] $Path,
        [Parameter(Mandatory, ParameterSetName = 'Object')][System.Collections.IDictionary] $InputObject,
        [hashtable] $Override,
        [switch] $SkipValidation
    )
    $fileConfiguration = if ($PSCmdlet.ParameterSetName -eq 'Path') { Read-GwmConfigurationFile -Path $Path } else { ConvertTo-GwmDictionary $InputObject }
    $configuration = Resolve-GwmConfiguration -FileConfiguration $fileConfiguration -Overrides $Override
    if (-not $SkipValidation) {
        $errors = Test-GwmConfigurationObject -Configuration $configuration
        if ($errors.Count -gt 0) {
            $exception = [System.ArgumentException]::new("Invalid agent configuration:`n - " + ($errors -join "`n - "))
            $exception.Data['GwmConfigurationError'] = $true
            throw $exception
        }
    }
    return $configuration
}
