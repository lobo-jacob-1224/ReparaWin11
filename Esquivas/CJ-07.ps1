<#
.SYNOPSIS
    Esquiva el callejon de RC_DataStore.ps1 / RS_DataStore.ps1 (solucionador de Windows Update):
    comprueba el almacen de datos de Windows Update y, solo si el administrador lo pide, lo reinicia
    RENOMBRANDO SoftwareDistribution con la fecha, sin borrar nada: ni la cache, ni el historial,
    ni las copias anteriores, ni los trabajos de Optimizacion de distribucion.
.DESCRIPTION
    Por defecto SOLO COMPRUEBA y no cambia nada:
      - Tamano de SoftwareDistribution, de Download, de DataStore.edb y de ReportingEvents.log.
      - Copias anteriores (SoftwareDistribution.* junto a la carpeta): se listan y se conservan.
      - Trabajos de Optimizacion de distribucion (HKLM\...\DeliveryOptimization\Jobs).
      - Estado de wuauserv, BITS, DoSvc y TrustedInstaller.
      - Errores de Windows Update de los ultimos dias, con su codigo. Un error cualquiera NO es motivo
        para reiniciar el almacen (RC_DataStore.ps1 lo propone ante cualquier error, incluso un texto
        que no es un codigo: prueba P-WU-06).
    Con -Reparar (reinicio seguro del almacen):
      - No actua si wuauserv esta deshabilitado (decision del administrador) ni si hay una instalacion
        en curso (TrustedInstaller en marcha).
      - No actua si no hay motivo (ni errores recientes ni DataStore.edb vacio o ausente) salvo -Forzar.
      - Copia de seguridad: estado de servicios, reg export de sus claves y de DeliveryOptimization\Jobs,
        e inventario de archivos de SoftwareDistribution.
      - Para wuauserv, BITS y DoSvc (con limite de tiempo), RENOMBRA SoftwareDistribution a
        SoftwareDistribution.esquivar-<fecha> (mismo disco: instantaneo, nada se copia ni se borra) y
        deja que wuauserv cree una carpeta nueva.
      - No borra DeliveryOptimization\Jobs ni ninguna copia anterior.
      - Deja cada servicio en el estado y tipo de inicio en que estaba.
      - Comprueba al final que hay carpeta nueva, que la antigua esta entera (mismo numero de archivos
        y bytes) y que las copias anteriores y los trabajos siguen ahi.
    El nombre .esquivar-<fecha> no empieza por 'softwaredistribution.bak', asi que la funcion
    DeleteBakFolder de RS_DataStore.ps1 (lineas 23-29) no lo borraria si alguien la ejecutara despues.
.EXAMPLE
    .\2_esquivar.ps1                      # solo comprobar
.EXAMPLE
    .\2_esquivar.ps1 -Reparar             # reiniciar el almacen si hay motivo
.EXAMPLE
    .\2_esquivar.ps1 -Reparar -Forzar     # reiniciarlo aunque no haya errores recientes
.NOTES
    Libro «Lo que Microsoft no explica» - callejon CJ-07. Windows PowerShell 5.1 de 64 bits.
    Para -Reparar hace falta una consola de administrador. No reinicia ni toca la red.
    Para deshacer: parar wuauserv, BITS y DoSvc, apartar la carpeta nueva y devolver el nombre
    SoftwareDistribution a la carpeta .esquivar-<fecha> (las ordenes quedan en informe.txt).
    Cuando todo vaya bien, la carpeta antigua se puede borrar a mano para liberar espacio.
