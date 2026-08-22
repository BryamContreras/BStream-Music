param(
    [string]$InstallDirectory
)

$ErrorActionPreference = 'Stop'

# Keep this pinned. The Windows Flutter plugins invoke nuget.exe directly from
# CMake, so relying on whichever version happens to be on a developer machine
# makes local builds and hosted runners behave differently.
$nugetVersion = '6.12.2'
$nugetSha256 = '64f467376f2ee364ba389461df4a29a8f8dd9aa38120d29046e70b9c82045d97'
$downloadUri = "https://dist.nuget.org/win-x86-commandline/v$nugetVersion/nuget.exe"

if ([string]::IsNullOrWhiteSpace($InstallDirectory)) {
    if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
        $InstallDirectory = Join-Path $env:RUNNER_TEMP 'bstream-tools'
    } else {
        $InstallDirectory = Join-Path $env:LOCALAPPDATA 'BStream Music\tools'
    }
}

New-Item -ItemType Directory -Force -Path $InstallDirectory | Out-Null
$nugetPath = Join-Path $InstallDirectory 'nuget.exe'

$needsDownload = $true
if (Test-Path -LiteralPath $nugetPath) {
    $existingHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $nugetPath).Hash.ToLowerInvariant()
    $needsDownload = $existingHash -ne $nugetSha256
}

if ($needsDownload) {
    $downloadPath = Join-Path $InstallDirectory 'nuget.download.exe'
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $downloadUri -OutFile $downloadPath
        $downloadHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $downloadPath).Hash.ToLowerInvariant()
        if ($downloadHash -ne $nugetSha256) {
            throw "NuGet checksum mismatch. Expected $nugetSha256, got $downloadHash."
        }
        Move-Item -Force -LiteralPath $downloadPath -Destination $nugetPath
    } finally {
        if (Test-Path -LiteralPath $downloadPath) {
            Remove-Item -Force -LiteralPath $downloadPath
        }
    }
}

& $nugetPath help | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "NuGet CLI failed its self-check with exit code $LASTEXITCODE."
}

$nugetDirectory = Split-Path -Parent $nugetPath
$env:Path = "$nugetDirectory;$env:Path"
$env:NUGET_EXE = $nugetPath
$env:NUGET_EXECUTABLE = $nugetPath

# GitHub Actions steps do not inherit a child PowerShell process' environment.
# Persist the path for subsequent steps when the script runs on a hosted runner.
if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_PATH)) {
    Add-Content -Path $env:GITHUB_PATH -Value $nugetDirectory
}
if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_ENV)) {
    Add-Content -Path $env:GITHUB_ENV -Value "NUGET_EXE=$nugetPath"
    Add-Content -Path $env:GITHUB_ENV -Value "NUGET_EXECUTABLE=$nugetPath"
}

Write-Output $nugetPath
