<#
.SYNOPSIS
    Esquiva el callejon de RS_BITSRegKeys.ps1: comprueba BITS y, si se pide, arregla SOLO lo que este mal,
    sin quitar permisos a SYSTEM, sin sobrescribir la configuracion del servicio y con copia previa.
.DESCRIPTION
    Por defecto SOLO COMPRUEBA y no cambia nada.
    Con -Reparar:
      1. Copia de seguridad (registro de BITS, permisos de Parameters, descriptor del servicio, estado).
      2. Si SYSTEM no tiene control total sobre BITS\Parameters, se lo devuelve (AddAccessRule, sin quitar nada).
      3. Si ServiceDll falta o es incorrecto, lo escribe guardando antes los permisos exactos y
         reponiendolos tal cual al terminar (finally), pase lo que pase.
      4. Comprueba que BITS arranca y responde, y lo deja en el estado en que estaba.
    Nunca cambia el tipo de inicio de BITS ni su descriptor de seguridad del servicio.
.EXAMPLE
    .\2_esquivar.ps1              # solo comprobar
    .\2_esquivar.ps1 -Reparar     # comprobar y arreglar lo que este mal (como administrador)
.NOTES
    Libro «Lo que Microsoft no explica» - callejon: el arreglo de BITS deja a SYSTEM sin permisos.
    Windows PowerShell 5.1 de 64 bits.
#>
[CmdletBinding()]
param(
    [switch]$Reparar,
    [string]$CarpetaCopia = ("$env:SystemDrive\Copias_BITS\" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
)

$ErrorActionPreference = 'Stop'
$par = 'HKLM:\SYSTEM\CurrentControlSet\Services\BITS\Parameters'
$svc = 'HKLM:\SYSTEM\CurrentControlSet\Services\BITS'
$dllEsperada = '%SystemRoot%\System32\qmgr.dll'
$SYSTEM = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
$informe = New-Object System.Collections.ArrayList
function Nota($texto, $color = 'Gray') { [void]$informe.Add($texto); Write-Host $texto -ForegroundColor $color }

if (-not [Environment]::Is64BitProcess) { throw 'Usa Windows PowerShell de 64 bits ([Environment]::Is64BitProcess debe ser True).' }
$esAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($Reparar -and -not $esAdmin) { throw 'Para -Reparar abre PowerShell como administrador. No se ha cambiado nada.' }

# Cambiar permisos de BITS\Parameters: los administradores solo tienen LECTURA en esa clave, pero son sus
# propietarios, asi que pueden cambiar sus permisos si la abren pidiendo SOLO ese derecho (ChangePermissions).
# Set-Acl pide mas derechos al abrir la clave y Windows lo deniega («Acceso denegado al Registro»): no sirve aqui.
function Abrir-ParaPermisos {
    $d = [System.Security.AccessControl.RegistryRights]::ChangePermissions -bor [System.Security.AccessControl.RegistryRights]::ReadPermissions
    $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Services\BITS\Parameters', [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, $d)
    if (-not $k) { throw 'No se pudo abrir BITS\Parameters para cambiar permisos.' }
    return $k
}
function Poner-PermisosSddl([string]$Sddl) {
    $k = Abrir-ParaPermisos
    try { $s = $k.GetAccessControl('Access'); $s.SetSecurityDescriptorSddlForm($Sddl, 'Access'); $k.SetAccessControl($s) } finally { $k.Close() }
}
function Anadir-Regla($Regla) {
    $k = Abrir-ParaPermisos
    try { $s = $k.GetAccessControl('Access'); $s.AddAccessRule($Regla); $k.SetAccessControl($s) } finally { $k.Close() }
}

function SystemTieneControlTotal {
    $acl = Get-Acl -Path $par
    foreach ($r in $acl.Access) {
        $sid = try { $r.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]) } catch { $null }
        if ($sid -and $sid.Equals($SYSTEM) -and $r.AccessControlType -eq 'Allow' -and
            (($r.RegistryRights -band [System.Security.AccessControl.RegistryRights]::FullControl) -eq [System.Security.AccessControl.RegistryRights]::FullControl) -and
            $r.PropagationFlags -ne 'InheritOnly') { return $true }
    }
    return $false
}

