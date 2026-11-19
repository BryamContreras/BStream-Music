param(
    [ValidatePattern('^[a-zA-Z0-9_-]+$')][string]$Label = 'current',
    [ValidatePattern('^emulator-[0-9]+$')][string]$Device = 'emulator-5554',
    [ValidateRange(3, 20)][int]$Repetitions = 7,
    [ValidateRange(0.5, 20)][double]$AudioSeconds = 3,
    [string]$PresetFile,
    # Directory containing the production Java source files. Point this at a
    # saved copy to reproduce a baseline after the working sources are edited.
    [string]$SourceDirectory,
    [string]$AndroidSdk = "$env:LOCALAPPDATA\Android\Sdk",
    [string]$JavaDirectory = 'C:\Program Files\Android\Android Studio\jbr',
    [string]$GradleCache = "$env:USERPROFILE\.gradle\caches"
)

$ErrorActionPreference = 'Stop'

function Invoke-LoggedNative {
    param([string]$Executable, [string[]]$Arguments, [string]$LogFile)
    # Windows PowerShell 5.1 treats native stderr as an ErrorRecord. Compiler
    # warnings must not abort a successful compilation; the exit code decides.
    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $Executable @Arguments *> $LogFile
        $nativeExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedPreference
    }
    if ($nativeExitCode -ne 0) { throw "Native command failed ($nativeExitCode): $Executable; see $LogFile" }
}

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
if (-not $PresetFile) { $PresetFile = Join-Path $repoRoot '.dart_tool/eq-presets-ten.json' }
if (-not $SourceDirectory) {
    $SourceDirectory = Join-Path $repoRoot 'third_party/just_audio/android/src/main/java/com/ryanheise/just_audio'
}
$buildDirectory = Join-Path $repoRoot ".dart_tool/eq-bench-android/$Label"
$classesDirectory = Join-Path $buildDirectory 'classes'
New-Item -ItemType Directory -Path $classesDirectory -Force | Out-Null
$androidJar = Join-Path $AndroidSdk 'platforms/android-35/android.jar'
$d8Jar = Join-Path $AndroidSdk 'build-tools/35.0.0/lib/d8.jar'
$adb = Join-Path $AndroidSdk 'platform-tools/adb.exe'
$java = Join-Path $JavaDirectory 'bin/java.exe'
$javac = Join-Path $JavaDirectory 'bin/javac.exe'
$jar = Join-Path $JavaDirectory 'bin/jar.exe'
$media3 = Get-ChildItem -LiteralPath $GradleCache -Recurse -File -Filter classes.jar |
    Where-Object { $_.FullName -match 'media3-common-1\.4\.1[\\/]jars[\\/]classes\.jar$' } |
    Select-Object -First 1 -ExpandProperty FullName
$guava = Get-ChildItem -LiteralPath (Join-Path $GradleCache 'modules-2/files-2.1/com.google.guava/guava') -Recurse -File -Filter 'guava-33.0.0-android.jar' |
    Select-Object -First 1 -ExpandProperty FullName
$failureAccess = Get-ChildItem -LiteralPath (Join-Path $GradleCache 'modules-2/files-2.1/com.google.guava/failureaccess') -Recurse -File -Filter 'failureaccess-1.0.2.jar' |
    Select-Object -First 1 -ExpandProperty FullName
foreach ($required in @($androidJar, $d8Jar, $adb, $java, $javac, $jar, $media3, $guava, $failureAccess, $PresetFile)) {
    if (-not $required -or -not (Test-Path -LiteralPath $required)) { throw "Missing benchmark prerequisite: $required" }
}

$sources = @(
    (Join-Path $SourceDirectory 'BStreamEqualizerConfiguration.java'),
    (Join-Path $SourceDirectory 'BStreamEqualizerAudioProcessor.java'),
    (Join-Path $PSScriptRoot 'BStreamEqualizerBenchmark.java')
)
$classPath = @($androidJar, $media3, $guava, $failureAccess) -join ';'
Invoke-LoggedNative $javac (@('-encoding', 'UTF-8', '-source', '17', '-target', '17', '-classpath', $classPath, '-d', $classesDirectory) + $sources) (Join-Path $buildDirectory 'javac.log')
$compiledJar = Join-Path $buildDirectory 'benchmark-classes.jar'
Invoke-LoggedNative $jar @('--create', '--file', $compiledJar, '-C', $classesDirectory, '.') (Join-Path $buildDirectory 'jar.log')
$dexJar = Join-Path $buildDirectory 'benchmark-dex.jar'
Invoke-LoggedNative $java @('-cp', $d8Jar, 'com.android.tools.r8.D8', '--release', '--min-api', '24', '--lib', $androidJar, '--output', $dexJar, $compiledJar, $media3, $guava, $failureAccess) (Join-Path $buildDirectory 'd8.log')

$remoteJar = "/data/local/tmp/bstream-eq-benchmark-$Label.jar"
$remotePresets = "/data/local/tmp/bstream-eq-presets-$Label.json"
Invoke-LoggedNative $adb @('-s', $Device, 'push', $dexJar, $remoteJar) (Join-Path $buildDirectory 'push-jar.log')
Invoke-LoggedNative $adb @('-s', $Device, 'push', $PresetFile, $remotePresets) (Join-Path $buildDirectory 'push-presets.log')
$secondsArgument = $AudioSeconds.ToString([Globalization.CultureInfo]::InvariantCulture)
$rawLog = Join-Path $buildDirectory 'raw.log'
Invoke-LoggedNative $adb @('-s', $Device, 'shell', "CLASSPATH=$remoteJar app_process /system/bin com.ryanheise.just_audio.BStreamEqualizerBenchmark $remotePresets $Repetitions $secondsArgument $Label") $rawLog

$lines = @(Get-Content -LiteralPath $rawLog | Where-Object { $_.StartsWith('{') })
$results = @($lines | ForEach-Object { $_ | ConvertFrom-Json })
if (-not ($results | Where-Object { $_.type -eq 'complete' })) { throw "Benchmark did not complete; see $rawLog" }
$jsonLines = Join-Path $buildDirectory 'results.jsonl'
[IO.File]::WriteAllLines($jsonLines, [string[]]$lines, [Text.UTF8Encoding]::new($false))
$results | Where-Object { $_.type -eq 'case' } | Export-Csv -LiteralPath (Join-Path $buildDirectory 'results.csv') -NoTypeInformation -Encoding UTF8
Write-Output "Android ART benchmark complete: $jsonLines"
Write-Output "Cases: $(($results | Where-Object { $_.type -eq 'case' }).Count)"
