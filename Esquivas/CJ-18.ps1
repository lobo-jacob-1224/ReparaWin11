<#
.SYNOPSIS
    Esquiva el callejon de RS_SetSpoolerStartMode.ps1: deja la Cola de impresion (Spooler) en inicio
    automatico y en marcha SIN tocar el servicio de escaneres (StiSvc) y sin fijar el nombre visible.
.DESCRIPTION
    Por defecto SOLO COMPRUEBA y no cambia nada: modo de inicio y estado de Spooler y StiSvc, y si su
    nombre visible (DisplayName en el registro) es la referencia de recurso de Windows (@...dll,-n) o un
    texto fijo (la huella que deja ChangeStartMode de WMI, medida en el laboratorio).
    Con -Reparar:
      1. Copia de seguridad: reg export de las claves de los dos servicios y estado en texto.
      2. Spooler en Manual -> Automatico con "sc.exe config Spooler start= auto" (no reescribe el nombre).
         Spooler Deshabilitado se respeta (puede ser una medida de seguridad); solo se habilita con -HabilitarSpooler.
      3. Si Spooler esta parado, lo arranca (espera con limite).
      4. Si el nombre visible de Spooler o StiSvc es un texto fijo, devuelve la referencia de recurso,
         SOLO si se comprueba que esa referencia produce exactamente el mismo texto.
      5. StiSvc: su modo de inicio NO se toca, salvo que se indique con -ModoInicioStiSvc.
      6. Comprueba el resultado.
.PARAMETER Reparar
    Actua. Sin el, solo informa.
.PARAMETER HabilitarSpooler
    Con -Reparar, si Spooler esta Deshabilitado, lo pasa a Automatico. Sin el, se respeta.
.PARAMETER ModoInicioStiSvc
    Manual, Automatico o Deshabilitado. Solo si se indica se cambia el modo de inicio de StiSvc
    (p. ej. para devolverlo a Manual despues de que el solucionador de Microsoft lo pusiera en Automatico).
.PARAMETER CarpetaCopia
    Donde guardar la copia. Por defecto C:\Copias_Impresion\<fecha>.
.EXAMPLE
    .\2_esquivar.ps1                                   # solo comprobar
.EXAMPLE
    .\2_esquivar.ps1 -Reparar                          # Spooler automatico y en marcha; nombres restaurados
.EXAMPLE
    .\2_esquivar.ps1 -Reparar -ModoInicioStiSvc Manual # ademas devolver StiSvc a Manual
.NOTES
    Libro: callejon CJ-18 (la cola de impresion y el servicio de escaneres pasan a automatico y el nombre
    del servicio queda fijo en espanol). Windows PowerShell 5.1 de 64 bits; -Reparar como administrador.
    No reinicia Spooler en ningun caso (si ya esta en marcha, sigue igual: los trabajos en curso no se cortan).
    Para volver atras: reg import de los .reg de la carpeta de copia y "sc.exe config" con los valores de estado.txt.
