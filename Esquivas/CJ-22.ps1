<#
.SYNOPSIS
    Esquiva el callejon de RS_AudioServiceResponse.ps1 y RS_aud_reg_settings.ps1: comprueba si el servicio de
    audio esta caido o no responde y lo arregla SIN matar procesos y SIN cortar un audio que funciona.
.DESCRIPTION
    Por defecto SOLO COMPRUEBA y no cambia nada:
      - AudioEndpointBuilder y Audiosrv: tipo de inicio, estado, proceso y si comparten proceso con otros servicios.
      - Si responden: se les pregunta su estado (sc interrogate) con un limite de 10 s.
      - Si hay audio en curso (proceso audiodg.exe en marcha) y los dispositivos de sonido (Win32_SoundDevice).
      - El valor DisableProtectedAudioDG que borra RS_aud_reg_settings.ps1.
    Con -Reparar:
      - Servicio deshabilitado: no se toca (es una decision del administrador; ver CJ-17 y su -Reactivar).
      - Servicio PARADO (caido): se arranca, primero AudioEndpointBuilder y despues Audiosrv, sin cambiar su
        tipo de inicio. No se corta nada porque ya no habia sonido. Tarda unos segundos (espera con limite).
      - Servicio en marcha y que responde: NO se reinicia. Es lo que evita el corte de 20-25 s.
      - Servicio en marcha que NO responde: solo se reinicia Audiosrv si ademas se da -ForzarReinicio, avisando
        de que el sonido y las llamadas se cortaran, con parada ordenada (nunca Kill) y esperas con limite.
        Si Audiosrv comparte proceso con otros servicios, no se reinicia (arrastraria a los demas).
      - DisableProtectedAudioDG: solo se quita si se pide con -QuitarDisableProtectedAudioDG, con copia del
        registro antes. El cambio se aplica cuando el servicio de audio vuelva a arrancar; para aplicarlo ya
        hace falta -ForzarReinicio (corta el sonido unos segundos).
    Al final comprueba que los dos servicios estan en marcha, responden y conservan su tipo de inicio.
.EXAMPLE
    .\2_esquivar.ps1
    Solo comprobar.
.EXAMPLE
    .\2_esquivar.ps1 -Reparar
    Arranca el audio si esta caido. Si funciona, no toca nada.
.EXAMPLE
    .\2_esquivar.ps1 -Reparar -ForzarReinicio
    Ademas, si Audiosrv esta en marcha pero no responde, lo reinicia (corta el sonido unos segundos).
.NOTES
    Libro «Lo que Microsoft no explica» - callejon CJ-22: el sonido y las llamadas se cortan unos 20-25 segundos.
    Windows PowerShell 5.1 de 64 bits. Para -Reparar, consola de administrador. Sin Read-Host, sin reinicios del equipo.
