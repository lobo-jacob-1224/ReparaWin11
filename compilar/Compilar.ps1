# Compilar.ps1 - construye dist\ReparaWin11.exe (un solo archivo con la herramienta dentro).
# Usa solo lo que trae Windows: System.Drawing para el icono y csc.exe de .NET Framework 4 para compilar.
$ErrorActionPreference = 'Stop'
$aqui = Split-Path -Parent $MyInvocation.MyCommand.Path
$raiz = Split-Path -Parent $aqui
$obj = Join-Path $aqui 'obj'; $dist = Join-Path $raiz 'dist'
New-Item -ItemType Directory -Force $obj, $dist | Out-Null

# 1) comprobar que todos los scripts se leen sin errores
$malos = @()
foreach ($f in (Get-ChildItem $raiz -Recurse -Filter '*.ps1' | Where-Object { $_.FullName -notlike "$aqui*" })) {
    $tk = $null; $er = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tk, [ref]$er)
    if ($er.Count) { $malos += "$($f.Name): $($er[0].Message)" }
}
if ($malos) { throw ("Hay scripts con errores de sintaxis:`n" + ($malos -join "`n")) }
Write-Host '1/4 Sintaxis de los scripts: correcta'

# 2) icono: escudo blanco con marca verde sobre fondo azul (16, 32, 48 y 256 px, PNG dentro de ICO)
Add-Type -AssemblyName System.Drawing
function Dibujar([int]$n) {
    $b = New-Object System.Drawing.Bitmap $n, $n
    $g = [System.Drawing.Graphics]::FromImage($b)
    $g.SmoothingMode = 'AntiAlias'; $g.Clear([System.Drawing.Color]::Transparent)
    $k = $n / 256.0
    $r = 56 * $k; $fondo = New-Object System.Drawing.Drawing2D.GraphicsPath
    $fondo.AddArc(8 * $k, 8 * $k, $r, $r, 180, 90); $fondo.AddArc(248 * $k - $r, 8 * $k, $r, $r, 270, 90)
    $fondo.AddArc(248 * $k - $r, 248 * $k - $r, $r, $r, 0, 90); $fondo.AddArc(8 * $k, 248 * $k - $r, $r, $r, 90, 90); $fondo.CloseFigure()
    $grad = New-Object System.Drawing.Drawing2D.LinearGradientBrush((New-Object System.Drawing.PointF(0, 0)), (New-Object System.Drawing.PointF($n, $n)), [System.Drawing.Color]::FromArgb(30, 136, 229), [System.Drawing.Color]::FromArgb(13, 71, 161))
    $g.FillPath($grad, $fondo)
    $p = { param($x, $y) New-Object System.Drawing.PointF(($x * $k), ($y * $k)) }
    $escudo = New-Object System.Drawing.Drawing2D.GraphicsPath
    $escudo.AddBezier((& $p 128 40), (& $p 160 58), (& $p 190 62), (& $p 206 62))
    $escudo.AddBezier((& $p 206 62), (& $p 210 150), (& $p 180 196), (& $p 128 222))
    $escudo.AddBezier((& $p 128 222), (& $p 76 196), (& $p 46 150), (& $p 50 62))
    $escudo.AddBezier((& $p 50 62), (& $p 66 62), (& $p 96 58), (& $p 128 40)); $escudo.CloseFigure()
    $g.FillPath([System.Drawing.Brushes]::White, $escudo)
    $lapiz = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(46, 160, 67)), ([Math]::Max(2, 24 * $k))
    $lapiz.StartCap = 'Round'; $lapiz.EndCap = 'Round'; $lapiz.LineJoin = 'Round'
    $g.DrawLines($lapiz, [System.Drawing.PointF[]]@((& $p 90 132), (& $p 118 160), (& $p 168 104)))
    $g.Dispose()
    $ms = New-Object IO.MemoryStream; $b.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png); $b.Dispose()
    return , $ms.ToArray()
}
$tamanos = 16, 32, 48, 256
$pngs = @($tamanos | ForEach-Object { , (Dibujar $_) })
$ico = Join-Path $obj 'ReparaWin11.ico'
$fs = [IO.File]::Create($ico); $w = New-Object IO.BinaryWriter $fs
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$tamanos.Count)
$off = 6 + 16 * $tamanos.Count
for ($i = 0; $i -lt $tamanos.Count; $i++) {
    $t = $tamanos[$i]; $w.Write([byte]$(if ($t -ge 256) { 0 } else { $t })); $w.Write([byte]$(if ($t -ge 256) { 0 } else { $t }))
    $w.Write([byte]0); $w.Write([byte]0); $w.Write([uint16]1); $w.Write([uint16]32); $w.Write([uint32]$pngs[$i].Length); $w.Write([uint32]$off); $off += $pngs[$i].Length
}
foreach ($d in $pngs) { $w.Write($d) }
$w.Close()
[IO.File]::WriteAllBytes((Join-Path $obj 'icono_256.png'), $pngs[-1])
Write-Host '2/4 Icono creado'

# 3) empaquetar la herramienta (sin informes, copias ni la carpeta de compilacion)
$paq = Join-Path $obj 'paquete'
if (Test-Path $paq) { Remove-Item $paq -Recurse -Force }
New-Item -ItemType Directory -Force $paq | Out-Null
foreach ($x in 'Nucleo.ps1', 'ReparaWin11.ps1', 'LEEME.txt', 'Modulos', 'Esquivas') { Copy-Item (Join-Path $raiz $x) $paq -Recurse -Force }
$zip = Join-Path $obj 'app.zip'
if (Test-Path $zip) { Remove-Item $zip -Force }
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($paq, $zip, 'Optimal', $false)
Write-Host ('3/4 Herramienta empaquetada ({0:N0} KB)' -f ((Get-Item $zip).Length / 1KB))

# 4) compilar con csc.exe de .NET Framework 4 (viene con Windows)
$fw = "$env:windir\Microsoft.NET\Framework64\v4.0.30319"
$csc = Join-Path $fw 'csc.exe'
if (-not (Test-Path $csc)) { throw "No se encuentra $csc" }
$exe = Join-Path $dist 'ReparaWin11.exe'
$argumentos = @('/nologo', '/target:winexe', '/platform:x64', '/optimize+', "/out:$exe", "/win32icon:$ico", "/win32manifest:$(Join-Path $aqui 'app.manifest')",
    "/resource:$zip,app.zip", "/reference:$fw\System.IO.Compression.dll", "/reference:$fw\System.IO.Compression.FileSystem.dll", '/reference:System.Windows.Forms.dll',
    (Join-Path $aqui 'Lanzador.cs'))
$salida = & $csc @argumentos 2>&1
if ($LASTEXITCODE -ne 0) { throw ("csc fallo:`n" + ($salida -join "`n")) }
$h = (Get-FileHash $exe -Algorithm SHA256).Hash
Set-Content (Join-Path $dist 'ReparaWin11.exe.sha256') "$h  ReparaWin11.exe" -Encoding ASCII
Write-Host ('4/4 Compilado: {0} ({1:N0} KB)' -f $exe, ((Get-Item $exe).Length / 1KB)) -ForegroundColor Green
Write-Host "SHA256: $h"