#>
[CmdletBinding()]
param(
    [switch]$Reparar,
    [switch]$Forzar,
    [int]$Dias = 7,
    [string]$CarpetaCopia = ("$env:SystemDrive\Copias_WindowsUpdate\" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.ServiceProcess
$informe = New-Object System.Collections.ArrayList
function Nota([string]$Texto, [string]$Color = 'Gray') { [void]$informe.Add($Texto); Write-Host $Texto -ForegroundColor $Color }

if (-not [Environment]::Is64BitProcess) { throw 'Usa Windows PowerShell de 64 bits ([Environment]::Is64BitProcess debe ser True).' }
$esAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($Reparar -and -not $esAdmin) { throw 'Para -Reparar abre PowerShell como administrador. No se ha cambiado nada.' }

$SD = Join-Path $env:windir 'SoftwareDistribution'
$Jobs = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Jobs'
$servicios = @('wuauserv', 'BITS', 'DoSvc')
$sello = Get-Date -Format 'yyyyMMdd-HHmmss'

# ---------- utilidades ----------
function Leer-Servicio([string]$Nombre) {
    $s = Get-Service -Name $Nombre -ErrorAction SilentlyContinue
    if (-not $s) { return $null }
    $k = Get-ItemProperty -Path ('HKLM:\SYSTEM\CurrentControlSet\Services\' + $s.Name) -ErrorAction SilentlyContinue
    [pscustomobject]@{ Nombre = $s.Name; Estado = "$($s.Status)"; Inicio = "$($s.StartType)"; Start = [int]$k.Start; Retrasado = [int]$k.DelayedAutostart }
}
function Llevar-Servicio([string]$Nombre, [string]$Estado, [int]$Segundos = 60) {
    $c = New-Object System.ServiceProcess.ServiceController($Nombre)
    try {
        if ("$($c.Status)" -eq $Estado) { return $true }
        if ($Estado -eq 'Running' -and $c.Status -ne 'StartPending') { $c.Start() }
        if ($Estado -eq 'Stopped' -and $c.Status -ne 'StopPending') { $c.Stop() }
        $c.WaitForStatus($Estado, [TimeSpan]::FromSeconds($Segundos)); return $true   # espera con limite
    } catch { Nota ('  {0} no llego a {1}: {2}' -f $Nombre, $Estado, $_.Exception.Message) 'Red'; return $false }
    finally { $c.Close() }
}
function Reponer-TipoInicio($Antes) {
    if (-not $Antes) { return }
    $ruta = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $Antes.Nombre
    $k = Get-ItemProperty -Path $ruta
    if (([int]$k.Start -eq $Antes.Start) -and ([int]$k.DelayedAutostart -eq $Antes.Retrasado)) { return }
    $modo = switch ($Antes.Start) { 2 { if ($Antes.Retrasado -eq 1) { 'delayed-auto' } else { 'auto' } } 3 { 'demand' } 4 { 'disabled' } default { '' } }
    if ($modo) { & sc.exe config $Antes.Nombre start= $modo | Out-Null }
    $k = Get-ItemProperty -Path $ruta
    if ([int]$k.DelayedAutostart -ne $Antes.Retrasado) { try { Set-ItemProperty -Path $ruta -Name DelayedAutostart -Value $Antes.Retrasado -Type DWord } catch { } }
    Nota ('  Tipo de inicio de {0} devuelto a Start={1} (Windows lo habia cambiado).' -f $Antes.Nombre, $Antes.Start) 'Cyan'
}
function Medir([string]$Ruta) {
    if (-not (Test-Path -LiteralPath $Ruta)) { return [pscustomobject]@{ Archivos = 0; Bytes = [long]0 } }
    $f = @(Get-ChildItem -LiteralPath $Ruta -Recurse -Force -File -ErrorAction SilentlyContinue)
    $b = [long]0; foreach ($x in $f) { $b += $x.Length }
    [pscustomobject]@{ Archivos = $f.Count; Bytes = $b }
}
function MB([long]$b) { '{0:N1} MB' -f ($b / 1MB) }
function Copias-Anteriores { @(Get-ChildItem -LiteralPath $env:windir -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'SoftwareDistribution.*' } | ForEach-Object { $_.FullName }) }
function Trabajos-DO { if (Test-Path -Path $Jobs) { @(Get-ChildItem -Path $Jobs -ErrorAction SilentlyContinue).Count } else { -1 } }

# ---------- 1. Comprobacion (solo lectura) ----------
Nota '== Almacen de datos de Windows Update (solo lectura) ==' 'Cyan'
$existe = Test-Path -LiteralPath $SD
$total = Medir $SD
$edb = Join-Path $SD 'DataStore\DataStore.edb'
$edbLen = if (Test-Path -LiteralPath $edb) { (Get-Item -LiteralPath $edb -Force).Length } else { -1 }
$rep = Join-Path $SD 'ReportingEvents.log'
Nota ('  {0}: {1}' -f $SD, $(if ($existe) { '{0} archivos, {1}' -f $total.Archivos, (MB $total.Bytes) } else { 'NO EXISTE' }))
Nota ('  Download: {0}' -f (MB (Medir (Join-Path $SD 'Download')).Bytes))
Nota ('  DataStore.edb (historial y base de datos): {0}' -f $(if ($edbLen -ge 0) { MB $edbLen } else { 'NO EXISTE' }))
Nota ('  ReportingEvents.log: {0}' -f $(if (Test-Path -LiteralPath $rep) { '{0} bytes' -f (Get-Item -LiteralPath $rep -Force).Length } else { 'no existe' }))
$previas = Copias-Anteriores
if ($previas.Count -eq 0) { Nota '  Copias anteriores: ninguna.' }
else { $previas | ForEach-Object { Nota ('  Copia anterior (se conserva): {0}  {1}' -f $_, (MB (Medir $_).Bytes)) } }
$nJobs = Trabajos-DO
Nota ('  DeliveryOptimization\Jobs: {0}' -f $(if ($nJobs -lt 0) { 'no existe' } else { "$nJobs trabajos (no se borran)" }))
$est = @{}
foreach ($n in $servicios + 'TrustedInstaller') { $est[$n] = Leer-Servicio $n; if ($est[$n]) { Nota ('  {0,-16} {1}, inicio {2} (Start={3})' -f $n, $est[$n].Estado, $est[$n].Inicio, $est[$n].Start) } }

$errs = @()
try { $errs = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-WindowsUpdateClient/Operational'; Level = 2; StartTime = (Get-Date).AddDays(-$Dias) } -ErrorAction Stop) } catch { }
$codigos = @($errs | ForEach-Object { [regex]::Matches("$($_.Message)", '0x[0-9A-Fa-f]{8}') | ForEach-Object { '0x' + $_.Value.Substring(2).ToUpper() } } | Select-Object -Unique)
if ($errs.Count -eq 0) { Nota ("  Errores de Windows Update en los ultimos {0} dias: ninguno." -f $Dias) }
else { Nota ("  Errores de Windows Update en los ultimos {0} dias: {1}; codigos: {2}" -f $Dias, $errs.Count, $(if ($codigos.Count) { $codigos -join ', ' } else { 'sin codigo en el texto' })) 'Yellow' }

$danado = $existe -and ($edbLen -le 0)
$motivo = @()
if (-not $existe) { $motivo += 'no existe SoftwareDistribution' }
if ($danado) { $motivo += 'DataStore.edb falta o esta vacio' }
if ($errs.Count -gt 0) { $motivo += ('{0} errores recientes de Windows Update' -f $errs.Count) }
if ($motivo.Count -eq 0) { Nota 'DIAGNOSTICO: no hay errores recientes y el almacen esta presente. No hace falta reiniciarlo.' 'Green' }
else {
    Nota ('DIAGNOSTICO: {0}.' -f ($motivo -join '; ')) 'Yellow'
    if ($errs.Count -gt 0 -and -not $danado) { Nota '  Reinicia el almacen SOLO si el codigo apunta a la cache o al almacen de datos (busca el codigo antes). Un error cualquiera no es motivo.' 'Yellow' }
}
if (-not $Reparar) {
    Nota 'Con -Reparar se renombraria SoftwareDistribution con la fecha (sin borrar nada) y Windows Update crearia una nueva.' 'Gray'
    Nota 'RESULTADO: comprobacion terminada. No se ha cambiado nada.' 'Green'
    return
}

# ---------- 2. Condiciones para actuar ----------
if (-not $existe) { Nota 'RESULTADO: no existe SoftwareDistribution: Windows Update la creara al arrancar. No se ha cambiado nada.' 'Yellow'; return }
if ($est['wuauserv'] -and $est['wuauserv'].Start -eq 4) { Nota 'RESULTADO: wuauserv esta DESHABILITADO (decision del administrador). No se reinicia el almacen ni se toca el servicio.' 'Yellow'; return }
if ($est['TrustedInstaller'] -and $est['TrustedInstaller'].Estado -ne 'Stopped') { Nota 'RESULTADO: hay una instalacion en curso (TrustedInstaller en marcha). Espera a que termine. No se ha cambiado nada.' 'Yellow'; return }
if ($motivo.Count -eq 0 -and -not $Forzar) { Nota 'RESULTADO: no hay motivo para reiniciar el almacen. No se ha cambiado nada (usa -Forzar si de verdad quieres reiniciarlo).' 'Green'; return }

# ---------- 3. Copia de seguridad ----------
New-Item -ItemType Directory -Force -Path $CarpetaCopia | Out-Null
$foto = @{}; foreach ($n in $servicios) { $foto[$n] = Leer-Servicio $n }
@($foto.Values | Where-Object { $_ }) | Export-Csv -Path (Join-Path $CarpetaCopia 'estado_servicios_antes.csv') -NoTypeInformation -Encoding UTF8
foreach ($n in $servicios) { & reg.exe export ('HKLM\SYSTEM\CurrentControlSet\Services\' + $n) (Join-Path $CarpetaCopia ($n + '.reg')) /y 2>$null | Out-Null }
if ($nJobs -ge 0) { & reg.exe export 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Jobs' (Join-Path $CarpetaCopia 'DeliveryOptimization_Jobs.reg') /y 2>$null | Out-Null }
Nota "Copia de seguridad (estado de servicios y registro) en $CarpetaCopia" 'Cyan'

# ---------- 4. Parar, inventariar y renombrar (sin borrar) ----------
$destNombre = 'SoftwareDistribution.esquivar-' + $sello
$dest = Join-Path $env:windir $destNombre
$renombrado = $false
for ($i = 1; $i -le 3 -and -not $renombrado; $i++) {
    foreach ($n in $servicios) { if ($foto[$n]) { [void](Llevar-Servicio $n 'Stopped' 60) } }
    # inventario con los servicios ya parados: es lo que se comparara al final
    $total = Medir $SD
    Get-ChildItem -LiteralPath $SD -Recurse -Force -File -ErrorAction SilentlyContinue |
        Select-Object @{ n = 'Ruta'; e = { $_.FullName.Substring($SD.Length) } }, Length, LastWriteTime |
        Export-Csv -Path (Join-Path $CarpetaCopia 'inventario_SoftwareDistribution.csv') -NoTypeInformation -Encoding UTF8
    try { Rename-Item -LiteralPath $SD -NewName $destNombre -ErrorAction Stop; $renombrado = $true }
    catch { Nota ('  Intento {0}: no se pudo renombrar ({1})' -f $i, $_.Exception.Message) 'Yellow'; Start-Sleep -Seconds 3 }
}
if ($renombrado) {
    Nota "Hecho: SoftwareDistribution renombrada a $dest (no se ha borrado nada)." 'Green'
    Set-Content -Path (Join-Path $CarpetaCopia 'donde_esta_la_carpeta_antigua.txt') -Value $dest -Encoding UTF8
}

# ---------- 5. Servicios: que wuauserv cree la carpeta nueva y dejar todo como estaba ----------
$nueva = $false
if ($renombrado) {
    if (Llevar-Servicio 'wuauserv' 'Running' 60) {
        $t0 = Get-Date
        while (-not (Test-Path -LiteralPath $SD) -and ((Get-Date) - $t0).TotalSeconds -lt 60) { Start-Sleep -Seconds 1 }   # espera con limite
    }
    $nueva = Test-Path -LiteralPath $SD
}
foreach ($n in $servicios) {
    $a = $foto[$n]; if (-not $a) { continue }
    if ($a.Estado -eq 'Running') { [void](Llevar-Servicio $n 'Running' 60) } else { [void](Llevar-Servicio $n 'Stopped' 60) }
}
foreach ($n in $servicios) { Reponer-TipoInicio $foto[$n] }

# ---------- 6. Comprobacion final ----------
$fallos = New-Object System.Collections.ArrayList
if (-not $renombrado) { [void]$fallos.Add('no se pudo renombrar SoftwareDistribution: el almacen sigue como estaba') }
else {
    $vieja = Medir $dest
    Nota ('  Carpeta antigua: {0} archivos, {1} (antes {2} archivos, {3})' -f $vieja.Archivos, (MB $vieja.Bytes), $total.Archivos, (MB $total.Bytes))
    if ($vieja.Archivos -ne $total.Archivos -or $vieja.Bytes -ne $total.Bytes) { [void]$fallos.Add('la carpeta antigua no coincide con el inventario (revisa inventario_SoftwareDistribution.csv)') }
    if (-not $nueva) { [void]$fallos.Add('Windows Update no ha creado la carpeta nueva SoftwareDistribution (se creara la proxima vez que arranque)') }
}
foreach ($p in $previas) { if (-not (Test-Path -LiteralPath $p)) { [void]$fallos.Add("ha desaparecido la copia anterior $p") } }
if ((Trabajos-DO) -ne $nJobs) { [void]$fallos.Add('ha cambiado el numero de trabajos de DeliveryOptimization\Jobs') }
foreach ($n in $servicios) {
    $a = $foto[$n]; $d = Leer-Servicio $n; if (-not $a) { continue }
    Nota ('  {0,-10} antes {1} Start={2} | ahora {3} Start={4}' -f $n, $a.Estado, $a.Start, $d.Estado, $d.Start)
    if ($a.Estado -ne $d.Estado) { [void]$fallos.Add("$n no ha quedado como estaba ($($a.Estado))") }
    if ($a.Start -ne $d.Start) { [void]$fallos.Add("el tipo de inicio de $n ha cambiado") }
}
$deshacer = "Para deshacer: Stop-Service wuauserv,BITS,DoSvc ; Rename-Item '$SD' 'SoftwareDistribution.nueva-$sello' ; Rename-Item '$dest' 'SoftwareDistribution'"
if ($fallos.Count -eq 0) {
    Nota ('RESULTADO: almacen de Windows Update reiniciado sin borrar nada. Lo anterior (cache, historial, ReportingEvents.log) esta entero en {0}; copias anteriores y trabajos de Optimizacion de distribucion intactos.' -f $dest) 'Green'
    Nota "  $deshacer" 'Gray'
} else {
    $fallos | ForEach-Object { Nota "  - $_" 'Red' }
    Nota "RESULTADO: queda algo por revisar. Copia e inventario en $CarpetaCopia." 'Red'
    if ($renombrado) { Nota "  $deshacer" 'Gray' }
}
$informe | Set-Content -Path (Join-Path $CarpetaCopia 'informe.txt') -Encoding UTF8
