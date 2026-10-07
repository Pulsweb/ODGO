function Set-GwmClientSecret {
    <#
    .SYNOPSIS
        Stores the app registration client secret encrypted with DPAPI (machine scope).
    .DESCRIPTION
        Any process of this server could decrypt the file, so the folder ACL is what protects it: the folder must exist
        and must not let broad groups (Users, Everyone, ...) read the files it contains. Install-Agent.ps1 creates the
        folder restricted to SYSTEM, Administrators and the scheduled task identity, and calls this function
        (Install-Agent.ps1 -UpdateSecret rotates the secret).
    .PARAMETER Secret
        The client secret value (not the secret id).
    .PARAMETER Path
        Default: authentication.clientSecretPath (config\client-secret.dat in the agent folder).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][securestring] $Secret,
        [string] $Path = (Get-GwmDefaultConfiguration).authentication.clientSecretPath
    )
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $folder = [System.IO.Path]::GetDirectoryName($fullPath)
    if (-not [System.IO.Directory]::Exists($folder)) { throw "Folder '$folder' not found: run Install-Agent.ps1, which creates it with restricted access." }
    Assert-GwmPrivateFolder -Path $folder
    $protected = Protect-GwmSecret -Secret $Secret
    if ($PSCmdlet.ShouldProcess($fullPath, 'Store the encrypted client secret')) {
        # A new file gets the folder's permissions; replacing the old one leaves no stale permissions behind.
        $temporary = Join-Path $folder ('.client-secret-{0}.tmp' -f [guid]::NewGuid().ToString('n'))
        try {
            [System.IO.File]::WriteAllBytes($temporary, $protected)
            if ([System.IO.File]::Exists($fullPath)) { [System.IO.File]::Delete($fullPath) }
            [System.IO.File]::Move($temporary, $fullPath)
        }
        finally {
            if ([System.IO.File]::Exists($temporary)) { [System.IO.File]::Delete($temporary) }
        }
        Clear-GwmTokenCache
    }
}
