param(
  [string]$Python,
  [int]$Jobs = 28,
  [switch]$Clean,
  [switch]$CompileDependencies,
  [switch]$ShowProgress
)

$ErrorActionPreference = 'Stop'

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$bridgeScript = Join-Path $PSScriptRoot 'tiktok_live_bridge.py'
$requirements = Join-Path $PSScriptRoot 'requirements-tiktok.txt'
$buildRoot = Join-Path $projectRoot 'build\tiktok-live-bridge'
$venvDir = Join-Path $buildRoot '.venv'
$nuitkaOutputDir = Join-Path $buildRoot 'nuitka'
$iconPath = Join-Path $projectRoot 'windows\runner\resources\app_icon.ico'
$targetDir = Join-Path $projectRoot 'windows\tools\tiktok-live-bridge'

function Resolve-PackagingPython {
  if ($Python -and $Python.Trim()) {
    return $Python.Trim()
  }

  if ($env:BSTREAM_TIKTOK_PYTHON -and $env:BSTREAM_TIKTOK_PYTHON.Trim()) {
    return $env:BSTREAM_TIKTOK_PYTHON.Trim()
  }

  try {
    $pyList = & py -0p 2>$null
    foreach ($line in $pyList) {
      if ($line -match '3\.12' -and $line -match '([A-Za-z]:\\.*python\.exe)$') {
        return $Matches[1]
      }
    }
  } catch {
    # Fall through to PATH-based discovery below.
  }

  foreach ($candidate in @('python', 'python3')) {
    try {
      $version = & $candidate -c 'import sys; print(".".join(map(str, sys.version_info[:2])))' 2>$null
      if ($LASTEXITCODE -eq 0 -and [version]$version -ge [version]'3.11' -and [version]$version -lt [version]'3.14') {
        return $candidate
      }
    } catch {
      # Try the next candidate.
    }
  }

  throw 'No encontre Python 3.11-3.13 para empaquetar. Define BSTREAM_TIKTOK_PYTHON con la ruta a python.exe.'
}

