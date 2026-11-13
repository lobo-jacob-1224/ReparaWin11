<#
.SYNOPSIS
    Esquiva los callejones del indice de busqueda (CJ-15 y CJ-35): guarda el alcance indexado y
    las reglas (CrawlScopeManager) y los permisos (ACL) de la carpeta del indice, reinicia el
    servicio con cuidado, restaura alcance y permisos, y solo reconstruye el indice si se pide.
.DESCRIPTION
    Por defecto SOLO COMPRUEBA y no cambia nada:
      - Estado y tipo de inicio de WSearch.
      - Valor SetupCompletedSuccessfully (ponerlo a 0 es la trampa de RS_RestoreDefaults, que
        vacia el indice entero y pierde las carpetas anadidas a mano).
      - Tamano del indice (Windows.db) y numero de reglas de alcance (SearchRoots / WorkingSetRules).
      - Resumen de permisos de la carpeta de datos del indice.
    Siempre que se vaya a actuar, primero copia: exporta la clave CrawlScopeManager (reg export,
    solo lectura) y guarda las ACL con icacls /save.

    -Reparar          reinicia WSearch con limite de tiempo, SIN tocar SetupCompletedSuccessfully
                      y dejando el tipo de inicio como estaba.
    -RestaurarScope <archivo.reg>   vuelve a meter (reg import) el alcance guardado, para
                      recuperar las carpetas que la trampa saco del indice.
    -RestaurarAcl <archivo>         repone los permisos guardados con icacls /restore (CJ-35).
    -Reconstruir      pide una reconstruccion del indice por COM (operacion pesada; solo si hace
                      falta de verdad). Conserva el alcance.
.EXAMPLE
    .\2_esquivar.ps1
    .\2_esquivar.ps1 -Reparar
    .\2_esquivar.ps1 -Reparar -RestaurarScope C:\Copias_Busqueda\20261113\CrawlScopeManager.reg
.NOTES
    Libro "Lo que Microsoft no explica" - CJ-15 (RS_RestoreDefaults) y CJ-35 (RS_RestorePermissions).
    Windows PowerShell 5.1 de 64 bits.
#>
[CmdletBinding()]
param(
    [switch]$Reparar,
    [string]$RestaurarScope,
    [string]$RestaurarAcl,
    [switch]$Reconstruir,
    [string]$DirDatosPrueba,   # solo para pruebas de laboratorio: aisla el save/restore de ACL a una carpeta de C:\LabExp
    [string]$CarpetaCopia = ("$env:SystemDrive\Copias_Busqueda\" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
)

$ErrorActionPreference = 'Stop'
$modoPrueba = [bool]$DirDatosPrueba
$raizReg = 'HKLM:\SOFTWARE\Microsoft\Windows Search'
$csm = 'HKLM\SOFTWARE\Microsoft\Windows Search\CrawlScopeManager'
$informe = New-Object System.Collections.ArrayList
function Nota($t, $c = 'Gray') { [void]$informe.Add($t); Write-Host $t -ForegroundColor $c }
# reg.exe e icacls.exe escriben avisos (incluso "La operacion se completo correctamente") por stderr. En Windows
# PowerShell 5.1, con ErrorActionPreference=Stop y stderr redirigido, eso corta el script. Se llaman con Continue
# y se decide por el codigo de salida.
function Nativo([string]$Exe) {
    $antes = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & $Exe @args 2>&1 | Out-Null; return $LASTEXITCODE } finally { $ErrorActionPreference = $antes }
}

$esAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$actuar = $Reparar -or $RestaurarScope -or $RestaurarAcl -or $Reconstruir
if ($actuar -and -not $esAdmin) { throw 'Para actuar abre PowerShell como administrador. No se ha cambiado nada.' }

