<#
.SYNOPSIS
    Esquiva el callejon de TS_SetSpoolerMode.ps1: diagnostica la impresion SIN reiniciar la Cola de impresion
    (Spooler) y, si se pide, la arregla sin cortar los trabajos de nadie.
.DESCRIPTION
    Por defecto SOLO COMPRUEBA (nunca reinicia nada):
      - Estado y modo de inicio de Spooler; si responde (Get-Printer con limite de tiempo).
      - Cada cola: estado, si esta en pausa, trabajos (Get-PrintJob) con su estado y antiguedad.
      - Trabajos con error o atascados (mas antiguos que -MinutosAtasco y sin estar en pausa).
      - Archivos pendientes en la carpeta de cola (%windir%\System32\spool\PRINTERS).
    Con -Reparar:
      - Spooler parado (y no deshabilitado) -> lo arranca, con limite de espera.
      - Spooler que no responde -> lo reinicia SOLO si no hay trabajos pendientes en la carpeta de cola,
        o si se anade -ReiniciarAunqueHayaTrabajos. Antes copia los archivos de cola (*.SPL, *.SHD).
      - Spooler que responde con trabajos atascados -> NO lo reinicia (cortaria los trabajos de todos):
        informa de cada trabajo para que el administrador decida. Con -ReiniciarAunqueHayaTrabajos lo reinicia.
      - Deja el tipo de inicio de Spooler como estaba y comprueba que no se ha perdido ningun trabajo.
.PARAMETER Reparar
    Actua. Sin el, solo informa.
.PARAMETER ReiniciarAunqueHayaTrabajos
    Permite reiniciar Spooler aunque haya trabajos en cola (se copian antes los archivos de cola).
.PARAMETER MinutosAtasco
    Antiguedad a partir de la cual un trabajo que no esta en pausa se considera atascado. Por defecto 10.
.PARAMETER SegundosLimite
    Espera maxima para cada consulta o cambio de estado del servicio. Por defecto 30.
.PARAMETER CarpetaCopia
    Donde guardar la copia. Por defecto C:\Copias_Impresion\<fecha>.
.EXAMPLE
    .\2_esquivar.ps1                       # diagnosticar sin tocar nada
.EXAMPLE
    .\2_esquivar.ps1 -Reparar              # arrancar Spooler si esta parado; reiniciar solo si es seguro
.NOTES
    Libro: callejon CJ-19 (solo con diagnosticar las impresoras se cortan los trabajos en curso).
    Windows PowerShell 5.1 de 64 bits; -Reparar como administrador. No cambia el modo de inicio (ver CJ-18).
