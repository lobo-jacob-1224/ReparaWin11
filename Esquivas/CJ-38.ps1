<#
.SYNOPSIS
    Esquiva el callejon de RS_AppData.ps1 (solucionador de Windows Update): comprueba el valor AppData
    de HKU\.DEFAULT (User Shell Folders) y, si se pide, lo deja como debe estar: el texto
    %USERPROFILE%\AppData\Roaming con el tipo REG_EXPAND_SZ, que es el que permite expandir la variable.
.DESCRIPTION
    Por defecto SOLO COMPRUEBA y no cambia nada: si el valor existe, su texto sin expandir, su tipo y
    a que carpeta apunta una vez expandido.
    Casos:
      - Texto correcto y REG_EXPAND_SZ: bien, no se toca.
      - Texto con variables (%...%) pero REG_SZ: la ruta no se expande (es lo que deja RS_AppData.ps1
        cuando el valor era REG_SZ, prueba P-WU-09c). -Reparar lo reescribe como REG_EXPAND_SZ.
      - No existe: -Reparar lo crea con el valor de fabrica.
      - Texto distinto que apunta a una carpeta que NO existe: roto. -Reparar pone el de fabrica.
      - Texto distinto que apunta a una carpeta que SI existe: puede ser una redireccion hecha a
        proposito. No se toca salvo que se de -PonerValorDeFabrica.
    Antes de cambiar nada: reg export de la clave en la carpeta de copia. Al final comprueba texto y tipo.
    HKU\.DEFAULT es el perfil de la cuenta SYSTEM (conocimiento externo), por eso %USERPROFILE% se
    resuelve aqui con la carpeta de perfil de S-1-5-18 (ProfileList).
.EXAMPLE
    .\2_esquivar.ps1                                   # solo comprobar
.EXAMPLE
    .\2_esquivar.ps1 -Reparar                          # corregir tipo o valor roto (como administrador)
.EXAMPLE
    .\2_esquivar.ps1 -Reparar -PonerValorDeFabrica     # tambien si apunta a otra carpeta que existe
.NOTES
    Libro «Lo que Microsoft no explica» - callejon CJ-38. Windows PowerShell 5.1 de 64 bits.
    Para volver atras: reg import "<carpeta de copia>\User_Shell_Folders_DEFAULT.reg".
