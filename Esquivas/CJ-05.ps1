<#
.SYNOPSIS
    Esquiva el callejon de RS_GENWUError.ps1 (solucionador de Windows Update): comprueba los servicios
    de los que depende Windows Update y, si se pide, arranca SOLO los que esten parados y deban estar en
    marcha, sin parar CryptSvc ni sus dependientes (AppIDSvc, AppLocker) y sin cambiar tipos de inicio.
.DESCRIPTION
    Por defecto SOLO COMPRUEBA y no cambia nada:
      - CryptSvc, BITS y wuauserv: si existen, tipo de inicio y estado.
      - Servicios que dependen de CryptSvc (AppIDSvc, applockerfltr...) y si deberian estar en marcha.
      - Si hay reglas de AppLocker (HKLM\SOFTWARE\Policies\Microsoft\Windows\SrpV2).
      - Errores de Windows Update de los ultimos dias (registro de eventos, solo lectura).
      - Proxy de WinHTTP (netsh winhttp show proxy, solo lectura).
    Con -Reparar:
      1. Copia de seguridad: estado de los servicios (CSV) y reg export de sus claves.
      2. Arranca CryptSvc si esta parado (sin cambiar su tipo de inicio).
      3. Arranca los dependientes de CryptSvc que esten parados y deban estar en marcha:
         los de inicio automatico, AppIDSvc y applockerfltr si hay reglas de AppLocker, y los que
         el administrador nombre con -ArrancarTambien.
      4. Nunca para ningun servicio. Si Windows cambia un tipo de inicio al arrancar, lo devuelve.
      5. Comprueba al final que todo lo que estaba en marcha sigue en marcha y lo arrancado tambien.
    Lo que hace RS_GENWUError.ps1 y este script NO hace, a proposito: parar CryptSvc con -Force (tumba
    AppIDSvc), ponerlo en Automatico, registrar 36 DLL con regsvr32, borrar qmgr*.dat (ruta antigua que
    en Windows 11 no existe) y ejecutar 'netsh winhttp reset proxy' (borraria un proxy configurado a
    proposito). El proxy solo se muestra.
.PARAMETER ArrancarTambien
    Nombres de servicios dependientes de CryptSvc que deben quedar en marcha aunque esten en Manual
    (por ejemplo AppIDSvc si estaba en marcha antes de usar el solucionador de Microsoft).
.EXAMPLE
    .\2_esquivar.ps1                                   # solo comprobar
.EXAMPLE
    .\2_esquivar.ps1 -Reparar                          # arrancar lo que este parado y deba estar en marcha
.EXAMPLE
    .\2_esquivar.ps1 -Reparar -ArrancarTambien AppIDSvc,applockerfltr
.NOTES
    Libro «Lo que Microsoft no explica» - callejon CJ-05. Windows PowerShell 5.1 de 64 bits.
    Para -Reparar hace falta una consola de administrador. No reinicia, no toca la red ni el proxy.