#>
[CmdletBinding()]
param(
    [switch]$Reparar,
    [switch]$HabilitarSpooler,
    [ValidateSet('', 'Manual', 'Automatico', 'Deshabilitado')][string]$ModoInicioStiSvc = '',
    [string]$CarpetaCopia = ("$env:SystemDrive\Copias_Impresion\" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
)

$ErrorActionPreference = 'Stop'
$informe = New-Object System.Collections.ArrayList
function Nota($texto, $color = 'Gray') { [void]$informe.Add($texto); Write-Host $texto -ForegroundColor $color }

if (-not [Environment]::Is64BitProcess) { throw 'Usa Windows PowerShell de 64 bits ([Environment]::Is64BitProcess debe ser True).' }
$esAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($Reparar -and -not $esAdmin) { throw 'Para -Reparar abre PowerShell como administrador. No se ha cambiado nada.' }

if (-not ('Esq18.Texto' -as [type])) {
    Add-Type -Namespace Esq18 -Name Texto -MemberDefinition '[DllImport("shlwapi.dll", CharSet = CharSet.Unicode)] public static extern int SHLoadIndirectString(string src, System.Text.StringBuilder dst, int cch, IntPtr r);'
}
function Resolver([string]$Ref) {
    $sb = New-Object System.Text.StringBuilder 1024
    if ([Esq18.Texto]::SHLoadIndirectString([Environment]::ExpandEnvironmentVariables($Ref), $sb, 1024, [IntPtr]::Zero) -eq 0) { return $sb.ToString() }
    return $null
}
function Nombre-Inicio($start) { switch ($start) { 0 { 'Arranque' } 1 { 'Sistema' } 2 { 'Automatico' } 3 { 'Manual' } 4 { 'Deshabilitado' } default { "desconocido($start)" } } }
$scInicio = @{ 'Manual' = 'demand'; 'Automatico' = 'auto'; 'Deshabilitado' = 'disabled' }

function Leer-Servicio([string]$Nombre) {
    $ruta = "HKLM:\SYSTEM\CurrentControlSet\Services\$Nombre"
    if (-not (Test-Path $ruta)) { return $null }
    $k = Get-Item $ruta
    $s = Get-Service $Nombre
    $r = [ordered]@{}
    $r.nombre = $Nombre
    $r.start = $k.GetValue('Start')
    $r.inicio = Nombre-Inicio $r.start
    $r.retrasado = $k.GetValue('DelayedAutostart')
    $r.estado = "$($s.Status)"
    $r.displayname_registro = $k.GetValue('DisplayName', $null, 'DoNotExpandEnvironmentNames')
    $r.nombre_es_referencia = ("$($r.displayname_registro)" -like '@*')
    # referencia candidata: la Description de Windows es "@archivo,-n" y el nombre es "@archivo,-(n-1)" (comprobado en Spooler y StiSvc)
    $r.referencia_candidata = $null
    $d = $k.GetValue('Description', $null, 'DoNotExpandEnvironmentNames')
    if (-not $r.nombre_es_referencia -and "$d" -match '^(@.+,-)(\d+)$') {
        $cand = $Matches[1] + ([int]$Matches[2] - 1)
        if ((Resolver $cand) -ceq $r.displayname_registro) { $r.referencia_candidata = $cand }
    }
    return $r
}

Nota '== Cola de impresion y servicio de escaneres (solo lectura) ==' 'Cyan'
$sp = Leer-Servicio 'Spooler'; $st = Leer-Servicio 'StiSvc'
if (-not $sp) { Nota 'RESULTADO: el servicio Spooler no existe en este equipo.' 'Red'; return }
foreach ($x in @($sp, $st) | Where-Object { $_ }) { Nota ('  {0,-8} inicio={1} estado={2} DisplayName="{3}"' -f $x.nombre, $x.inicio, $x.estado, $x.displayname_registro) }

$cambios = @()
if ($sp.start -eq 3) { $cambios += 'Spooler en Manual -> pasarlo a Automatico (sc.exe config, sin reescribir el nombre)' }
if ($sp.start -eq 4) {
    if ($HabilitarSpooler) { $cambios += 'Spooler Deshabilitado -> pasarlo a Automatico (pedido con -HabilitarSpooler)' }
    else { Nota 'Spooler esta DESHABILITADO: puede ser una decision de seguridad. Se respeta; para habilitarlo usa -HabilitarSpooler.' 'Yellow' }
}
if ($sp.estado -ne 'Running' -and ($sp.start -ne 4 -or $HabilitarSpooler)) { $cambios += 'Spooler parado -> arrancarlo' }
foreach ($x in @($sp, $st) | Where-Object { $_ }) {
    if (-not $x.nombre_es_referencia) {
        if ($x.referencia_candidata) { $cambios += ('{0}: nombre visible fijo "{1}" -> devolver la referencia {2}' -f $x.nombre, $x.displayname_registro, $x.referencia_candidata) }
        else { Nota ('{0}: nombre visible fijo y no se puede deducir su referencia con seguridad: no se toca.' -f $x.nombre) 'Yellow' }
    }
}
if ($st) {
    if ($ModoInicioStiSvc) {
        if ($st.inicio -ne $ModoInicioStiSvc) { $cambios += "StiSvc: $($st.inicio) -> $ModoInicioStiSvc (pedido con -ModoInicioStiSvc)" }
    } elseif ($st.start -eq 2) {
        Nota 'StiSvc (escaneres) esta en Automatico. Si no lo elegiste tu (lo hace RS_SetSpoolerStartMode), usa -ModoInicioStiSvc Manual. No se toca.' 'Yellow'
    }
}

if ($cambios.Count -eq 0) { Nota 'RESULTADO: la Cola de impresion esta bien (automatica y en marcha). No hace falta cambiar nada.' 'Green'; return }
Nota 'CAMBIOS NECESARIOS:' 'Yellow'; $cambios | ForEach-Object { Nota "  - $_" 'Yellow' }
if (-not $Reparar) { Nota 'Ejecuta con -Reparar en una consola de administrador para aplicarlos.' 'Yellow'; return }

# ---------- 1. Copia de seguridad ----------
New-Item -ItemType Directory -Force $CarpetaCopia | Out-Null
foreach ($x in @($sp, $st) | Where-Object { $_ }) {
    & reg.exe export "HKLM\SYSTEM\CurrentControlSet\Services\$($x.nombre)" (Join-Path $CarpetaCopia "$($x.nombre).reg") /y | Out-Null
    ('{0}|Start={1}|DelayedAutostart={2}|Estado={3}|DisplayName={4}' -f $x.nombre, $x.start, $x.retrasado, $x.estado, $x.displayname_registro) | Add-Content (Join-Path $CarpetaCopia 'estado.txt')
}
Nota "Copia de seguridad en $CarpetaCopia" 'Cyan'
$pidAntes = (Get-CimInstance Win32_Service -Filter "Name='Spooler'").ProcessId

# ---------- 2. Modo de inicio de Spooler (sc.exe: no toca DisplayName) ----------
if ($sp.start -eq 3 -or ($sp.start -eq 4 -and $HabilitarSpooler)) {
    $o = & sc.exe config Spooler start= auto
    if ($LASTEXITCODE -ne 0) { Nota ('Error al cambiar el inicio de Spooler: ' + ($o -join ' ')) 'Red' } else { Nota 'Hecho: Spooler en inicio Automatico.' 'Green' }
}
# ---------- 3. Arrancar Spooler si esta parado ----------
if ((Get-Service Spooler).Status -ne 'Running' -and ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Spooler').Start -ne 4)) {
    try { $s = Get-Service Spooler; $s.Start(); $s.WaitForStatus('Running', [TimeSpan]::FromSeconds(30)); Nota 'Hecho: Spooler arrancado.' 'Green' }
    catch { Nota ('Spooler no arranco en 30 s: ' + $_.Exception.Message) 'Red' }
}
# ---------- 4. Nombre visible ----------
foreach ($x in @($sp, $st) | Where-Object { $_ -and $_.referencia_candidata }) {
    $o = & sc.exe config $x.nombre DisplayName= $x.referencia_candidata
    $ruta = "HKLM:\SYSTEM\CurrentControlSet\Services\$($x.nombre)"
    if ((Get-Item $ruta).GetValue('DisplayName', $null, 'DoNotExpandEnvironmentNames') -cne $x.referencia_candidata) {
        Set-ItemProperty -Path $ruta -Name DisplayName -Value $x.referencia_candidata -Type String   # si sc.exe no lo guardo tal cual
    }
    Nota ('Hecho: {0} DisplayName = {1}' -f $x.nombre, $x.referencia_candidata) 'Green'
}
# ---------- 5. StiSvc solo si se pide ----------
if ($st -and $ModoInicioStiSvc -and $st.inicio -ne $ModoInicioStiSvc) {
    $o = & sc.exe config StiSvc start= $scInicio[$ModoInicioStiSvc]
    if ($LASTEXITCODE -ne 0) { Nota ('Error al cambiar StiSvc: ' + ($o -join ' ')) 'Red' } else { Nota "Hecho: StiSvc en $ModoInicioStiSvc." 'Green' }
}

# ---------- 6. Comprobacion final ----------
$sp2 = Leer-Servicio 'Spooler'; $st2 = Leer-Servicio 'StiSvc'
$pidDespues = (Get-CimInstance Win32_Service -Filter "Name='Spooler'").ProcessId
Nota '== Despues ==' 'Cyan'
foreach ($x in @($sp2, $st2) | Where-Object { $_ }) { Nota ('  {0,-8} inicio={1} estado={2} DisplayName="{3}"' -f $x.nombre, $x.inicio, $x.estado, $x.displayname_registro) }
$ok = ($sp2.estado -eq 'Running') -and ($sp2.start -eq 2 -or ($sp2.start -eq 4 -and -not $HabilitarSpooler))
if ($sp.estado -eq 'Running' -and $pidAntes -ne $pidDespues) { $ok = $false; Nota 'Aviso: el proceso de Spooler ha cambiado (no deberia).' 'Red' }
if ($st2 -and -not $ModoInicioStiSvc -and $st2.start -ne $st.start) { $ok = $false; Nota 'Aviso: el inicio de StiSvc ha cambiado sin pedirlo.' 'Red' }
if ($st2 -and $ModoInicioStiSvc -and $st2.inicio -ne $ModoInicioStiSvc) { $ok = $false }
foreach ($par in @(@($sp, $sp2), @($st, $st2))) {
    if ($par[0] -and $par[0].referencia_candidata -and $par[1].displayname_registro -cne $par[0].referencia_candidata) { $ok = $false }
    if ($par[0] -and -not $par[0].referencia_candidata -and $par[1].displayname_registro -cne $par[0].displayname_registro) { $ok = $false; Nota "Aviso: el nombre de $($par[0].nombre) ha cambiado sin pedirlo." 'Red' }
}
if ($sp2.start -eq 4 -and -not $HabilitarSpooler) { Nota 'RESULTADO: Spooler sigue deshabilitado a proposito; el resto queda como se pidio.' 'Yellow' }
elseif ($ok) { Nota 'RESULTADO: la Cola de impresion esta en Automatico y en marcha; StiSvc y los nombres visibles quedan como se pidio.' 'Green' }
else { Nota "RESULTADO: queda algo por revisar. Copia en $CarpetaCopia" 'Red' }
$informe | Set-Content (Join-Path $CarpetaCopia 'informe.txt')
