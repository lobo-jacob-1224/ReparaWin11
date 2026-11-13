<#
.SYNOPSIS
    Esquiva el callejon de RC_DateTime.ps1 (solucionador de Windows Update): comprueba la hora del
    equipo sin cambiar el tipo de inicio de W32Time y sin consultar ningun servidor salvo que el
    administrador lo pida; si se pide -Reparar y la hora esta desfasada, la sincroniza con la fuente
    configurada y deja W32Time como estaba.
.DESCRIPTION
    Por defecto SOLO COMPRUEBA, sin red y sin tocar servicios:
      - W32Time: tipo de inicio y estado (no se arranca).
      - Configuracion de hora: Type y NtpServer (registro y directiva), union a dominio, zona horaria,
        limites de correccion MaxPosPhaseCorrection / MaxNegPhaseCorrection.
      - No ejecuta w32tm ni envia nada a la red.
    Con -ConsultarServidor (lo pide el administrador):
      - w32tm /query /status si W32Time ya esta en marcha (no lo arranca).
      - w32tm /stripchart contra el servidor configurado (o el de -Servidor) para medir el desfase.
        Nunca cambia de servidor por su cuenta: si la fuente es el reloj local (Local CMOS Clock) o
        el dominio, hay que dar -Servidor.
    Con -Reparar (implica -ConsultarServidor):
      - Si el desfase es menor que -MaxDesfaseSegundos (300, el mismo limite que RC_DateTime.ps1), no
        cambia nada.
      - Si es mayor: no actua si W32Time esta deshabilitado o la sincronizacion desactivada (Type=NoSync),
        porque es una decision del administrador. Si no, copia de seguridad (reg export de W32Time y
        estado), arranca W32Time solo si hace falta, w32tm /resync, vuelve a medir, y deja el servicio
        en el estado y tipo de inicio en que estaba.
    RC_DateTime.ps1, en cambio, pone W32Time en Automatico y lo arranca (lineas 124-129), consulta
    time.windows.com si falla la fuente configurada (lineas 137-140) y no lo vuelve a parar
    (la condicion de la linea 148 nunca se cumple: prueba P-WU-04).
.EXAMPLE
    .\2_esquivar.ps1                                    # solo comprobar (sin red)
.EXAMPLE
    .\2_esquivar.ps1 -ConsultarServidor                 # medir el desfase con el servidor configurado
.EXAMPLE
    .\2_esquivar.ps1 -Reparar -Servidor ntp.miempresa.local
.NOTES
    Libro «Lo que Microsoft no explica» - callejon CJ-20. Windows PowerShell 5.1 de 64 bits.
    Para -Reparar hace falta una consola de administrador. No reinicia, no cambia la configuracion
    de W32Time (Type, NtpServer) ni su tipo de inicio.
#>
[CmdletBinding()]
param(
    [switch]$Reparar,
    [switch]$ConsultarServidor,
    [string]$Servidor = '',
    [int]$MaxDesfaseSegundos = 300,
    [string]$CarpetaCopia = ("$env:SystemDrive\Copias_Hora\" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.ServiceProcess
$informe = New-Object System.Collections.ArrayList
function Nota([string]$Texto, [string]$Color = 'Gray') { [void]$informe.Add($Texto); Write-Host $Texto -ForegroundColor $Color }

if (-not [Environment]::Is64BitProcess) { throw 'Usa Windows PowerShell de 64 bits ([Environment]::Is64BitProcess debe ser True).' }
$esAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($Reparar -and -not $esAdmin) { throw 'Para -Reparar abre PowerShell como administrador. No se ha cambiado nada.' }
if ($Reparar) { $ConsultarServidor = $true }

$svcRuta = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time'
function Leer-W32 {
    $s = Get-Service -Name W32Time -ErrorAction SilentlyContinue
    if (-not $s) { return $null }
    $k = Get-ItemProperty -Path $svcRuta -ErrorAction SilentlyContinue
    [pscustomobject]@{ Estado = "$($s.Status)"; Inicio = "$($s.StartType)"; Start = [int]$k.Start; Retrasado = [int]$k.DelayedAutostart }
}
function Leer-Valor([string]$Ruta, [string]$Nombre) {
    try { return (Get-ItemProperty -Path $Ruta -Name $Nombre -ErrorAction Stop).$Nombre } catch { return $null }
}
# Ejecuta un programa con limite de tiempo y devuelve sus lineas de salida (nada de esperas infinitas)
function Ejecutar([string]$Exe, [string]$Argumentos, [int]$Segundos = 30) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo($Exe, $Argumentos)
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
    try { $psi.StandardOutputEncoding = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage) } catch { }
    $p = [System.Diagnostics.Process]::Start($psi)
    $tOut = $p.StandardOutput.ReadToEndAsync(); $tErr = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($Segundos * 1000)) { try { $p.Kill() } catch { }; return [pscustomobject]@{ Codigo = -1; Lineas = @('(se agoto el tiempo de espera)') } }
    $txt = $tOut.Result + $tErr.Result
    [pscustomobject]@{ Codigo = $p.ExitCode; Lineas = @($txt -split "`r?`n" | Where-Object { $_.Trim() }) }
}
# Mide el desfase con w32tm /stripchart. Acepta punto o coma decimal.
function Medir-Desfase([string]$Srv) {
    $r = Ejecutar "$env:windir\System32\w32tm.exe" ("/stripchart /computer:{0} /dataonly /samples:3" -f $Srv) 45
    $vals = @()
    foreach ($l in $r.Lineas) {
        if ($l -match ',\s*([+-]?\d+(?:[.,]\d+)?)s\s*$') { $vals += [double]::Parse(($matches[1] -replace ',', '.'), [Globalization.CultureInfo]::InvariantCulture) }
    }
    [pscustomobject]@{ Valores = $vals; Lineas = $r.Lineas; Ultimo = $(if ($vals.Count) { $vals[-1] } else { $null }) }
}
function Llevar-W32([string]$Estado, [int]$Segundos = 60) {
    $c = New-Object System.ServiceProcess.ServiceController('W32Time')
    try {
        if ("$($c.Status)" -eq $Estado) { return $true }
        if ($Estado -eq 'Running' -and $c.Status -ne 'StartPending') { $c.Start() }
        if ($Estado -eq 'Stopped' -and $c.Status -ne 'StopPending') { $c.Stop() }
        $c.WaitForStatus($Estado, [TimeSpan]::FromSeconds($Segundos)); return $true
    } catch { Nota ('  W32Time no llego a {0}: {1}' -f $Estado, $_.Exception.Message) 'Red'; return $false }
    finally { $c.Close() }
}
function Reponer-TipoInicio($Antes) {
    $k = Get-ItemProperty -Path $svcRuta
    if (([int]$k.Start -eq $Antes.Start) -and ([int]$k.DelayedAutostart -eq $Antes.Retrasado)) { return }
    $modo = switch ($Antes.Start) { 2 { if ($Antes.Retrasado -eq 1) { 'delayed-auto' } else { 'auto' } } 3 { 'demand' } 4 { 'disabled' } default { '' } }
    if ($modo) { & sc.exe config W32Time start= $modo | Out-Null }
    Nota ('  Tipo de inicio de W32Time devuelto a Start={0}.' -f $Antes.Start) 'Cyan'
}