function Comprobar {
    $r = [ordered]@{}
    $s = Get-Service BITS -ErrorAction SilentlyContinue
    $r.servicio_existe = [bool]$s
    if ($s) { $r.estado = "$($s.Status)"; $r.inicio = "$($s.StartType)" }
    $r.parameters_existe = Test-Path $par
    if ($r.parameters_existe) {
        $r.permisos_parameters = (Get-Acl -Path $par).GetSecurityDescriptorSddlForm('Access')
        $r.system_control_total = SystemTieneControlTotal
        $dll = (Get-Item $par).GetValue('ServiceDll', $null, 'DoNotExpandEnvironmentNames')
        $r.servicedll = $dll
        $r.servicedll_ok = ($dll -eq $dllEsperada) -and (Test-Path ([Environment]::ExpandEnvironmentVariables($dllEsperada)))
    } else { $r.system_control_total = $false; $r.servicedll_ok = $false }
    $k = Get-Item $svc
    $r.imagepath_ok = ("$($k.GetValue('ImagePath', $null, 'DoNotExpandEnvironmentNames'))" -match 'svchost\.exe -k netsvcs')
    $r.cuenta_ok = ($k.GetValue('ObjectName') -eq 'LocalSystem')
    return $r
}

Nota '== Comprobacion de BITS (solo lectura) ==' 'Cyan'
$antes = Comprobar
foreach ($k in $antes.Keys) { Nota ('  {0,-22} {1}' -f $k, $antes[$k]) }
$problemas = @()
if (-not $antes.servicio_existe) { $problemas += 'el servicio BITS no existe' }
if (-not $antes.system_control_total) { $problemas += 'SYSTEM no tiene control total sobre BITS\Parameters (el callejon de RS_BITSRegKeys)' }
if (-not $antes.servicedll_ok) { $problemas += 'ServiceDll falta o no es %SystemRoot%\System32\qmgr.dll' }
if (-not $antes.imagepath_ok) { $problemas += 'ImagePath no apunta a svchost.exe -k netsvcs (no se toca: revisalo a mano)' }
if (-not $antes.cuenta_ok) { $problemas += 'la cuenta del servicio no es LocalSystem (no se toca: revisalo a mano)' }
if ($problemas.Count -eq 0) { Nota 'RESULTADO: BITS esta bien. No hace falta cambiar nada.' 'Green' }
else { Nota 'PROBLEMAS ENCONTRADOS:' 'Yellow'; $problemas | ForEach-Object { Nota "  - $_" 'Yellow' } }

if (-not $Reparar) {
    if ($problemas.Count -gt 0) { Nota 'Para arreglarlo, ejecuta de nuevo con -Reparar en una consola de administrador.' 'Yellow' }
    return
}
if ($problemas.Count -eq 0) { return }

# ---------- 1. Copia de seguridad ----------
New-Item -ItemType Directory -Force $CarpetaCopia | Out-Null
& reg.exe export 'HKLM\SYSTEM\CurrentControlSet\Services\BITS' (Join-Path $CarpetaCopia 'BITS.reg') /y | Out-Null
if ($antes.parameters_existe) { Set-Content (Join-Path $CarpetaCopia 'permisos_Parameters.sddl') (Get-Acl -Path $par).GetSecurityDescriptorSddlForm('Access') }
(& sc.exe sdshow bits) -join '' | Set-Content (Join-Path $CarpetaCopia 'descriptor_servicio.txt')
$estadoInicial = (Get-Service BITS).Status
$inicioInicial = (Get-ItemProperty $svc).Start                     # 2 = automatico, 3 = manual
$retrasoInicial = (Get-ItemProperty $svc).DelayedAutostart
Nota "Copia de seguridad en $CarpetaCopia" 'Cyan'

