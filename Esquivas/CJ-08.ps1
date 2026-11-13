<#
.SYNOPSIS
    Esquiva el callejon de DisableUnusedSmb1.ps1: comprueba el estado REAL de SMB1 y, si se pide,
    lo retira de forma verificable, sin fiarse de la marca AuditSmb1Access e informando del reinicio
    pendiente SIN reiniciar.
.DESCRIPTION
    El script de Microsoft escribe AuditSmb1Access = 0 ("ya tratado") SIEMPRE, aunque la
    desinstalacion de SMB1 haya fallado (su try/catch se traga el error). Este esquivar NO usa esa
    marca como prueba: consulta el estado real de las caracteristicas con Get-WindowsOptionalFeature.

    Por defecto SOLO COMPRUEBA (no cambia nada): lee el estado de cada caracteristica SMB1 y avisa de
    si la marca AuditSmb1Access miente respecto al estado real.

    Con -Desinstalar (interruptor explicito, exige consola de administrador):
      1. Copia de seguridad: estado de las caracteristicas y export de las claves Parameters de
         LanmanServer y LanmanWorkstation en C:\Copias_SMB1\<fecha>\ (reg export solo lee).
      2. Deshabilita con Disable-WindowsOptionalFeature -NoRestart SOLO las caracteristicas SMB1 que
         siguen habilitadas (por defecto SMB1Protocol-Client, SMB1Protocol-Server y SMB1Protocol).
      3. Comprueba el resultado releyendo el estado. NO escribe AuditSmb1Access.
      4. Si queda reinicio pendiente, lo informa y NO reinicia.

    Nunca reinicia, nunca toca la red y nunca da por hecho lo que no ha comprobado.
.PARAMETER Desinstalar
    Retira de verdad las caracteristicas SMB1 que sigan habilitadas. Sin este interruptor solo comprueba.
.PARAMETER Caracteristicas
    Lista de caracteristicas SMB1 a retirar. Por defecto el cliente, el servidor y el protocolo.
    La caracteristica SMB1Protocol-Deprecation (la tarea de retirada automatica) NO se toca por defecto.
.PARAMETER CarpetaCopia
    Carpeta de la copia de seguridad.
.EXAMPLE
    .\2_esquivar.ps1
    Solo comprueba el estado real de SMB1 y si la marca AuditSmb1Access es fiable.
.EXAMPLE
    .\2_esquivar.ps1 -Desinstalar
    Retira SMB1 de forma verificable (como administrador) e informa del reinicio pendiente.
.NOTES
    Libro «Lo que Microsoft no explica» - callejon CJ-08: SMB1 consta como tratado aunque falle.
    Windows PowerShell 5.1 de 64 bits. La desinstalacion real de SMB1 exige reinicio: este script
    NO reinicia; lo deja indicado para que el administrador lo programe.