# ---------- 1. Comprobacion sin red ----------
Nota $(if ($ConsultarServidor) { '== Hora del equipo (lectura; se consultara el servidor de hora porque se pidio -ConsultarServidor o -Reparar) ==' } else { '== Hora del equipo (solo lectura, sin red) ==' }) 'Cyan'
$antes = Leer-W32
if (-not $antes) { Nota 'RESULTADO: no existe el servicio W32Time. No se puede seguir.' 'Red'; return }
Nota ('  W32Time: {0}, inicio {1} (Start={2}). No se arranca ni se cambia.' -f $antes.Estado, $antes.Inicio, $antes.Start)
$dominio = $false; try { $dominio = [bool](Get-CimInstance -ClassName Win32_ComputerSystem).PartOfDomain } catch { }
$par = "$svcRuta\Parameters"; $polPar = 'HKLM:\SOFTWARE\Policies\Microsoft\W32Time\Parameters'
$tipo = Leer-Valor $par 'Type'; $ntp = Leer-Valor $par 'NtpServer'
$tipoPol = Leer-Valor $polPar 'Type'; $ntpPol = Leer-Valor $polPar 'NtpServer'
if ($tipoPol) { $tipo = $tipoPol }; if ($ntpPol) { $ntp = $ntpPol }
Nota ('  Union a dominio: {0} | Type={1} | NtpServer={2}{3}' -f $(if ($dominio) { 'si' } else { 'no' }), $tipo, $ntp, $(if ($tipoPol -or $ntpPol) { ' (por directiva)' } else { '' }))
$cfg = "$svcRuta\Config"
Nota ('  Limites de correccion: MaxPosPhaseCorrection={0} s, MaxNegPhaseCorrection={1} s' -f (Leer-Valor $cfg 'MaxPosPhaseCorrection'), (Leer-Valor $cfg 'MaxNegPhaseCorrection'))
Nota ('  Hora local: {0:yyyy-MM-dd HH:mm:ss} | UTC: {1:yyyy-MM-dd HH:mm:ss} | zona: {2}' -f (Get-Date), (Get-Date).ToUniversalTime(), (Get-TimeZone).Id)

if (-not $ConsultarServidor) {
    Nota 'No se ha consultado ningun servidor de hora (la red no se usa). Para medir el desfase: -ConsultarServidor.' 'Gray'
    Nota 'RESULTADO: comprobacion terminada sin red. No se ha cambiado nada.' 'Green'
    return
}

