<#
.SYNOPSIS
    Draws the 3dxGC icon and writes gui\3dxGC.ico plus the installer's
    wizard image.

.DESCRIPTION
    Every size is drawn separately at its own pixel size rather than scaled
    down from one big bitmap, so the 16 px tray icon stays sharp. The .ico
    holds classic 32-bit DIB entries up to 64 px (what csc /win32icon and
    the tray read most reliably) and a PNG entry at 256 px.

    Run it again only when the design changes; the outputs are committed.
#>
[CmdletBinding()]
param(
    [string]$Root = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

function New-RoundedRect {
    param([single]$X, [single]$Y, [single]$W, [single]$H, [single]$R)
    $p = New-Object Drawing.Drawing2D.GraphicsPath
    $d = $R * 2
    $p.AddArc($X, $Y, $d, $d, 180, 90)
    $p.AddArc($X + $W - $d, $Y, $d, $d, 270, 90)
    $p.AddArc($X + $W - $d, $Y + $H - $d, $d, $d, 0, 90)
    $p.AddArc($X, $Y + $H - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

function New-IconBitmap {
    param([int]$Size)

    $bmp = New-Object Drawing.Bitmap($Size, $Size, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.PixelOffsetMode = 'HighQuality'
    $g.Clear([Drawing.Color]::Transparent)

    # Tile: the panel's blue, darkening towards the bottom.
    $inset = [Math]::Max(0.5, $Size / 32.0)
    $s = $Size - 2 * $inset
    $tile = New-RoundedRect $inset $inset $s $s ([single]($Size * 0.22))
    $top = [Drawing.Color]::FromArgb(255, 0x5A, 0xB2, 0xFF)
    $bot = [Drawing.Color]::FromArgb(255, 0x24, 0x5E, 0xD8)
    $fill = New-Object Drawing.Drawing2D.LinearGradientBrush(
        (New-Object Drawing.PointF(0, 0)), (New-Object Drawing.PointF(0, $Size)), $top, $bot)
    $g.FillPath($fill, $tile)

    # Memory-stick contacts along the bottom edge, from 32 px up - below
    # that they would only blur the letters.
    $lettersBottom = $Size * 0.86
    if ($Size -ge 32) {
        $pinW = $Size * 0.055
        $pinH = $Size * 0.11
        $gap  = $Size * 0.042
        $count = 8
        $rowW = $count * $pinW + ($count - 1) * $gap
        $x0 = ($Size - $rowW) / 2
        $y0 = $Size - $inset - $Size * 0.06 - $pinH
        $pin = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(150, 255, 255, 255))
        for ($i = 0; $i -lt $count; $i++) {
            $g.FillRectangle($pin, [single]($x0 + $i * ($pinW + $gap)), [single]$y0, [single]$pinW, [single]$pinH)
        }
        $lettersBottom = $y0 - $Size * 0.05
    }

    # "GC", fitted into the space above the contacts.
    $font = New-Object Drawing.FontFamily('Segoe UI')
    $path = New-Object Drawing.Drawing2D.GraphicsPath
    $path.AddString('GC', $font, [int][Drawing.FontStyle]::Bold, [single]100, (New-Object Drawing.PointF(0, 0)), [Drawing.StringFormat]::GenericTypographic)
    $b = $path.GetBounds()
    $boxW = $Size * 0.74
    $boxTop = $Size * 0.16
    $boxH = $lettersBottom - $boxTop
    $scale = [Math]::Min($boxW / $b.Width, $boxH / $b.Height)
    $m = New-Object Drawing.Drawing2D.Matrix
    $m.Translate([single](($Size - $b.Width * $scale) / 2), [single]($boxTop + ($boxH - $b.Height * $scale) / 2))
    $m.Scale([single]$scale, [single]$scale)
    $m.Translate([single](-$b.X), [single](-$b.Y))
    $path.Transform($m)
    $g.FillPath([Drawing.Brushes]::White, $path)

    $g.Dispose()
    return $bmp
}

function Get-PngBytes {
    param([Drawing.Bitmap]$Bitmap)
    $ms = New-Object IO.MemoryStream
    $Bitmap.Save($ms, [Drawing.Imaging.ImageFormat]::Png)
    return ,$ms.ToArray()
}

function Get-DibBytes {
    # BITMAPINFOHEADER + bottom-up BGRA rows + an all-clear AND mask; the
    # header's height is doubled because it counts the mask too.
    param([Drawing.Bitmap]$Bitmap)
    $n = $Bitmap.Width
    $ms = New-Object IO.MemoryStream
    $w = New-Object IO.BinaryWriter($ms)
    $w.Write([int]40); $w.Write([int]$n); $w.Write([int]($n * 2))
    $w.Write([int16]1); $w.Write([int16]32); $w.Write([int]0)
    $w.Write([int]0); $w.Write([int]0); $w.Write([int]0); $w.Write([int]0); $w.Write([int]0)
    for ($y = $n - 1; $y -ge 0; $y--) {
        for ($x = 0; $x -lt $n; $x++) {
            $c = $Bitmap.GetPixel($x, $y)
            $w.Write([byte]$c.B); $w.Write([byte]$c.G); $w.Write([byte]$c.R); $w.Write([byte]$c.A)
        }
    }
    $maskRow = [int]([Math]::Ceiling($n / 32.0) * 4)
    $w.Write((New-Object byte[] ($maskRow * $n)))
    $w.Flush()
    return ,$ms.ToArray()
}

$sizes = 16, 20, 24, 32, 40, 48, 64, 256
$images = foreach ($size in $sizes) {
    $bmp = New-IconBitmap $size
    $bytes = if ($size -ge 256) { Get-PngBytes $bmp } else { Get-DibBytes $bmp }
    $bmp.Dispose()
    [pscustomobject]@{ Size = $size; Bytes = $bytes }
}

$icoPath = Join-Path $Root 'gui\3dxGC.ico'
$fs = [IO.File]::Create($icoPath)
$w = New-Object IO.BinaryWriter($fs)
$w.Write([int16]0); $w.Write([int16]1); $w.Write([int16]$images.Count)
$offset = 6 + 16 * $images.Count
foreach ($img in $images) {
    $dim = if ($img.Size -ge 256) { 0 } else { $img.Size }
    $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([int16]1); $w.Write([int16]32)
    $w.Write([int]$img.Bytes.Length); $w.Write([int]$offset)
    $offset += $img.Bytes.Length
}
foreach ($img in $images) { $w.Write([byte[]]$img.Bytes) }
$w.Close()

# Installer header image (top right of each wizard page). Inno scales it
# for the display, so one large-ish PNG covers every DPI.
$wiz = New-IconBitmap 128
$wiz.Save((Join-Path $PSScriptRoot 'wizard-small.png'), [Drawing.Imaging.ImageFormat]::Png)
$wiz.Dispose()

"wrote $icoPath ($((Get-Item $icoPath).Length) bytes, sizes $($sizes -join ', '))"