#>
[CmdletBinding()]
param(
    [switch]$Reparar,
    [switch]$ForzarReinicio,
    [switch]$QuitarDisableProtectedAudioDG,
    [ValidateRange(5, 120)][int]$SegundosEspera = 30,
    [string]$CarpetaCopia = ("$env:SystemDrive\Copias_Audio\" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
)

$ErrorActionPreference = 'Stop'
$informe = New-Object System.Collections.ArrayList
function Nota($texto, $color = 'Gray') { [void]$informe.Add($texto); Write-Host $texto -ForegroundColor $color }

if (-not [Environment]::Is64BitProcess) { throw 'Usa Windows PowerShell de 64 bits ([Environment]::Is64BitProcess debe ser True).' }
$esAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($Reparar -and -not $esAdmin) { throw 'Para -Reparar abre PowerShell como administrador. No se ha cambiado nada.' }
if (($ForzarReinicio -or $QuitarDisableProtectedAudioDG) -and -not $Reparar) { throw '-ForzarReinicio y -QuitarDisableProtectedAudioDG cambian el sistema: usalos junto con -Reparar.' }

$ClaveAudio = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Audio'
$ValorDG = 'DisableProtectedAudioDG'
$Servs = @('AudioEndpointBuilder', 'Audiosrv')      # orden de arranque

function Leer-Servicio([string]$Nombre) {
    $w = Get-CimInstance -ClassName Win32_Service -Filter ("Name='{0}'" -f $Nombre) -ErrorAction SilentlyContinue
    if (-not $w) { return [pscustomobject]@{ Nombre = $Nombre; Existe = $false } }
    $tipo = switch ($w.StartMode) { 'Auto' { if ($w.DelayedAutoStart) { 'delayed-auto' } else { 'auto' } } 'Manual' { 'demand' } 'Disabled' { 'disabled' } default { "$($w.StartMode)".ToLower() } }
    $comp = @()
    if ($w.ProcessId -gt 0) { $comp = @(Get-CimInstance -ClassName Win32_Service -Filter ("ProcessId={0}" -f $w.ProcessId) | Where-Object { $_.Name -ne $Nombre } | ForEach-Object { $_.Name }) }
    return [pscustomobject]@{ Nombre = $w.Name; Existe = $true; Tipo = $tipo; Estado = "$($w.State)"; Pid = [int]$w.ProcessId; Comparte = $comp }
}
# sc interrogate pide al servicio que informe de su estado: si esta colgado no contesta. Limite de 10 s.
function Responde([string]$Nombre) {
    $p = Start-Process -FilePath "$env:windir\System32\sc.exe" -ArgumentList @('interrogate', $Nombre) -WindowStyle Hidden -PassThru
    $null = $p.Handle
    if (-not $p.WaitForExit(10000)) { try { $p.Kill() } catch { }; return $false }
    return ($p.ExitCode -eq 0)
}
function Esperar-Estado([string]$Nombre, [string]$Estado) {
    $sc = New-Object System.ServiceProcess.ServiceController $Nombre
    try { $sc.WaitForStatus($Estado, [TimeSpan]::FromSeconds($SegundosEspera)); return $true } catch { return $false } finally { $sc.Dispose() }
}
function Arrancar([string]$Nombre) {
    $sc = New-Object System.ServiceProcess.ServiceController $Nombre
    try { if ($sc.Status -ne 'Running') { $sc.Start() } } finally { $sc.Dispose() }
    return (Esperar-Estado $Nombre 'Running')
}
function Leer-DG {
    $k = Get-Item -LiteralPath $ClaveAudio -ErrorAction SilentlyContinue
    if ($k -and (@($k.GetValueNames()) -contains $ValorDG)) { return $k.GetValue($ValorDG) }
    return $null
}

# ---------------------------------------------------------------- comprobacion
Nota '== Comprobacion del audio (solo lectura) ==' 'Cyan'
$antes = @{}
$problemas = @()
foreach ($n in $Servs) {
    $s = Leer-Servicio $n
    $antes[$n] = $s
    if (-not $s.Existe) { Nota "  $n NO EXISTE" 'Red'; $problemas += "$n no existe"; continue }
    $resp = $null
    if ($s.Estado -eq 'Running') { $resp = Responde $n; $s | Add-Member -NotePropertyName Responde -NotePropertyValue $resp }
    $txtComp = $(if ($s.Comparte.Count) { 'comparte proceso con ' + ($s.Comparte -join ', ') } else { 'proceso propio' })
    Nota ("  {0,-21} inicio={1,-13} estado={2,-8} pid={3,-6} {4}{5}" -f $n, $s.Tipo, $s.Estado, $s.Pid, $txtComp, $(if ($null -ne $resp) { ' | responde=' + $resp } else { '' }))
    if ($s.Tipo -eq 'disabled') { $problemas += "$n esta DESHABILITADO: no se toca (si fue a proposito, es lo esperado; para reactivarlo usa el esquivar de CJ-17 con -Reactivar $n)" }
    elseif ($s.Estado -ne 'Running') { $problemas += "$n esta PARADO (caido): -Reparar lo arrancaria sin cambiar su tipo de inicio" }
    elseif (-not $resp) { $problemas += "$n esta en marcha pero NO RESPONDE: solo se reinicia con -Reparar -ForzarReinicio (corta el sonido)" }
}
$audiodg = @(Get-Process -Name audiodg -ErrorAction SilentlyContinue)
if ($audiodg.Count) { Nota ("  audiodg.exe en marcha (pid {0}): hay sonido o una llamada en curso; un reinicio del audio lo cortaria." -f (($audiodg | ForEach-Object { $_.Id }) -join ',')) 'DarkYellow' }
else { Nota '  audiodg.exe no esta en marcha (ahora mismo no se esta reproduciendo ni grabando nada).' }
foreach ($d in @(Get-CimInstance -ClassName Win32_SoundDevice -ErrorAction SilentlyContinue)) {
    Nota ("  dispositivo de sonido: {0} | {1} | codigo {2}" -f $d.Name, $d.Status, $d.ConfigManagerErrorCode)
}
$dg = Leer-DG
if ($null -ne $dg) {
    Nota ("  {0} = {1} en {2}: RS_aud_reg_settings.ps1 lo borraria sin copia." -f $ValorDG, $dg, $ClaveAudio) 'DarkYellow'
    if ($QuitarDisableProtectedAudioDG) { $problemas += "$ValorDG presente y el administrador pide quitarlo" }
    else { Nota "      -> se respeta. Para quitarlo (con copia): -Reparar -QuitarDisableProtectedAudioDG" 'DarkYellow' }
} else { Nota "  $ValorDG no existe (valor por defecto)." }

$hayAccion = @($problemas | Where-Object { $_ -notmatch 'DESHABILITADO' }).Count -gt 0
if ($problemas.Count -eq 0) { Nota 'RESULTADO: el audio esta en marcha y responde. No hace falta reiniciar nada.' 'Green'; return }
Nota 'PROBLEMAS ENCONTRADOS:' 'Yellow'; $problemas | ForEach-Object { Nota "  - $_" 'Yellow' }
if (-not $Reparar) { if ($hayAccion) { Nota 'Para arreglarlo, ejecuta de nuevo con -Reparar en una consola de administrador.' 'Yellow' }; return }
if (-not $hayAccion) { Nota 'RESULTADO: no hay nada que este en manos de este script; los servicios deshabilitados se respetan.' 'Yellow'; return }

# ---------------------------------------------------------------- 1. copia de seguridad
New-Item -ItemType Directory -Force $CarpetaCopia | Out-Null
foreach ($n in $Servs) { if ($antes[$n].Existe) { (& sc.exe qc $n) | Set-Content (Join-Path $CarpetaCopia ($n + '_sc_qc.txt')) } }
& reg.exe export 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Audio' (Join-Path $CarpetaCopia 'Audio.reg') /y | Out-Null
$antes.Values | Select-Object Nombre, Tipo, Estado, Pid | ConvertTo-Json | Set-Content (Join-Path $CarpetaCopia 'estado_antes.json') -Encoding UTF8
Nota "Copia de seguridad en $CarpetaCopia" 'Cyan'
$fallos = @()
$reloj = [Diagnostics.Stopwatch]::StartNew()

# ---------------------------------------------------------------- 2. DisableProtectedAudioDG (solo si se pide)
if ($QuitarDisableProtectedAudioDG -and ($null -ne $dg)) {
    Remove-ItemProperty -LiteralPath $ClaveAudio -Name $ValorDG -Force
    Nota "Hecho: $ValorDG quitado (copia en Audio.reg). Se aplica cuando Audiosrv vuelva a arrancar." 'Green'
}

# ---------------------------------------------------------------- 3. arrancar lo que este caido (sin cortar nada)
foreach ($n in $Servs) {
    $s = $antes[$n]
    if (-not $s.Existe -or $s.Tipo -eq 'disabled' -or $s.Estado -eq 'Running') { continue }
    Nota ("Arrancando {0} (estaba parado; espera maxima {1} s)..." -f $n, $SegundosEspera) 'Cyan'
    try { if (Arrancar $n) { Nota "Hecho: $n en marcha." 'Green' } else { $fallos += "$n no llego a Running en $SegundosEspera s" } }
    catch { $fallos += ("{0}: {1}" -f $n, $_.Exception.Message) }
}

# ---------------------------------------------------------------- 4. reinicio de Audiosrv, solo si se fuerza
$a = $antes['Audiosrv']
$pedirReinicio = $a.Existe -and $a.Estado -eq 'Running' -and ((-not $a.Responde) -or ($QuitarDisableProtectedAudioDG -and $null -ne $dg))
if ($pedirReinicio -and -not $ForzarReinicio) {
    Nota 'Audiosrv no se reinicia: haria falta -ForzarReinicio (cortaria el sonido y las llamadas unos segundos).' 'Yellow'
}
if ($pedirReinicio -and $ForzarReinicio) {
    $comp = @((Leer-Servicio 'Audiosrv').Comparte)
    if ($comp.Count) { $fallos += ('Audiosrv comparte proceso con {0}: no se reinicia para no arrastrarlos. Reinicia el equipo cuando no moleste.' -f ($comp -join ', ')) }
    else {
        Nota ("AVISO: se reinicia Audiosrv. El sonido y las llamadas se cortaran unos segundos (maximo {0} s por paso)." -f $SegundosEspera) 'Yellow'
        try {
            $sc = New-Object System.ServiceProcess.ServiceController 'Audiosrv'
            try { $sc.Stop() } finally { $sc.Dispose() }      # parada ordenada; .NET para antes sus dependientes (AarSvc)
            if (-not (Esperar-Estado 'Audiosrv' 'Stopped')) { $fallos += "Audiosrv no se paro en $SegundosEspera s: no se mata el proceso; reinicia el equipo cuando no moleste." }
            elseif (Arrancar 'Audiosrv') { Nota 'Hecho: Audiosrv reiniciado.' 'Green' }
            else { $fallos += "Audiosrv no volvio a Running en $SegundosEspera s" }
        } catch { $fallos += ('Audiosrv: ' + $_.Exception.Message) }
    }
}
$reloj.Stop()

# ---------------------------------------------------------------- 5. tipo de inicio intacto y comprobacion final
foreach ($n in $Servs) {
    if (-not $antes[$n].Existe) { continue }
    $d = Leer-Servicio $n
    if ($d.Tipo -ne $antes[$n].Tipo) {
        & sc.exe config $n start= $antes[$n].Tipo | Out-Null
        Nota ("Tipo de inicio de {0} devuelto a {1} (habia cambiado a {2})." -f $n, $antes[$n].Tipo, $d.Tipo) 'Cyan'
    }
}
Nota '== Despues ==' 'Cyan'
$bien = $true
foreach ($n in $Servs) {
    if (-not $antes[$n].Existe) { $bien = $false; continue }
    $d = Leer-Servicio $n
    if ($d.Tipo -eq 'disabled') { Nota ("  {0}: deshabilitado (respetado)" -f $n) 'DarkYellow'; $bien = $false; continue }
    $r = ($d.Estado -eq 'Running') -and (Responde $n)
    if (-not $r) { $bien = $false }
    Nota ("  {0,-21} inicio={1,-13} estado={2,-8} pid={3,-6} (antes {4}, pid {5}) responde={6}" -f $n, $d.Tipo, $d.Estado, $d.Pid, $antes[$n].Estado, $antes[$n].Pid, $r) $(if ($r) { 'Green' } else { 'Red' })
}
Nota ("  Tiempo de la reparacion: {0:N1} s" -f $reloj.Elapsed.TotalSeconds)
if ($QuitarDisableProtectedAudioDG) { Nota ("  {0}: {1}" -f $ValorDG, $(if ($null -eq (Leer-DG)) { 'quitado' } else { 'SIGUE' })) }
foreach ($f in $fallos) { Nota "  FALLO: $f" 'Red' }
if ($bien -and $fallos.Count -eq 0) { Nota 'RESULTADO: audio en marcha y respondiendo; no se ha matado ningun proceso ni se ha reiniciado lo que funcionaba.' 'Green' }
else { Nota "RESULTADO: queda algo por revisar. Copia en $CarpetaCopia (reg import `"$CarpetaCopia\Audio.reg`" repone DisableProtectedAudioDG)." 'Red' }
$informe | Set-Content (Join-Path $CarpetaCopia 'informe.txt')
