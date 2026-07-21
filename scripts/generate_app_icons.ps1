Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Drawing

$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$SourceCandidates = @(
    (Join-Path $Root "assets\icons\source\ico.png"),
    (Join-Path $Root "assets\icons\source\ico.jpeg"),
    (Join-Path $Root "assets\icons\source\ico.jpg")
)
$SourcePath = $SourceCandidates | Where-Object {
    Test-Path -LiteralPath $_
} | Select-Object -First 1

if (-not $SourcePath) {
    throw "Icon source not found. Expected one of: $($SourceCandidates -join ', ')"
}

function New-RoundedRectPath {
    param(
        [System.Drawing.RectangleF]$Rect,
        [float]$Radius
    )

    $diameter = $Radius * 2
    $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $path.AddArc($Rect.X, $Rect.Y, $diameter, $diameter, 180, 90)
    $path.AddArc($Rect.Right - $diameter, $Rect.Y, $diameter, $diameter, 270, 90)
    $path.AddArc($Rect.Right - $diameter, $Rect.Bottom - $diameter, $diameter, $diameter, 0, 90)
    $path.AddArc($Rect.X, $Rect.Bottom - $diameter, $diameter, $diameter, 90, 90)
    $path.CloseFigure()
    return $path
}

function Get-CenteredCropRect {
    param(
        [System.Drawing.Image]$Image,
        [float]$InsetFactor = 0.018
    )

    $edge = [Math]::Min($Image.Width, $Image.Height)
    $cropInset = $edge * $InsetFactor
    $size = $edge - ($cropInset * 2)
    return [System.Drawing.Rectangle]::new(
        [int][Math]::Round((($Image.Width - $edge) / 2) + $cropInset),
        [int][Math]::Round((($Image.Height - $edge) / 2) + $cropInset),
        [int][Math]::Round($size),
        [int][Math]::Round($size)
    )
}

function New-BStreamIcon {
    param(
        [System.Drawing.Image]$Source,
        [int]$Size,
        [float]$CropInsetFactor = 0.018
    )

    $bitmap = [System.Drawing.Bitmap]::new(
        $Size,
        $Size,
        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
    )
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $graphics.Clear([System.Drawing.Color]::Transparent)

    $s = [float]$Size
    $maskRect = [System.Drawing.RectangleF]::new(0, 0, $s, $s)
    $destRect = [System.Drawing.Rectangle]::new(0, 0, $Size, $Size)
    $mask = New-RoundedRectPath $maskRect ($s * 0.185)
    $sourceRect = Get-CenteredCropRect $Source $CropInsetFactor

    $state = $graphics.Save()
    $graphics.SetClip($mask)
    $graphics.DrawImage(
        $Source,
        $destRect,
        $sourceRect.X,
        $sourceRect.Y,
        $sourceRect.Width,
        $sourceRect.Height,
        [System.Drawing.GraphicsUnit]::Pixel
    )
    $graphics.Restore($state)

    $mask.Dispose()
    $graphics.Dispose()
    return $bitmap
}

function Save-PngIcon {
    param(
        [System.Drawing.Image]$Source,
        [int]$Size,
        [string]$Path,
        [float]$CropInsetFactor = 0.018
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }

    $bitmap = New-BStreamIcon $Source $Size $CropInsetFactor
    $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
}

function Get-PngBytes {
    param(
        [System.Drawing.Image]$Source,
        [int]$Size,
        [float]$CropInsetFactor = 0.018
    )

    $bitmap = New-BStreamIcon $Source $Size $CropInsetFactor
    $stream = [System.IO.MemoryStream]::new()
    $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
    $bytes = $stream.ToArray()
    $stream.Dispose()
    return $bytes
}

function Write-Ico {
    param(
        [System.Drawing.Image]$Source,
        [int[]]$Sizes,
        [string]$Path,
        [float]$CropInsetFactor = 0.018
    )

    $images = @()
    foreach ($size in $Sizes) {
        $images += [pscustomobject]@{
            Size = $size
            Data = Get-PngBytes $Source $size $CropInsetFactor
        }
    }

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }

    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create)
    $writer = [System.IO.BinaryWriter]::new($stream)
    $writer.Write([uint16]0)
    $writer.Write([uint16]1)
    $writer.Write([uint16]$images.Count)

    $offset = 6 + (16 * $images.Count)
    foreach ($image in $images) {
        $sizeByte = if ($image.Size -eq 256) { 0 } else { $image.Size }
        $writer.Write([byte]$sizeByte)
        $writer.Write([byte]$sizeByte)
        $writer.Write([byte]0)
        $writer.Write([byte]0)
        $writer.Write([uint16]1)
        $writer.Write([uint16]32)
        $writer.Write([uint32]$image.Data.Length)
        $writer.Write([uint32]$offset)
        $offset += $image.Data.Length
    }

    foreach ($image in $images) {
        $writer.Write([byte[]]$image.Data)
    }

    $writer.Dispose()
    $stream.Dispose()
}

$source = [System.Drawing.Image]::FromFile($SourcePath)

try {
    Save-PngIcon $source 48 (Join-Path $Root "assets\icons\bstream_icon.png")
    Save-PngIcon $source 96 (Join-Path $Root "assets\icons\2.0x\bstream_icon.png")
    Save-PngIcon $source 144 (Join-Path $Root "assets\icons\3.0x\bstream_icon.png")
    Save-PngIcon $source 192 (Join-Path $Root "assets\icons\4.0x\bstream_icon.png")

    $androidIcons = @{
        "mipmap-mdpi\ic_launcher.png" = 48
        "mipmap-hdpi\ic_launcher.png" = 72
        "mipmap-xhdpi\ic_launcher.png" = 96
        "mipmap-xxhdpi\ic_launcher.png" = 144
        "mipmap-xxxhdpi\ic_launcher.png" = 192
    }

    foreach ($entry in $androidIcons.GetEnumerator()) {
        Save-PngIcon $source $entry.Value `
            (Join-Path $Root "android\app\src\main\res\$($entry.Key)") 0.065
    }

    foreach ($size in @(16, 32, 64, 128, 256, 512, 1024)) {
        Save-PngIcon $source $size (Join-Path $Root "macos\Runner\Assets.xcassets\AppIcon.appiconset\app_icon_$size.png")
    }

    # Windows renders taskbar icons inside an additional safe area. Use only a
    # subtle crop so the B mark is slightly larger without crowding the icon.
    Write-Ico $source @(16, 20, 24, 32, 40, 48, 64, 80, 96, 128, 256) `
        (Join-Path $Root "windows\runner\resources\app_icon.ico") 0.065
} finally {
    $source.Dispose()
}