function Dir-Datos {
    if ($modoPrueba) { $d = $DirDatosPrueba }
    else { $d = (Get-ItemProperty $raizReg -ErrorAction SilentlyContinue).DataDirectory }
    if ([string]::IsNullOrEmpty($d)) { $d = "$env:ProgramData\Microsoft\Search\Data\" }
    if (-not $d.EndsWith('\')) { $d += '\' }
    return $d
}
function Contar-Subclaves([string]$sub) {
    $p = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows Search\CrawlScopeManager\Windows\SystemIndex\$sub"
    if (-not (Test-Path $p)) { return 0 }
    return @(Get-ChildItem $p -ErrorAction SilentlyContinue).Count
}

# ---------- Comprobacion ----------
Nota '== Comprobacion del indice de busqueda (solo lectura) ==' 'Cyan'
$svc = Get-Service WSearch -ErrorAction SilentlyContinue
if ($svc) { Nota ("  WSearch: {0} / {1}" -f $svc.Status, $svc.StartType) } else { Nota '  WSearch: no existe' 'Red' }
$inicioInicial = if ($svc) { (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\WSearch').Start } else { $null }
$setup = (Get-ItemProperty $raizReg -ErrorAction SilentlyContinue).SetupCompletedSuccessfully
Nota ("  SetupCompletedSuccessfully = {0} {1}" -f $setup, $(if ($setup -eq 0) { '<- indice marcado para RESET (trampa de CJ-15)' } else { '(ok)' })) $(if ($setup -eq 0) { 'Yellow' } else { 'Gray' })
$datos = Dir-Datos
$dbWin = Join-Path $datos 'Applications\Windows\Windows.db'
try {
    if (Test-Path -LiteralPath $dbWin) { Nota ("  Indice Windows.db = {0} MB" -f [Math]::Round((Get-Item $dbWin).Length / 1MB, 2)) }
    else { Nota '  Windows.db: no existe (indice vaciado o aun sin construir)' 'Yellow' }
} catch { Nota '  Windows.db: sin acceso (carpeta del indice protegida; normal sin ser SYSTEM)' }
Nota ("  Reglas de alcance: SearchRoots={0}  WorkingSetRules={1}  DefaultRules={2}" -f (Contar-Subclaves 'SearchRoots'), (Contar-Subclaves 'WorkingSetRules'), (Contar-Subclaves 'DefaultRules'))
$aclResumen = try { (& icacls.exe $datos.TrimEnd('\')) 2>$null | Select-Object -First 6 } catch { @() }
Nota '  Permisos de la carpeta de datos (icacls):'
$aclResumen | ForEach-Object { Nota ("    " + $_) }

if (-not $actuar) {
    Nota 'RESULTADO: solo comprobacion. Nada cambiado.' 'Green'
    Nota 'Antes de usar el solucionador de Microsoft, guarda alcance y permisos con -Reparar (hace copia).' 'Cyan'
    return
}

# ---------- Copia de seguridad (siempre antes de actuar) ----------
New-Item -ItemType Directory -Force $CarpetaCopia | Out-Null
if (-not $modoPrueba) { if ((Nativo reg.exe export $csm (Join-Path $CarpetaCopia 'CrawlScopeManager.reg') /y) -ne 0) { throw 'No se pudo copiar el alcance (CrawlScopeManager). No se ha cambiado nada.' } }
$aclFile = Join-Path $CarpetaCopia 'permisos_datos.acl'
$codAcl = Nativo icacls.exe ($datos.TrimEnd('\')) /save $aclFile /t /c /q
if (-not (Test-Path -LiteralPath $aclFile) -or (Get-Item -LiteralPath $aclFile).Length -eq 0) { throw 'No se pudo guardar la copia de permisos (icacls /save). No se ha cambiado nada.' }
if ($codAcl -ne 0) { Nota ("  Aviso: icacls /save termino con codigo {0}: algun archivo no se pudo leer (normal en archivos abiertos por WSearch); la copia de la carpeta si esta." -f $codAcl) 'Yellow' }
Nota ("Copia de alcance y permisos en {0}" -f $CarpetaCopia) 'Cyan'

# ---------- Restaurar permisos (CJ-35) ----------
if ($RestaurarAcl) {
    if (-not (Test-Path $RestaurarAcl)) { Nota ("AVISO: no existe {0}; permisos no restaurados." -f $RestaurarAcl) 'Red' }
    else {
        $padre = Split-Path ($datos.TrimEnd('\')) -Parent
        $codR = Nativo icacls.exe $padre /restore $RestaurarAcl /c /q
        if ($codR -eq 0) { Nota 'Hecho: permisos de la carpeta del indice restaurados (icacls /restore).' 'Green' }
        else { Nota ("AVISO: icacls /restore termino con codigo {0}: algun permiso no se repuso. Revisa con icacls '{1}'." -f $codR, $datos.TrimEnd('\')) 'Red' }
    }
}

# ---------- Restaurar alcance (CJ-15) ----------
if ($RestaurarScope -and -not $modoPrueba) {
    if (-not (Test-Path $RestaurarScope)) { Nota ("AVISO: no existe {0}; alcance no restaurado." -f $RestaurarScope) 'Red' }
    else {
        $codS = Nativo reg.exe import $RestaurarScope
        if ($codS -eq 0) { Nota 'Hecho: alcance indexado (CrawlScopeManager) reimportado. Reinicia WSearch para que lo lea.' 'Green' }
        else { Nota ("AVISO: reg import termino con codigo {0}: el alcance NO se reimporto." -f $codS) 'Red' }
    }
}

# ---------- Reparar: reiniciar el servicio con cuidado ----------
if (($Reparar -or $RestaurarScope) -and -not $modoPrueba) {
    try {
        Stop-Service WSearch -ErrorAction SilentlyContinue
        $sc = New-Object ServiceProcess.ServiceController 'WSearch'
        $sc.WaitForStatus('Stopped', (New-Object TimeSpan(0, 0, 30)))
        Start-Service WSearch
        $sc.WaitForStatus('Running', (New-Object TimeSpan(0, 0, 30)))
        Nota 'Hecho: WSearch reiniciado (sin tocar SetupCompletedSuccessfully).' 'Green'
    } catch { Nota ("AVISO al reiniciar WSearch: {0}" -f $_.Exception.Message) 'Red' }
    # dejar el tipo de inicio como estaba
    if ($null -ne $inicioInicial -and (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\WSearch').Start -ne $inicioInicial) {
        Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\WSearch' Start $inicioInicial
        Nota ("Tipo de inicio de WSearch devuelto a Start={0}." -f $inicioInicial) 'Cyan'
    }
}

# ---------- Reconstruir solo si se pide (operacion pesada) ----------
if ($Reconstruir -and -not $modoPrueba) {
    Nota 'AVISO: reconstruir el indice es una operacion pesada (horas). Conserva el alcance.' 'Yellow'
    try {
        $mgr = [Activator]::CreateInstance([Type]::GetTypeFromCLSID([Guid]'7D096C5F-AC08-4F1F-BEB7-5C22C517CE39'))
        $cat = $mgr.GetCatalog('SystemIndex')
        $cat.Reindex()
        Nota 'Hecho: reconstruccion solicitada por COM (ISearchCatalogManager.Reindex).' 'Green'
    } catch { Nota ("No se pudo pedir la reconstruccion por COM: {0}. Usa Opciones de indizacion > Avanzado > Reconstruir." -f $_.Exception.Message) 'Red' }
}

# ---------- Comprobacion final ----------
Nota '== Despues ==' 'Cyan'
$svc2 = Get-Service WSearch -ErrorAction SilentlyContinue
Nota ("  WSearch: {0} / {1}" -f $svc2.Status, $svc2.StartType)
Nota ("  SetupCompletedSuccessfully = {0}" -f (Get-ItemProperty $raizReg -ErrorAction SilentlyContinue).SetupCompletedSuccessfully)
Nota ("  Reglas de alcance: SearchRoots={0}  WorkingSetRules={1}" -f (Contar-Subclaves 'SearchRoots'), (Contar-Subclaves 'WorkingSetRules'))
Nota ("RESULTADO: accion completada sin vaciar el indice. Copia en {0}" -f $CarpetaCopia) 'Green'
$informe | Set-Content (Join-Path $CarpetaCopia 'informe.txt')