# ---------- 2. Consultar (lo ha pedido el administrador) ----------
$srv = $Servidor
if (-not $srv) {
    if ($tipo -in @('NTP', 'AllSync') -and $ntp) { $srv = (("$ntp" -split '\s+')[0] -split ',')[0] }
}
if (-not $srv) {
    Nota ('RESULTADO: la fuente configurada (Type={0}) no es un servidor NTP con nombre. Este script no elige un servidor por su cuenta: indica cual con -Servidor. No se ha cambiado nada.' -f $tipo) 'Yellow'
    return
}
if ($antes.Estado -eq 'Running') {
    $q = Ejecutar "$env:windir\System32\w32tm.exe" '/query /status' 20
    Nota '  w32tm /query /status:'; $q.Lineas | ForEach-Object { Nota ('    ' + $_.Trim()) }
} else { Nota '  W32Time parado: no se hace w32tm /query (exigiria arrancarlo).' }
Nota ("  Se consulta el servidor {0} con w32tm /stripchart (3 muestras)..." -f $srv) 'Cyan'
$m = Medir-Desfase $srv
if ($null -eq $m.Ultimo) {
    Nota '  No se obtuvo ninguna medida:' 'Yellow'; $m.Lineas | Select-Object -Last 4 | ForEach-Object { Nota ('    ' + $_.Trim()) 'Yellow' }
    Nota 'RESULTADO: no se pudo medir el desfase (servidor inaccesible o bloqueado). No se ha cambiado nada.' 'Yellow'
    return
}
$desfase = $m.Ultimo
Nota ('  Desfase medido: {0:N3} s (muestras: {1})' -f $desfase, (($m.Valores | ForEach-Object { '{0:N3}' -f $_ }) -join ' ; '))
$bien = [Math]::Abs($desfase) -lt $MaxDesfaseSegundos
if ($bien) {
    Nota ('RESULTADO: la hora esta bien (desfase menor que {0} s). No se ha cambiado nada.' -f $MaxDesfaseSegundos) 'Green'
    return
}
Nota ('DIAGNOSTICO: la hora esta desfasada {0:N0} s: Windows Update puede fallar por certificados fuera de plazo.' -f $desfase) 'Yellow'
if (-not $Reparar) { Nota 'RESULTADO: comprobacion terminada. Para sincronizar: -Reparar. No se ha cambiado nada.' 'Yellow'; return }

# ---------- 3. Reparar ----------
if ($antes.Start -eq 4) { Nota 'RESULTADO: W32Time esta DESHABILITADO (decision del administrador). No se arranca ni se sincroniza. Corrige la hora a mano si procede.' 'Yellow'; return }
if ($tipo -eq 'NoSync') { Nota 'RESULTADO: la sincronizacion esta desactivada (Type=NoSync), a proposito o por directiva. No se cambia. Corrige la hora a mano si procede.' 'Yellow'; return }
New-Item -ItemType Directory -Force -Path $CarpetaCopia | Out-Null
& reg.exe export 'HKLM\SYSTEM\CurrentControlSet\Services\W32Time' (Join-Path $CarpetaCopia 'W32Time.reg') /y 2>$null | Out-Null
$antes | Export-Csv -Path (Join-Path $CarpetaCopia 'estado_W32Time_antes.csv') -NoTypeInformation -Encoding UTF8
Nota "Copia de seguridad en $CarpetaCopia" 'Cyan'

$ok = $true
if ($antes.Estado -ne 'Running') { $ok = Llevar-W32 'Running' 60 }
if ($ok) {
    $r = Ejecutar "$env:windir\System32\w32tm.exe" '/resync' 60
    Nota '  w32tm /resync:'; $r.Lineas | ForEach-Object { Nota ('    ' + $_.Trim()) }
    Start-Sleep -Seconds 2
}
if ($antes.Estado -ne 'Running') { [void](Llevar-W32 'Stopped' 60) }
Reponer-TipoInicio $antes
$m2 = Medir-Desfase $srv
$fin = Leer-W32
Nota ('== Despues == W32Time: {0}, inicio {1} (Start={2}); desfase: {3}' -f $fin.Estado, $fin.Inicio, $fin.Start, $(if ($null -ne $m2.Ultimo) { '{0:N3} s' -f $m2.Ultimo } else { 'no medido' })) 'Cyan'
if ($srv -ne ((("$ntp" -split '\s+')[0] -split ',')[0])) { Nota '  Nota: /resync sincroniza con la fuente configurada, no con -Servidor.' 'Gray' }
$igual = ($fin.Estado -eq $antes.Estado) -and ($fin.Start -eq $antes.Start)
if ($null -ne $m2.Ultimo -and [Math]::Abs($m2.Ultimo) -lt $MaxDesfaseSegundos -and $igual) { Nota 'RESULTADO: hora sincronizada y comprobada. W32Time queda como estaba.' 'Green' }
else {
    if (-not $igual) { Nota '  W32Time no ha quedado como estaba: revisalo.' 'Red' }
    Nota '  Si el desfase sigue: W32Time no corrige saltos mayores que MaxPos/NegPhaseCorrection; revisa esos valores o pon la hora a mano.' 'Yellow'
    Nota "RESULTADO: queda algo por revisar. Copia en $CarpetaCopia." 'Red'
}
$informe | Set-Content -Path (Join-Path $CarpetaCopia 'informe.txt') -Encoding UTF8