#>
[CmdletBinding()]
param(
    [switch]$Desinstalar,
    [string[]]$Caracteristicas = @('SMB1Protocol-Client', 'SMB1Protocol-Server', 'SMB1Protocol'),
    [string]$CarpetaCopia = ("$env:SystemDrive\Copias_SMB1\" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
)

$ErrorActionPreference = 'Stop'
$todas = @('SMB1Protocol', 'SMB1Protocol-Client', 'SMB1Protocol-Server', 'SMB1Protocol-Deprecation')
$claves = @{
    LanmanServer      = 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters'
    LanmanWorkstation = 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters'
}
$informe = New-Object System.Collections.ArrayList
function Nota($texto, $color = 'Gray') { [void]$informe.Add($texto); Write-Host $texto -ForegroundColor $color }

if (-not [Environment]::Is64BitProcess) { throw 'Usa Windows PowerShell de 64 bits ([Environment]::Is64BitProcess debe ser True).' }
$esAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($Desinstalar -and -not $esAdmin) { throw 'Para -Desinstalar abre PowerShell como administrador. No se ha cambiado nada.' }

function Estado-Caracteristica([string]$Nombre) {
    try {
        $f = Get-WindowsOptionalFeature -Online -FeatureName $Nombre -ErrorAction Stop
        return [pscustomobject]@{ nombre = $Nombre; estado = "$($f.State)"; existe = $true }
    } catch {
        return [pscustomobject]@{ nombre = $Nombre; estado = 'NO_DISPONIBLE'; existe = $false }
    }
}

function Leer-Marca([string]$Clave) {
    if (-not (Test-Path $Clave)) { return $null }
    return (Get-Item $Clave).GetValue('AuditSmb1Access', $null)
}

# ---------- Comprobacion (solo lectura) ----------
Nota '== Estado REAL de SMB1 (Get-WindowsOptionalFeature, solo lectura) ==' 'Cyan'
$estados = foreach ($c in $todas) { Estado-Caracteristica $c }
foreach ($e in $estados) { Nota ('  {0,-26} {1}' -f $e.nombre, $e.estado) }

Nota '== Marca AuditSmb1Access (la que el script de Microsoft escribe SIEMPRE) ==' 'Cyan'
$marcas = @{}
foreach ($s in $claves.Keys) {
    $v = Leer-Marca $claves[$s]
    $marcas[$s] = $v
    Nota ('  {0,-20} AuditSmb1Access = {1}' -f $s, $(if ($null -eq $v) { '(no existe)' } else { $v }))
}

# Habilitadas de verdad
$habilitadas = @($estados | Where-Object { $_.estado -eq 'Enabled' })
$noLeidas = @($estados | Where-Object { $_.estado -eq 'NO_DISPONIBLE' })
# ¿La marca miente? Marca puesta a 0 ("tratado") pero alguna caracteristica SMB1 sigue habilitada
$marcaDice0 = ($marcas.Values | Where-Object { $_ -eq 0 }).Count -gt 0
$marcaMiente = $marcaDice0 -and ($habilitadas.Count -gt 0)

if ($noLeidas.Count -gt 0 -and -not $esAdmin) {
    Nota 'No se pudo leer el estado real de SMB1 (Get-WindowsOptionalFeature suele exigir administrador). Abre PowerShell como administrador para comprobarlo.' 'Yellow'
} elseif ($noLeidas.Count -gt 0) {
    Nota ('No se pudo leer el estado de: {0}. No se puede afirmar que SMB1 este retirado.' -f (($noLeidas | ForEach-Object { $_.nombre }) -join ', ')) 'Yellow'
} elseif ($habilitadas.Count -eq 0) {
    Nota 'RESULTADO: no queda ninguna caracteristica SMB1 habilitada.' 'Green'
} else {
    Nota ('SMB1 SIGUE PRESENTE. Caracteristicas habilitadas: {0}' -f (($habilitadas | ForEach-Object { $_.nombre }) -join ', ')) 'Yellow'
}
if ($marcaMiente) {
    Nota 'AVISO: AuditSmb1Access = 0 marca "ya tratado", pero SMB1 sigue habilitado. La marca NO es fiable (este es el callejon de DisableUnusedSmb1.ps1).' 'Red'
}

if (-not $Desinstalar) {
    if ($habilitadas.Count -gt 0) { Nota 'Para retirarlo de verdad, ejecuta de nuevo con -Desinstalar en una consola de administrador.' 'Yellow' }
    return
}

# ---------- Desinstalar (verificable, sin reiniciar) ----------
$aRetirar = @($Caracteristicas | Where-Object { $nom = $_; @($estados | Where-Object { $_.nombre -eq $nom -and $_.estado -eq 'Enabled' }).Count -gt 0 })
if ($aRetirar.Count -eq 0) {
    Nota 'RESULTADO: nada que desinstalar; las caracteristicas pedidas ya no estan habilitadas.' 'Green'
    return
}

# 1. Copia de seguridad (solo lectura del sistema)
New-Item -ItemType Directory -Force $CarpetaCopia | Out-Null
$estados | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $CarpetaCopia 'estado_antes.json')
foreach ($s in $claves.Keys) {
    & reg.exe export ('HKLM\SYSTEM\CurrentControlSet\Services\{0}\Parameters' -f $s) (Join-Path $CarpetaCopia ($s + '_Parameters.reg')) /y 2>$null | Out-Null
}
Nota "Copia de seguridad en $CarpetaCopia" 'Cyan'

# 2. Deshabilitar solo lo que sigue habilitado, sin reiniciar
$reinicioPendiente = $false
foreach ($c in $aRetirar) {
    Nota ("Deshabilitando {0} (sin reiniciar)..." -f $c) 'Cyan'
    $r = Disable-WindowsOptionalFeature -Online -FeatureName $c -NoRestart -ErrorAction Stop
    if ($r.RestartNeeded) { $reinicioPendiente = $true }
}

# 3. Comprobacion del resultado (releer estado real)
$despues = foreach ($c in $todas) { Estado-Caracteristica $c }
$siguenHabilitadas = @($despues | Where-Object { $_.nombre -in $aRetirar -and $_.estado -eq 'Enabled' })

Nota '== Estado despues ==' 'Cyan'
foreach ($e in $despues) { Nota ('  {0,-26} {1}' -f $e.nombre, $e.estado) }

# Una caracteristica puede quedar Enabled con reinicio pendiente: es normal al deshabilitar sin reiniciar.
if ($siguenHabilitadas.Count -eq 0) {
    Nota 'RESULTADO: SMB1 retirado y comprobado (estado != Enabled en las caracteristicas pedidas).' 'Green'
} elseif ($reinicioPendiente) {
    Nota 'RESULTADO: desinstalacion aplicada; las caracteristicas quedan pendientes de un REINICIO para completarse.' 'Yellow'
} else {
    Nota 'RESULTADO: algo no se ha retirado y no consta reinicio pendiente. Revisa el estado a mano (NO se ha escrito ninguna marca de "tratado").' 'Red'
}
if ($reinicioPendiente) {
    Nota '>> HAY UN REINICIO PENDIENTE. Programa el reinicio del equipo para completar la retirada de SMB1. Este script NO reinicia.' 'Yellow'
}
Nota 'Nota: este esquivar NO escribe AuditSmb1Access; el estado fiable es el de Get-WindowsOptionalFeature.' 'Cyan'
$informe | Set-Content (Join-Path $CarpetaCopia 'informe.txt')