#>
[CmdletBinding()]
param(
    [switch]$Reparar,
    [switch]$ReiniciarAunqueHayaTrabajos,
    [int]$MinutosAtasco = 10,
    [int]$SegundosLimite = 30,
    [string]$CarpetaCopia = ("$env:SystemDrive\Copias_Impresion\" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
)

$ErrorActionPreference = 'Stop'
$informe = New-Object System.Collections.ArrayList
function Nota($texto, $color = 'Gray') { [void]$informe.Add($texto); Write-Host $texto -ForegroundColor $color }

if (-not [Environment]::Is64BitProcess) { throw 'Usa Windows PowerShell de 64 bits ([Environment]::Is64BitProcess debe ser True).' }
$esAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($Reparar -and -not $esAdmin) { throw 'Para -Reparar abre PowerShell como administrador. No se ha cambiado nada.' }

$svcReg = 'HKLM:\SYSTEM\CurrentControlSet\Services\Spooler'
$carpetaCola = Join-Path $env:windir 'System32\spool\PRINTERS'

function Leer-Colas {
    # Get-Printer y Get-PrintJob en un trabajo aparte, con limite de tiempo: si Spooler esta colgado no nos colgamos.
    $j = Start-Job -ScriptBlock {
        foreach ($p in @(Get-Printer -ErrorAction Stop)) {
            $trab = @(Get-PrintJob -PrinterName $p.Name -ErrorAction SilentlyContinue | ForEach-Object {
                [pscustomobject]@{ Id = $_.Id; Documento = $_.DocumentName; Usuario = $_.UserName; Estado = "$($_.JobStatus)"
                                   Enviado = $_.SubmittedTime; Paginas = $_.TotalPages; Impresas = $_.PagesPrinted; Bytes = $_.Size } })
            [pscustomobject]@{ Nombre = $p.Name; Estado = "$($p.PrinterStatus)"; Puerto = $p.PortName; Controlador = $p.DriverName; Trabajos = $trab }
        }
    }
    $fin = Wait-Job $j -Timeout $SegundosLimite
    if (-not $fin) { Stop-Job $j; Remove-Job $j -Force; return $null }
    try { $r = @(Receive-Job $j -ErrorAction Stop); return ,$r } catch { return $null } finally { Remove-Job $j -Force }
}
function Archivos-Cola { if ($esAdmin) { @(Get-ChildItem -LiteralPath $carpetaCola -File -Force -ErrorAction SilentlyContinue) } else { $null } }
function Pid-Spooler { (Get-CimInstance Win32_Service -Filter "Name='Spooler'").ProcessId }

function Diagnosticar {
    $r = [ordered]@{}
    $s = Get-Service Spooler
    $r.estado = "$($s.Status)"
    $r.start = (Get-ItemProperty $svcReg).Start
    $r.pid = Pid-Spooler
    $lc = $null
    if ($r.estado -eq 'Running') { $lc = Leer-Colas }   # asignacion directa: una lista vacia (sin colas) no se confunde con "no responde"
    $r.colas = $lc
    $r.responde = ($r.estado -eq 'Running') -and ($null -ne $lc)
    $r.trabajos = @(); $r.atascados = @()
    foreach ($c in @($r.colas)) {
        if (-not $c) { continue }
        foreach ($t in @($c.Trabajos)) {
            if (-not $t) { continue }
            $linea = '{0} #{1} "{2}" de {3}: {4}, {5}/{6} pag, enviado {7}' -f $c.Nombre, $t.Id, $t.Documento, $t.Usuario, $t.Estado, $t.Impresas, $t.Paginas, $t.Enviado
            $r.trabajos += $linea
            $enPausa = ($t.Estado -match 'Paused') -or ($c.Estado -match 'Paused')
            $conError = $t.Estado -match 'Error|Blocked|Offline|PaperOut|UserIntervention|Deleting'
            $viejo = $t.Enviado -and (((Get-Date) - [datetime]$t.Enviado).TotalMinutes -ge $MinutosAtasco)
            if ($conError -or ($viejo -and -not $enPausa)) { $r.atascados += $linea }
        }
    }
    $f = Archivos-Cola
    $r.archivos_cola = if ($null -eq $f) { 'no se puede leer sin administrador' } else { @($f).Count }
    return $r
}

Nota '== Diagnostico de impresion (solo lectura; no se reinicia nada) ==' 'Cyan'
$antes = Diagnosticar
Nota ('  Spooler: {0}, Start={1}, PID={2}, responde={3}' -f $antes.estado, $antes.start, $antes.pid, $antes.responde)
foreach ($c in @($antes.colas)) { if ($c) { Nota ('  Cola "{0}": {1}, puerto {2}, controlador {3}, trabajos {4}' -f $c.Nombre, $c.Estado, $c.Puerto, $c.Controlador, @($c.Trabajos | Where-Object { $_ }).Count) } }
foreach ($t in $antes.trabajos) { Nota "    trabajo: $t" }
foreach ($c in @($antes.colas)) { if ($c -and $c.Estado -match 'Paused' -and @($c.Trabajos | Where-Object { $_ }).Count -gt 0) { Nota ('  Aviso: la cola "{0}" esta EN PAUSA con trabajos: no imprimira hasta reanudarla (no hace falta reiniciar nada).' -f $c.Nombre) 'Yellow' } }
Nota ('  Archivos en la carpeta de cola: {0}' -f $antes.archivos_cola)

$hayTrabajos = (@($antes.trabajos).Count -gt 0) -or (($antes.archivos_cola -is [int]) -and $antes.archivos_cola -gt 0) -or ($antes.archivos_cola -isnot [int])
$accion = 'ninguna'
if ($antes.start -eq 4) { Nota 'Spooler esta DESHABILITADO: no se puede imprimir. Es una decision de configuracion; este script no la cambia (ver CJ-18).' 'Yellow' }
elseif ($antes.estado -ne 'Running') { $accion = 'arrancar'; Nota 'PROBLEMA: Spooler esta parado. Haria: arrancarlo (no hay trabajos que cortar).' 'Yellow' }
elseif (-not $antes.responde) {
    Nota "PROBLEMA: Spooler esta en marcha pero no responde en $SegundosLimite s." 'Yellow'
    if ($hayTrabajos -and -not $ReiniciarAunqueHayaTrabajos) { Nota '  Hay (o puede haber) trabajos en cola: NO se reiniciara. Si lo aceptas: -ReiniciarAunqueHayaTrabajos.' 'Yellow' }
    else { $accion = 'reiniciar' }
} elseif (@($antes.atascados).Count -gt 0) {
    Nota 'PROBLEMA: trabajos con error o atascados:' 'Yellow'; $antes.atascados | ForEach-Object { Nota "    $_" 'Yellow' }
    if ($ReiniciarAunqueHayaTrabajos) { $accion = 'reiniciar' }
    else { Nota '  Reiniciar Spooler cortaria todos los trabajos de todas las colas: NO se hace. Revisa la impresora de esos trabajos o quita solo ese trabajo (Remove-PrintJob). Para reiniciar igualmente: -ReiniciarAunqueHayaTrabajos.' 'Yellow' }
} else { Nota 'Spooler en marcha y respondiendo; sin trabajos atascados.' 'Green' }

if ($accion -eq 'ninguna') {
    if ($antes.estado -eq 'Running' -and $antes.responde -and @($antes.atascados).Count -eq 0) { Nota 'RESULTADO: la cola de impresion funciona. No hace falta cambiar nada.' 'Green' }
    else { Nota 'RESULTADO: no se ha cambiado nada (ver avisos).' 'Yellow' }
    return
}
if (-not $Reparar) { Nota "Haria: $accion Spooler. Ejecuta con -Reparar en una consola de administrador." 'Yellow'; return }

# ---------- Copia de seguridad ----------
New-Item -ItemType Directory -Force $CarpetaCopia | Out-Null
$inicioInicial = $antes.start
$retrasoInicial = (Get-ItemProperty $svcReg).DelayedAutostart
@("Spooler|Estado=$($antes.estado)|Start=$inicioInicial|DelayedAutostart=$retrasoInicial|PID=$($antes.pid)") + @($antes.trabajos) | Set-Content (Join-Path $CarpetaCopia 'estado_y_trabajos.txt')
$f = Archivos-Cola
if (@($f).Count -gt 0) { $d = Join-Path $CarpetaCopia 'spool_PRINTERS'; New-Item -ItemType Directory -Force $d | Out-Null; $f | Copy-Item -Destination $d -Force -ErrorAction SilentlyContinue }
Nota "Copia de seguridad en $CarpetaCopia" 'Cyan'

# ---------- Actuar (esperas con limite) ----------
$limite = [TimeSpan]::FromSeconds($SegundosLimite)
try {
    $s = Get-Service Spooler
    if ($accion -eq 'reiniciar') {
        Nota 'Reiniciando Spooler...' 'Cyan'
        foreach ($dep in @($s.DependentServices | Where-Object { $_.Status -eq 'Running' })) { Nota "  (tambien se para y se vuelve a arrancar: $($dep.Name))" }
        $deps = @($s.DependentServices | Where-Object { $_.Status -eq 'Running' })
        $s.Stop(); $s.WaitForStatus('Stopped', $limite)
        $s.Start(); $s.WaitForStatus('Running', $limite)
        foreach ($dep in $deps) { try { $dep.Start(); $dep.WaitForStatus('Running', $limite) } catch { } }
    } else {
        $s.Start(); $s.WaitForStatus('Running', $limite)
    }
    Nota 'Hecho: Spooler en marcha.' 'Green'
} catch { Nota ('Spooler no cambio de estado en el tiempo limite: ' + $_.Exception.Message) 'Red' }
finally {
    if ((Get-ItemProperty $svcReg).Start -ne $inicioInicial) {
        & sc.exe config Spooler start= $(if ($inicioInicial -eq 2) { if ($retrasoInicial -eq 1) { 'delayed-auto' } else { 'auto' } } elseif ($inicioInicial -eq 4) { 'disabled' } else { 'demand' }) | Out-Null
        Nota ('Tipo de inicio devuelto a su valor original (Start={0}).' -f $inicioInicial) 'Cyan'
    }
}

# ---------- Comprobacion final ----------
$despues = Diagnosticar
Nota '== Despues ==' 'Cyan'
Nota ('  Spooler: {0}, Start={1}, PID={2}, responde={3}, trabajos={4} (antes {5})' -f $despues.estado, $despues.start, $despues.pid, $despues.responde, @($despues.trabajos).Count, @($antes.trabajos).Count)
$sinPerdidas = @($despues.trabajos).Count -ge @($antes.trabajos).Count
if ($despues.responde -and $despues.start -eq $inicioInicial -and $sinPerdidas) { Nota 'RESULTADO: la cola de impresion esta en marcha y responde; no se ha perdido ningun trabajo.' 'Green' }
else { Nota "RESULTADO: queda algo por revisar (responde=$($despues.responde), trabajos conservados=$sinPerdidas). Copia en $CarpetaCopia" 'Red' }
$informe | Set-Content (Join-Path $CarpetaCopia 'informe.txt')