#>
[CmdletBinding()]
param(
    [switch]$Reparar,
    [string[]]$ArrancarTambien = @(),
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

# ---------- utilidades ----------
function Leer-Servicio([string]$Nombre) {
    $s = Get-Service -Name $Nombre -ErrorAction SilentlyContinue
    if (-not $s) { return $null }
    $k = Get-ItemProperty -Path ('HKLM:\SYSTEM\CurrentControlSet\Services\' + $s.Name) -ErrorAction SilentlyContinue
    $pid0 = 0
    try { $w = Get-CimInstance -ClassName Win32_Service -Filter ("Name='{0}'" -f $s.Name) -ErrorAction Stop; if ($w) { $pid0 = [int]$w.ProcessId } } catch { }
    [pscustomobject]@{ Nombre = $s.Name; Estado = "$($s.Status)"; Inicio = "$($s.StartType)"; Start = [int]$k.Start; Retrasado = [int]$k.DelayedAutostart; PID = $pid0 }
}
function Texto-Servicio($e) {
    if (-not $e) { return 'no existe' }
    return ('{0}, inicio {1} (Start={2}{3})' -f $e.Estado, $e.Inicio, $e.Start, $(if ($e.Start -eq 2 -and $e.Retrasado -eq 1) { ', retrasado' } else { '' }))
}
function Arrancar-Servicio([string]$Nombre, [int]$Segundos = 60) {
    $c = New-Object System.ServiceProcess.ServiceController($Nombre)
    try {
        if ($c.Status -eq 'Running') { return $true }
        if ($c.Status -ne 'StartPending') { $c.Start() }
        $c.WaitForStatus('Running', [TimeSpan]::FromSeconds($Segundos))   # espera con limite
        return $true
    } catch { Nota ('  No se pudo arrancar {0}: {1}' -f $Nombre, $_.Exception.Message) 'Red'; return $false }
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
function AppLocker-EnUso {
    $base = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\SrpV2'
    if (-not (Test-Path -Path $base)) { return $false }
    foreach ($c in @(Get-ChildItem -Path $base -ErrorAction SilentlyContinue)) {
        if (@(Get-ChildItem -Path $c.PSPath -ErrorAction SilentlyContinue).Count -gt 0) { return $true }
    }
    return $false
}
function Errores-WindowsUpdate([int]$NDias) {
    $r = @()
    try {
        $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-WindowsUpdateClient/Operational'; Level = 2; StartTime = (Get-Date).AddDays(-$NDias) } -ErrorAction Stop)
    } catch { $ev = @() }   # sin eventos Get-WinEvent lanza un error: se trata como lista vacia
    foreach ($e in $ev) {
        $cod = @([regex]::Matches("$($e.Message)", '0x[0-9A-Fa-f]{8}') | ForEach-Object { '0x' + $_.Value.Substring(2).ToUpper() }) | Select-Object -Unique
        $r += [pscustomobject]@{ Fecha = $e.TimeCreated; Id = $e.Id; Codigos = (@($cod) -join ',') }
    }
    return $r
}

# ---------- 1. Comprobacion (solo lectura) ----------
Nota '== Servicios de Windows Update (solo lectura) ==' 'Cyan'
$basicos = @('CryptSvc', 'BITS', 'wuauserv')
$est = @{}
foreach ($n in $basicos) { $est[$n] = Leer-Servicio $n; Nota ('  {0,-14} {1}' -f $n, (Texto-Servicio $est[$n])) }

$problemas = New-Object System.Collections.ArrayList
$aArrancar = New-Object System.Collections.ArrayList
$avisos = New-Object System.Collections.ArrayList

$c = $est['CryptSvc']
if (-not $c) { [void]$problemas.Add('CryptSvc no existe (no se puede arreglar con este script)') }
elseif ($c.Start -eq 4) { [void]$avisos.Add('CryptSvc esta DESHABILITADO: Windows Update no puede comprobar firmas. No se toca: es una decision del administrador.') }
elseif ($c.Estado -ne 'Running') { [void]$problemas.Add('CryptSvc (Servicios de cifrado) esta parado'); [void]$aArrancar.Add('CryptSvc') }

foreach ($n in 'BITS', 'wuauserv') {
    $e = $est[$n]
    if (-not $e) { [void]$problemas.Add("$n no existe (no se puede arreglar con este script)") }
    elseif ($e.Start -eq 4) { [void]$avisos.Add("$n esta DESHABILITADO. No se toca: si fue a proposito, dejalo; si no, revisalo (callejon CJ-06).") }
    elseif ($e.Estado -ne 'Running') { Nota ("  {0} parado con inicio {1}: es normal, Windows lo arranca cuando lo necesita." -f $n, $e.Inicio) }
}

$reglas = AppLocker-EnUso
Nota ('  Reglas de AppLocker (SrpV2): {0}' -f $(if ($reglas) { 'SI' } else { 'no' }))
Nota '== Servicios que dependen de CryptSvc (los para RS_GENWUError al parar CryptSvc con -Force) ==' 'Cyan'
$deps = @()
if ($c) { $deps = @((Get-Service -Name CryptSvc).DependentServices | ForEach-Object { $_.Name }) }
$nombresDeps = @($deps | ForEach-Object { $_.ToLower() })
foreach ($x in $ArrancarTambien) {
    if ($nombresDeps -notcontains $x.ToLower()) { [void]$avisos.Add("-ArrancarTambien '$x' se ignora: no es un servicio que dependa de CryptSvc.") }
}
$estDeps = @{}
foreach ($d in $deps) {
    $e = Leer-Servicio $d; $estDeps[$d] = $e
    Nota ('  {0,-18} {1}' -f $d, (Texto-Servicio $e))
    if (-not $e -or $e.Estado -eq 'Running') { continue }
    if ($e.Start -eq 4) { continue }                                   # deshabilitado: decision del administrador
    $pedido = @($ArrancarTambien | Where-Object { $_ -ieq $d }).Count -gt 0
    $porAppLocker = $reglas -and (@('AppIDSvc', 'applockerfltr') -contains $d)
    if ($e.Start -le 2 -or $pedido -or $porAppLocker) {
        $motivo = if ($pedido) { 'lo pide el administrador' } elseif ($porAppLocker) { 'hay reglas de AppLocker' } else { 'su inicio es automatico' }
        [void]$problemas.Add("$d esta parado y debe estar en marcha ($motivo)")
        [void]$aArrancar.Add($d)
    } elseif ($d -ieq 'AppIDSvc') {
        Nota '    AppIDSvc parado, en Manual y sin reglas de AppLocker: normal, Windows lo arranca cuando hace falta.'
        Nota '    Si estaba en marcha antes de usar el solucionador de Microsoft, ejecuta con -Reparar -ArrancarTambien AppIDSvc,applockerfltr'
    }
}

Nota '== Errores de Windows Update (registro de eventos, solo lectura) ==' 'Cyan'
$errs = @(Errores-WindowsUpdate $Dias)
if ($errs.Count -eq 0) { Nota ("  Ninguno en los ultimos {0} dias." -f $Dias) }
else { $errs | Select-Object -First 10 | ForEach-Object { Nota ('  {0:yyyy-MM-dd HH:mm}  evento {1}  {2}' -f $_.Fecha, $_.Id, $_.Codigos) 'Yellow' } }
Nota '  (Este script no consulta cem.services.microsoft.com: ya no resuelve en DNS, prueba P-WU-13.)'
Nota '== Proxy de WinHTTP (solo se muestra; no se borra) ==' 'Cyan'
try { @(& netsh.exe winhttp show proxy) | Where-Object { "$_".Trim() } | ForEach-Object { Nota ('  ' + "$_".Trim()) } } catch { Nota '  No se pudo leer.' }

foreach ($a in $avisos) { Nota ('AVISO: ' + $a) 'Yellow' }
if ($problemas.Count -eq 0) { Nota 'RESULTADO: los servicios de los que depende Windows Update estan bien. No hace falta cambiar nada.' 'Green' }
else {
    Nota 'PROBLEMAS ENCONTRADOS:' 'Yellow'; $problemas | ForEach-Object { Nota "  - $_" 'Yellow' }
    Nota ('Con -Reparar se arrancaria (sin parar nada ni cambiar tipos de inicio): ' + ($aArrancar -join ', ')) 'Yellow'
}
if (-not $Reparar) { return }
if ($aArrancar.Count -eq 0) { return }

# ---------- 2. Copia de seguridad ----------
New-Item -ItemType Directory -Force -Path $CarpetaCopia | Out-Null
$vigilados = @($basicos + $deps | Select-Object -Unique)
$foto = @{}
foreach ($n in $vigilados) { $foto[$n] = Leer-Servicio $n }
@($foto.Values | Where-Object { $_ }) | Export-Csv -Path (Join-Path $CarpetaCopia 'estado_servicios_antes.csv') -NoTypeInformation -Encoding UTF8
foreach ($n in $vigilados) {
    try { & reg.exe export ('HKLM\SYSTEM\CurrentControlSet\Services\' + $n) (Join-Path $CarpetaCopia ($n + '.reg')) /y 2>$null | Out-Null } catch { }
}
Nota "Copia de seguridad en $CarpetaCopia" 'Cyan'

# ---------- 3. Arrancar solo lo que falta (CryptSvc primero) ----------
$orden = @($aArrancar | Sort-Object { if ($_ -ieq 'CryptSvc') { 0 } elseif ($_ -ieq 'AppIDSvc') { 1 } else { 2 } })
foreach ($n in $orden) {
    if (Arrancar-Servicio $n 60) { Nota "Hecho: $n en marcha." 'Green' }
}
foreach ($n in $vigilados) { Reponer-TipoInicio $foto[$n] }

# ---------- 4. Comprobacion final ----------
$fallos = New-Object System.Collections.ArrayList
Nota '== Despues ==' 'Cyan'
foreach ($n in $vigilados) {
    $a = $foto[$n]; $d = Leer-Servicio $n
    if (-not $a -or -not $d) { continue }
    Nota ('  {0,-18} antes {1} | ahora {2}' -f $n, (Texto-Servicio $a), (Texto-Servicio $d))
    if ($a.Estado -eq 'Running' -and $d.Estado -ne 'Running') { [void]$fallos.Add("$n estaba en marcha y ahora no") }
    if ($a.Start -ne $d.Start) { [void]$fallos.Add("el tipo de inicio de $n ha cambiado (Start $($a.Start) -> $($d.Start))") }
    if (($aArrancar -contains $n) -and $d.Estado -ne 'Running') { [void]$fallos.Add("$n no ha arrancado") }
}
if ($fallos.Count -eq 0) { Nota ('RESULTADO: servicios de Windows Update en orden. Arrancados: {0}. No se ha parado nada ni cambiado ningun tipo de inicio.' -f ($aArrancar -join ', ')) 'Green' }
else { $fallos | ForEach-Object { Nota "  - $_" 'Red' }; Nota "RESULTADO: queda algo por revisar. Estado anterior en $CarpetaCopia\estado_servicios_antes.csv" 'Red' }
$informe | Set-Content -Path (Join-Path $CarpetaCopia 'informe.txt') -Encoding UTF8