# ---------- 2. Devolver a SYSTEM su control total (sin quitar nada a nadie) ----------
if ($antes.parameters_existe -and -not $antes.system_control_total) {
    Anadir-Regla (New-Object System.Security.AccessControl.RegistryAccessRule($SYSTEM, 'FullControl', 'ContainerInherit', 'None', 'Allow'))
    Nota 'Hecho: SYSTEM vuelve a tener control total sobre BITS\Parameters.' 'Green'
}

# ---------- 3. ServiceDll, sin perder los permisos ----------
if (-not $antes.servicedll_ok) {
    if (-not (Test-Path $par)) { New-Item -Path $par -Force | Out-Null }
    $original = (Get-Acl -Path $par).GetSecurityDescriptorSddlForm('Access')
    $adm = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
    try {
        Anadir-Regla (New-Object System.Security.AccessControl.RegistryAccessRule($adm, 'FullControl', 'Allow'))   # permiso temporal (PowerShell abre la clave pidiendo escritura completa); el finally lo quita
        New-ItemProperty -Path $par -Name ServiceDll -PropertyType ExpandString -Value $dllEsperada -Force | Out-Null
        Nota 'Hecho: ServiceDll = %SystemRoot%\System32\qmgr.dll' 'Green'
    } finally {
        Poner-PermisosSddl $original       # permisos EXACTOS de antes, pase lo que pase
    }
}

# ---------- 4. Comprobacion final ----------
$despues = Comprobar
$arranca = $false
try {
    if ((Get-Service BITS).Status -ne 'Running') { Start-Service BITS; Start-Sleep 2 }
    $arranca = ((Get-Service BITS).Status -eq 'Running')
    $null = Get-BitsTransfer -AllUsers -ErrorAction Stop
    $responde = $true
} catch { $responde = $false; Nota ('BITS no responde: ' + $_.Exception.Message) 'Red' }
finally {
    if ($estadoInicial -eq 'Stopped') { Stop-Service BITS -Force -ErrorAction SilentlyContinue }
    # Al arrancar BITS, Windows puede cambiar su tipo de inicio por su cuenta (medido en el laboratorio):
    # se deja exactamente como estaba.
    if ((Get-ItemProperty $svc).Start -ne $inicioInicial) {
        & sc.exe config bits start= $(if ($inicioInicial -eq 2) { 'delayed-auto' } elseif ($inicioInicial -eq 4) { 'disabled' } else { 'demand' }) | Out-Null
        if ($null -ne $retrasoInicial) { Set-ItemProperty $svc -Name DelayedAutostart -Value $retrasoInicial -ErrorAction SilentlyContinue }
        Nota ('Tipo de inicio devuelto a su valor original (Start={0}).' -f $inicioInicial) 'Cyan'
    }
}

Nota '== Despues ==' 'Cyan'
Nota ('  SYSTEM con control total: {0} | ServiceDll correcto: {1} | BITS arranca: {2} | responde: {3}' -f $despues.system_control_total, $despues.servicedll_ok, $arranca, $responde)
Nota ('  Estado final de BITS: {0} (estaba {1}); tipo de inicio: {2} (estaba Start={3}, ahora Start={4})' -f (Get-Service BITS).Status, $estadoInicial, (Get-Service BITS).StartType, $inicioInicial, (Get-ItemProperty $svc).Start)
if ($despues.system_control_total -and $despues.servicedll_ok -and $arranca -and $responde) { Nota 'RESULTADO: BITS arreglado y comprobado.' 'Green' }
else { Nota "RESULTADO: queda algo por revisar. Para volver atras: reg import `"$CarpetaCopia\BITS.reg`" y los permisos de $CarpetaCopia\permisos_Parameters.sddl" 'Red' }
$informe | Set-Content (Join-Path $CarpetaCopia 'informe.txt')