function Assert-InProject {
  param([string]$Path)

  $fullPath = [System.IO.Path]::GetFullPath($Path)
  if (-not $fullPath.StartsWith($projectRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Ruta fuera del proyecto: $fullPath"
  }
  return $fullPath
}

function Copy-DependencyItem {
  param(
    [string]$SitePackages,
    [string]$Name,
    [string]$Destination
  )

  $source = Join-Path $SitePackages $Name
  if (-not (Test-Path -LiteralPath $source)) {
    throw "No encontre dependencia runtime en site-packages: $Name"
  }

  $target = Assert-InProject (Join-Path $Destination $Name)
  if (Test-Path -LiteralPath $target) {
    Remove-Item -LiteralPath $target -Recurse -Force
  }
  Copy-Item -LiteralPath $source -Destination $Destination -Recurse -Force
}

function Copy-DependencyMetadata {
  param(
    [string]$SitePackages,
    [string]$Pattern,
    [string]$Destination
  )

  $matches = @(Get-ChildItem -LiteralPath $SitePackages -Directory -Filter $Pattern)
  if ($matches.Count -eq 0) {
    throw "No encontre metadata runtime en site-packages: $Pattern"
  }

  foreach ($match in $matches) {
    Copy-DependencyItem -SitePackages $SitePackages -Name $match.Name -Destination $Destination
  }
}

function Remove-RuntimeCache {
  param([string]$Destination)

  $safeDestination = Assert-InProject $Destination
  Get-ChildItem -LiteralPath $safeDestination -Directory -Recurse -Filter '__pycache__' |
    Sort-Object FullName -Descending |
    Remove-Item -Recurse -Force
  Get-ChildItem -LiteralPath $safeDestination -File -Recurse |
    Where-Object { $_.Extension -in @('.pyc', '.pyo') } |
    Remove-Item -Force
  Get-ChildItem -LiteralPath $safeDestination -Directory -Recurse |
    Where-Object { $_.Name -in @('tests', 'test', 'testing') } |
    Sort-Object FullName -Descending |
    Remove-Item -Recurse -Force
}

function Copy-RuntimeDependencies {
  param(
    [string]$PythonExe,
    [string]$Destination
  )

  $sitePackages = (& $PythonExe -c "import sysconfig; print(sysconfig.get_paths()['purelib'])").Trim()
  if (-not (Test-Path -LiteralPath $sitePackages)) {
    throw "No encontre site-packages en: $sitePackages"
  }

  $runtimePackages = @(
    'TikTokLive',
    'anyio',
    'async_timeout',
    'betterproto',
    'certifi',
    'dateutil',
    'ffmpy',
    'google',
    'grpclib',
    'h11',
    'h2',
    'hpack',
    'httpcore',
    'httpx',
    'hyperframe',
    'idna',
    'mashumaro',
    'multidict',
    'pyee',
    'python_socks',
    'websockets',
    'websockets_proxy',
    'zstandard'
  )
  $runtimeModules = @(
    'protobuf_to_dict.py',
    'six.py',
    'typing_extensions.py'
  )
  $metadataPatterns = @(
    'anyio-*.dist-info',
    'async_timeout-*.dist-info',
    'betterproto-*.dist-info',
    'certifi-*.dist-info',
    'ffmpy-*.dist-info',
    'grpclib-*.dist-info',
    'h11-*.dist-info',
    'h2-*.dist-info',
    'hpack-*.dist-info',
    'httpcore-*.dist-info',
    'httpx-*.dist-info',
    'hyperframe-*.dist-info',
    'idna-*.dist-info',
    'mashumaro-*.dist-info',
    'multidict-*.dist-info',
    'protobuf-*.dist-info',
    'protobuf3_to_dict-*.dist-info',
    'pyee-*.dist-info',
    'python_dateutil-*.dist-info',
    'python_socks-*.dist-info',
    'six-*.dist-info',
    'tiktoklive-*.dist-info',
    'typing_extensions-*.dist-info',
    'websockets-*.dist-info',
    'websockets_proxy-*.dist-info',
    'zstandard-*.dist-info'
  )

  Write-Host "Copiando dependencias runtime necesarias desde: $sitePackages"
  foreach ($package in $runtimePackages) {
    Copy-DependencyItem -SitePackages $sitePackages -Name $package -Destination $Destination
  }
  foreach ($module in $runtimeModules) {
    Copy-DependencyItem -SitePackages $sitePackages -Name $module -Destination $Destination
  }
  foreach ($pattern in $metadataPatterns) {
    Copy-DependencyMetadata -SitePackages $sitePackages -Pattern $pattern -Destination $Destination
  }
  Remove-RuntimeCache -Destination $Destination
}

$pythonExe = Resolve-PackagingPython
Write-Host "Usando Python para empaquetar: $pythonExe"
if ($Jobs -lt 1) {
  throw 'Jobs debe ser 1 o mayor.'
}
if ($CompileDependencies) {
  Write-Host "Compilacion Nuitka onedir completa con $Jobs jobs."
} else {
  Write-Host "Compilacion Nuitka rapida: solo bridge compilado; dependencias copiadas como runtime."
}

New-Item -ItemType Directory -Force -Path $buildRoot | Out-Null

$versionLine = Get-Content (Join-Path $projectRoot 'pubspec.yaml') |
  Where-Object { $_ -match '^version:\s*([0-9]+)\.([0-9]+)\.([0-9]+)\+([0-9]+)\s*$' } |
  Select-Object -First 1
if ($versionLine -match '^version:\s*([0-9]+)\.([0-9]+)\.([0-9]+)\+([0-9]+)\s*$') {
  $major = [int]$Matches[1]
  $minor = [int]$Matches[2]
  $patch = [int]$Matches[3]
  $build = [int]$Matches[4]
} else {
  $major = 1
  $minor = 0
  $patch = 0
  $build = 0
}
$metadataVersion = "$major.$minor.$patch.$build"
$companyName = 'BStream Music'
$productName = 'BStream Music'
$copyright = "Copyright (C) 2026 $companyName. All rights reserved."

$createdVenv = $false
if (-not (Test-Path (Join-Path $venvDir 'Scripts\python.exe'))) {
  & $pythonExe -m venv $venvDir
  $createdVenv = $true
}

$venvPython = Join-Path $venvDir 'Scripts\python.exe'
if ($createdVenv) {
  & $venvPython -m pip install --disable-pip-version-check --upgrade pip
}
& $venvPython -m pip install --disable-pip-version-check -r $requirements nuitka ordered-set zstandard

$safeNuitkaOutput = Assert-InProject $nuitkaOutputDir
if ($Clean -and (Test-Path -LiteralPath $safeNuitkaOutput)) {
  Write-Host "Limpiando salida previa de Nuitka..."
  Remove-Item -LiteralPath $safeNuitkaOutput -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $safeNuitkaOutput | Out-Null

$nuitkaArgs = @(
  '--mode=standalone',
  '--deployment',
  '--assume-yes-for-downloads',
  '--msvc=latest',
  "--jobs=$Jobs",
  '--lto=no',
  '--python-flag=no_docstrings',
  "--output-dir=$safeNuitkaOutput",
  '--output-filename=tiktok_live_bridge.exe',
  "--windows-icon-from-ico=$iconPath",
  "--company-name=$companyName",
  "--product-name=$productName",
  "--file-version=$metadataVersion",
  "--product-version=$metadataVersion",
  '--file-description=BStream Music TikTok LIVE Bridge',
  "--copyright=$copyright",
  '--nofollow-import-to=*.tests',
  '--nofollow-import-to=*.testing',
  '--nofollow-import-to=trio',
  '--nofollow-import-to=anyio._backends._trio',
  '--noinclude-pytest-mode=nofollow',
  '--noinclude-unittest-mode=nofollow',
  '--noinclude-pydoc-mode=nofollow',
  '--noinclude-IPython-mode=nofollow',
  '--noinclude-setuptools-mode=nofollow'
)

if ($ShowProgress) {
  $nuitkaArgs += '--show-progress'
}

if ($CompileDependencies) {
  $nuitkaArgs += @(
    '--include-package-data=TikTokLive',
    '--include-module=websockets_proxy',
    '--include-module=python_socks.async_.asyncio.v2',
    '--include-module=python_socks.sync.v2',
    '--nofollow-import-to=TikTokLive.proto',
    '--nofollow-import-to=TikTokLive.proto.*'
  )
} else {
  $runtimeImportRoots = @(
    'TikTokLive',
    'anyio',
    'async_timeout',
    'betterproto',
    'certifi',
    'dateutil',
    'ffmpy',
    'google',
    'grpclib',
    'h11',
    'h2',
    'hpack',
    'httpcore',
    'httpx',
    'hyperframe',
    'idna',
    'mashumaro',
    'multidict',
    'pyee',
    'protobuf_to_dict',
    'python_socks',
    'six',
    'typing_extensions',
    'websockets',
    'websockets_proxy',
    'zstandard'
  )
  foreach ($root in $runtimeImportRoots) {
    $nuitkaArgs += "--nofollow-import-to=$root"
  }

  $runtimeStdlibModules = @(
    'base64',
    'calendar',
    'csv',
    'dataclasses',
    'datetime',
    'decimal',
    'gzip',
    'hashlib',
    'http.cookiejar',
    'http.cookies',
    'importlib.metadata',
    'importlib.resources',
    'ipaddress',
    'mimetypes',
    'netrc',
    'pathlib',
    'platform',
    'shlex',
    'ssl',
    'urllib.error',
    'urllib.parse',
    'urllib.request',
    'urllib.response',
    'uuid',
    'zipfile'
  )
  foreach ($module in $runtimeStdlibModules) {
    $nuitkaArgs += "--include-module=$module"
  }
}

& $venvPython -m nuitka @nuitkaArgs $bridgeScript

$builtDir = Join-Path $safeNuitkaOutput 'tiktok_live_bridge.dist'
$builtExe = Join-Path $builtDir 'tiktok_live_bridge.exe'
if (-not (Test-Path -LiteralPath $builtExe)) {
  throw "Nuitka no genero $builtExe"
}

if ($CompileDependencies) {
  $tiktokProtoSource = (& $venvPython -c "import pathlib, TikTokLive; print(pathlib.Path(TikTokLive.__file__).parent / 'proto')").Trim()
  $protoTargetParent = Join-Path $builtDir 'TikTokLive'
  $protoTarget = Join-Path $protoTargetParent 'proto'
  if (Test-Path -LiteralPath $protoTarget) {
    Remove-Item -LiteralPath $protoTarget -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path $protoTargetParent | Out-Null
  Copy-Item -LiteralPath $tiktokProtoSource -Destination $protoTargetParent -Recurse -Force
} else {
  Copy-RuntimeDependencies -PythonExe $venvPython -Destination $builtDir
}

$safeTarget = Assert-InProject $targetDir
if (Test-Path -LiteralPath $safeTarget) {
  Remove-Item -LiteralPath $safeTarget -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $safeTarget | Out-Null
Copy-Item -Path (Join-Path $builtDir '*') -Destination $safeTarget -Recurse -Force

$targetExe = Join-Path $safeTarget 'tiktok_live_bridge.exe'
$selfTest = & $targetExe --self-test
if ($LASTEXITCODE -ne 0) {
  throw "El self-test del puente empaquetado fallo: $selfTest"
}

Write-Host $selfTest
Write-Host "Puente TikTok LIVE empaquetado en: $safeTarget"