#>
[CmdletBinding()]
param(
    [switch]$Reparar,
    [switch]$PonerValorDeFabrica,
    [string]$CarpetaCopia = ("$env:SystemDrive\Copias_WindowsUpdate\" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
)

$ErrorActionPreference = 'Stop'
$informe = New-Object System.Collections.ArrayList
function Nota([string]$Texto, [string]$Color = 'Gray') { [void]$informe.Add($Texto); Write-Host $Texto -ForegroundColor $Color }

if (-not [Environment]::Is64BitProcess) { throw 'Usa Windows PowerShell de 64 bits ([Environment]::Is64BitProcess debe ser True).' }
$esAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($Reparar -and -not $esAdmin) { throw 'Para -Reparar abre PowerShell como administrador. No se ha cambiado nada.' }

$sub = '.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
$fabrica = '%USERPROFILE%\AppData\Roaming'          # Get-AppDataExpectedString (CL_Utility.ps1, lineas 39-48) en Windows 10/11

function Leer {
    $k = [Microsoft.Win32.Registry]::Users.OpenSubKey($sub, $false)
    if (-not $k) { return [pscustomobject]@{ Clave = $false; Existe = $false; Texto = $null; Tipo = '' } }
    try {
        if (@($k.GetValueNames()) -notcontains 'AppData') { return [pscustomobject]@{ Clave = $true; Existe = $false; Texto = $null; Tipo = '' } }
        return [pscustomobject]@{ Clave = $true; Existe = $true; Texto = [string]$k.GetValue('AppData', $null, 'DoNotExpandEnvironmentNames'); Tipo = $k.GetValueKind('AppData').ToString() }
    } finally { $k.Close() }
}
# %USERPROFILE% de SYSTEM: ProfileList\S-1-5-18\ProfileImagePath (normalmente C:\Windows\system32\config\systemprofile)
function Perfil-System {
    try { $p = (Get-Item 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\S-1-5-18').GetValue('ProfileImagePath') } catch { $p = $null }
    if (-not $p) { $p = Join-Path $env:windir 'system32\config\systemprofile' }
    return [Environment]::ExpandEnvironmentVariables($p)
}
# $true / $false, o $null si no se puede saber (el perfil de SYSTEM no es legible sin administrador)
function Existe([string]$Ruta) {
    if (-not $Ruta) { return $false }
    try { return [bool](Test-Path -LiteralPath $Ruta -ErrorAction Stop) } catch { return $null }
}
function Texto-Existe($v) { if ($v -eq $true) { 'si' } elseif ($v -eq $false) { 'no' } else { 'no se puede saber sin administrador' } }
function Expandir([string]$Texto) {
    if ($null -eq $Texto) { return $null }
    $t = $Texto -ireplace [regex]::Escape('%USERPROFILE%'), (Perfil-System).Replace('$', '$$')
    return [Environment]::ExpandEnvironmentVariables($t)
}

# ---------- 1. Comprobacion (solo lectura) ----------
Nota '== AppData de HKU\.DEFAULT (User Shell Folders) (solo lectura) ==' 'Cyan'
$antes = Leer
if (-not $antes.Clave) { Nota 'RESULTADO: no existe la clave User Shell Folders de HKU\.DEFAULT. No se toca: revisala a mano.' 'Red'; return }
$accion = ''      # '' = nada ; 'tipo' = mismo texto como REG_EXPAND_SZ ; 'fabrica' = valor de fabrica
if (-not $antes.Existe) {
    Nota '  AppData: NO EXISTE.' 'Yellow'; $accion = 'fabrica'
} else {
    $exp = Expandir $antes.Texto
    $apunta = if ($antes.Tipo -eq 'ExpandString') { $exp } else { $antes.Texto }   # REG_SZ no se expande
    Nota ('  Texto: {0}' -f $antes.Texto)
    Nota ('  Tipo:  {0}{1}' -f $antes.Tipo, $(if ($antes.Tipo -eq 'ExpandString') { ' (REG_EXPAND_SZ)' } elseif ($antes.Tipo -eq 'String') { ' (REG_SZ: las variables NO se expanden)' } else { '' }))
    $hay = Existe $apunta
    Nota ('  Apunta a: {0}  (existe: {1})' -f $apunta, (Texto-Existe $hay))
    $tieneVar = $antes.Texto -match '%[^%]+%'
    if ($antes.Texto -ieq $fabrica -and $antes.Tipo -eq 'ExpandString') { $accion = '' }
    elseif ($tieneVar -and $antes.Tipo -ne 'ExpandString') {
        Nota '  PROBLEMA: el texto lleva variables pero el tipo no es REG_EXPAND_SZ: la ruta queda literal, sin expandir.' 'Yellow'
        $accion = $(if ($antes.Texto -ieq $fabrica -or ((Existe $exp) -ne $false)) { 'tipo' } else { 'fabrica' })   # si la ruta expandida existe (o no se sabe) se conserva el texto
    } elseif ($antes.Texto -ieq $fabrica) {
        Nota ('  PROBLEMA: valor de fabrica con un tipo inesperado ({0}).' -f $antes.Tipo) 'Yellow'; $accion = 'tipo'
    } elseif ($hay -ne $false) {
        if ($null -eq $hay -and -not $PonerValorDeFabrica) { Nota '  Distinto del de fabrica; sin administrador no se puede comprobar si la carpeta existe. No se toca.' 'Yellow' }
        elseif ($PonerValorDeFabrica) { Nota '  Distinto del de fabrica y apunta a una carpeta que existe; se pondra el de fabrica porque lo pide -PonerValorDeFabrica.' 'Yellow'; $accion = 'fabrica' }
        else { Nota '  Distinto del de fabrica pero apunta a una carpeta que existe: puede ser una redireccion hecha a proposito. No se toca (usa -PonerValorDeFabrica si quieres el de fabrica).' 'Yellow' }
    } else {
        Nota '  PROBLEMA: distinto del de fabrica y apunta a una carpeta que no existe.' 'Yellow'; $accion = 'fabrica'
    }
}
if ($accion -eq '') { Nota 'RESULTADO: no hay nada que cambiar en AppData de HKU\.DEFAULT.' 'Green'; return }
$nuevoTexto = if ($accion -eq 'tipo') { $antes.Texto } else { $fabrica }
Nota ('Con -Reparar quedaria: {0} como REG_EXPAND_SZ.' -f $nuevoTexto) 'Yellow'
if (-not $Reparar) { return }

# ---------- 2. Copia y cambio ----------
New-Item -ItemType Directory -Force -Path $CarpetaCopia | Out-Null
$reg = Join-Path $CarpetaCopia 'User_Shell_Folders_DEFAULT.reg'
& reg.exe export ('HKU\' + $sub) $reg /y 2>$null | Out-Null
if (-not (Test-Path -LiteralPath $reg)) { Nota 'RESULTADO: no se pudo hacer la copia de seguridad (reg export). No se ha cambiado nada.' 'Red'; return }
Nota "Copia de seguridad en $reg" 'Cyan'
$k = [Microsoft.Win32.Registry]::Users.OpenSubKey($sub, $true)
try { $k.SetValue('AppData', $nuevoTexto, [Microsoft.Win32.RegistryValueKind]::ExpandString) } finally { $k.Close() }   # tipo explicito: no se hereda el que hubiera

# ---------- 3. Comprobacion final ----------
$fin = Leer
Nota ('== Despues == Texto: {0} | Tipo: {1} | Apunta a: {2}' -f $fin.Texto, $fin.Tipo, (Expandir $fin.Texto)) 'Cyan'
if ($fin.Existe -and $fin.Texto -eq $nuevoTexto -and $fin.Tipo -eq 'ExpandString') { Nota ('RESULTADO: AppData de HKU\.DEFAULT corregido ({0}, REG_EXPAND_SZ). Para volver atras: reg import "{1}"' -f $nuevoTexto, $reg) 'Green' }
else { Nota "RESULTADO: queda algo por revisar. Copia en $reg" 'Red' }
$informe | Set-Content -Path (Join-Path $CarpetaCopia 'informe.txt') -Encoding UTF8
