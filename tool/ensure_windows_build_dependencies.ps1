[CmdletBinding()]
param(
    [string] $RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [string] $InstallDirectory = (Join-Path $env:LOCALAPPDATA 'BStream Music\tools')
)

$ErrorActionPreference = 'Stop'

# Keep the NuGet bootstrap shared with CI.  The script is idempotent and
# verifies the pinned executable before using it.
$nugetScript = Join-Path $PSScriptRoot 'ensure_nuget.ps1'
$nugetPath = & $nugetScript -InstallDirectory $InstallDirectory
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $nugetPath)) {
    throw "NuGet bootstrap failed."
}

# smtc_windows 1.1.0 walks the Windows path one component at a time.  Its
# resolver omitted -Force, so the hidden AppData component looked missing on
# a normal Windows installation (and on windows-2022 runners).  Patch only
# that exact dependency script; newer versions that already contain -Force
# are left untouched.
$resolver = Join-Path $RepositoryRoot 'windows\flutter\ephemeral\.plugin_symlinks\smtc_windows\cargokit\cmake\resolve_symlinks.ps1'
if (Test-Path -LiteralPath $resolver) {
    $content = [IO.File]::ReadAllText($resolver)
    if ($content -notmatch 'Get-Item\s+-Force\s+\$realPath') {
        $legacy = 'Get-Item $realPath'
        if (-not $content.Contains($legacy)) {
            throw "Unsupported smtc_windows resolver: $resolver"
        }
        $patched = $content.Replace($legacy, 'Get-Item -Force $realPath')
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [IO.File]::WriteAllText($resolver, $patched, $utf8)
    }
}

Write-Output $nugetPath
