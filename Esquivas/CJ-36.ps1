<#
.SYNOPSIS
    Esquiva el callejon de RC_BITSACL.ps1 / RS_BITSACL.ps1 (solucionador de BITS): compara el
    descriptor de seguridad del servicio BITS con el de fabrica entrada por entrada y, si se pide,
    repone SOLO las entradas de fabrica que falten, conservando las que haya anadido el administrador.
.DESCRIPTION
    Por defecto SOLO COMPRUEBA y no cambia nada:
      - Lee el descriptor con 'sc.exe sdshow bits' (sin privilegios solo se ve la DACL; como
        administrador tambien la SACL).
      - Para cada entrada de fabrica dice si esta (con al menos esos derechos) o falta.
      - Lista las entradas anadidas (delegaciones) y avisa de las de denegacion.
    Con -Reparar (solo si falta alguna entrada de fabrica):
      1. Copia de seguridad: el SDDL completo (sddl_antes.txt) y reg export de BITS\Security.
      2. Nuevo descriptor = el actual + las entradas de fabrica que falten (o los derechos que les
         falten). Las entradas anadidas, la SACL, el propietario y el grupo se conservan tal cual.
      3. Lo aplica con 'sc.exe sdset bits' SIN parar BITS ni cambiar su tipo de inicio.
      4. Comprueba que estan todas las de fabrica y todas las que habia.
    RS_BITSACL.ps1, en cambio, para BITS y escribe un descriptor fijo de 2015 (lineas 19-23): cualquier
    entrada anadida desaparece (prueba P-BI-04b). Y RC_BITSACL.ps1 (lineas 15-18) lo propone en cuanto
    el texto del descriptor no contiene el de fabrica, aunque solo haya una entrada de mas.
.EXAMPLE
    .\2_esquivar.ps1              # solo comprobar
.EXAMPLE
    .\2_esquivar.ps1 -Reparar     # reponer solo lo que falte (como administrador)
.NOTES
    Libro «Lo que Microsoft no explica» - callejon CJ-36. Windows PowerShell 5.1 de 64 bits.
    Descriptor de fabrica: el de RC_BITSACL.ps1 linea 16, que coincide con el de Windows 11 limpio
    (prueba P-BI-10). Para volver atras: sc.exe sdset bits "<contenido de sddl_antes.txt>".
#>
[CmdletBinding()]
param(
    [switch]$Reparar,
    [string]$CarpetaCopia = ("$env:SystemDrive\Copias_BITS\" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
)

$ErrorActionPreference = 'Stop'
$informe = New-Object System.Collections.ArrayList
function Nota([string]$Texto, [string]$Color = 'Gray') { [void]$informe.Add($Texto); Write-Host $Texto -ForegroundColor $Color }

if (-not [Environment]::Is64BitProcess) { throw 'Usa Windows PowerShell de 64 bits ([Environment]::Is64BitProcess debe ser True).' }
$esAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($Reparar -and -not $esAdmin) { throw 'Para -Reparar abre PowerShell como administrador. No se ha cambiado nada.' }

$fabrica = 'D:(A;CI;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;IU)(A;;CCLCSWLOCRRC;;;SU)S:(AU;SAFA;WDWO;;;BA)'
$rawFab = New-Object System.Security.AccessControl.RawSecurityDescriptor($fabrica)

function Leer-Descriptor {
    $t = ((@(& sc.exe sdshow bits) | ForEach-Object { "$_".Trim() }) -join '').Trim()
    if ($LASTEXITCODE -ne 0 -or $t -notmatch '^(O:|G:|D:)') { throw "sc.exe sdshow bits no devolvio un descriptor: $t" }
    return $t
}
function Nombre-Sid($sid) { try { return $sid.Translate([System.Security.Principal.NTAccount]).Value } catch { return $sid.Value } }
function Texto-Ace($a) {
    $sd = New-Object System.Security.AccessControl.RawSecurityDescriptor('D:')
    $acl = New-Object System.Security.AccessControl.RawAcl(2, 1); $acl.InsertAce(0, $a)
    $sd.DiscretionaryAcl = $acl
    return ($sd.GetSddlForm('Access') -replace '^D:', '')
}
# Una entrada de fabrica "esta" si hay una de permitir para el mismo SID con al menos sus derechos y marcas
# (comparaciones con [int] y .Equals: '-eq' entre SecurityIdentifier da 'conversion no valida' en PowerShell 5.1)
function Mismo($a, $b) { return ([int]$a.AceQualifier -eq [int]$b.AceQualifier) -and $a.SecurityIdentifier.Equals($b.SecurityIdentifier) }
function Cubre($actual, $f) {
    return (Mismo $actual $f) -and (($actual.AccessMask -band $f.AccessMask) -eq $f.AccessMask) -and (([int]$actual.AceFlags -band [int]$f.AceFlags) -eq [int]$f.AceFlags)
}
function Igual($a, $b) {
    return (Mismo $a $b) -and ($a.AccessMask -eq $b.AccessMask) -and ([int]$a.AceFlags -eq [int]$b.AceFlags)
}
function Analizar([string]$Sddl) {
    $raw = New-Object System.Security.AccessControl.RawSecurityDescriptor($Sddl)
    $aces = @(); if ($raw.DiscretionaryAcl) { $aces = @($raw.DiscretionaryAcl) }
    $faltan = @(); foreach ($f in @($rawFab.DiscretionaryAcl)) { if (-not @($aces | Where-Object { Cubre $_ $f }).Count) { $faltan += $f } }
    $extra = @(); foreach ($a in $aces) { if (-not @(@($rawFab.DiscretionaryAcl) | Where-Object { Igual $a $_ }).Count) { $extra += $a } }
    [pscustomobject]@{ Raw = $raw; Aces = $aces; Faltan = $faltan; Extra = $extra; Sacl = ($Sddl -match 'S:') }
}

# ---------- 1. Comprobacion (solo lectura) ----------
Nota '== Descriptor de seguridad del servicio BITS (solo lectura) ==' 'Cyan'
$antes = Leer-Descriptor
Nota "  Actual:    $antes"
Nota "  Fabrica:   $fabrica"
$an = Analizar $antes
foreach ($f in @($rawFab.DiscretionaryAcl)) {
    $esta = -not (@($an.Faltan | Where-Object { Igual $_ $f }).Count)
    Nota ('  {0,-6} fabrica {1}  ({2})' -f $(if ($esta) { 'OK' } else { 'FALTA' }), (Texto-Ace $f), (Nombre-Sid $f.SecurityIdentifier)) $(if ($esta) { 'Gray' } else { 'Yellow' })
}
foreach ($a in $an.Extra) {
    $deny = ([int]$a.AceQualifier -eq [int][System.Security.AccessControl.AceQualifier]::AccessDenied)
    Nota ('  {0,-6} anadida {1}  ({2}){3}' -f $(if ($deny) { 'AVISO' } else { 'SE QUEDA' }), (Texto-Ace $a), (Nombre-Sid $a.SecurityIdentifier), $(if ($deny) { ' - es de DENEGAR: revisala a mano, no se toca' } else { ' - se conserva' })) $(if ($deny) { 'Yellow' } else { 'Gray' })
}
if (-not $an.Sacl) { Nota $(if ($esAdmin) { '  AVISO: el descriptor no tiene SACL (auditoria). No se cambia.' } else { '  (Sin administrador no se ve la SACL; se compara solo la DACL.)' }) }
if ($an.Faltan.Count -eq 0) {
    if ($an.Extra.Count -gt 0) { Nota '  RC_BITSACL.ps1 declararia aqui un problema solo porque hay entradas de mas; no lo hay.' 'Gray' }
    Nota 'RESULTADO: el descriptor de BITS tiene todas las entradas de fabrica. No hace falta cambiar nada.' 'Green'
    return
}
Nota ('PROBLEMA: faltan {0} entradas de fabrica (o parte de sus derechos).' -f $an.Faltan.Count) 'Yellow'
if (-not $Reparar) { Nota 'Para reponerlas conservando las anadidas: -Reparar en una consola de administrador.' 'Yellow'; return }

# ---------- 2. Copia de seguridad ----------
New-Item -ItemType Directory -Force -Path $CarpetaCopia | Out-Null
Set-Content -Path (Join-Path $CarpetaCopia 'sddl_antes.txt') -Value $antes -Encoding ASCII
& reg.exe export 'HKLM\SYSTEM\CurrentControlSet\Services\BITS\Security' (Join-Path $CarpetaCopia 'BITS_Security.reg') /y 2>$null | Out-Null
Nota "Copia de seguridad en $CarpetaCopia (sddl_antes.txt, BITS_Security.reg)" 'Cyan'

# ---------- 3. Nuevo descriptor: el actual + lo que falte ----------
$raw = $an.Raw
$acl = New-Object System.Security.AccessControl.RawAcl(2, ($an.Aces.Count + $an.Faltan.Count))
$i = 0; foreach ($a in $an.Aces) { $acl.InsertAce($i, $a.Copy()); $i++ }   # copias: el analisis de antes no se altera
foreach ($f in $an.Faltan) {
    $hueco = $null
    for ($j = 0; $j -lt $acl.Count; $j++) {
        $x = $acl[$j]
        if ((Mismo $x $f) -and ([int]$x.AceFlags -eq [int]$f.AceFlags)) { $hueco = $j; break }
    }
    if ($null -ne $hueco) { $acl[$hueco].AccessMask = ($acl[$hueco].AccessMask -bor $f.AccessMask) }   # anadir los derechos que falten
    else { $acl.InsertAce($acl.Count, (New-Object System.Security.AccessControl.CommonAce($f.AceFlags, $f.AceQualifier, $f.AccessMask, $f.SecurityIdentifier, $false, $null))) }
}
$raw.DiscretionaryAcl = $acl
$nuevo = $raw.GetSddlForm([System.Security.AccessControl.AccessControlSections]::All)
Nota "  Nuevo:     $nuevo"
$sal = @(& sc.exe sdset bits $nuevo)
if ($LASTEXITCODE -ne 0) { Nota ('RESULTADO: sc.exe sdset fallo ({0}). No se ha cambiado nada.' -f ($sal -join ' ')) 'Red'; return }

# ---------- 4. Comprobacion final ----------
$despues = Leer-Descriptor
$dn = Analizar $despues
$perdidas = @(); foreach ($a in $an.Aces) { if (-not @($dn.Aces | Where-Object { Cubre $_ $a }).Count) { $perdidas += (Texto-Ace $a) } }
Nota "  Despues:   $despues"
if ($dn.Faltan.Count -eq 0 -and $perdidas.Count -eq 0 -and ($dn.Sacl -eq $an.Sacl)) {
    Nota ('RESULTADO: entradas de fabrica repuestas ({0}) y conservadas las {1} anadidas. BITS no se ha parado. Para volver atras: sc.exe sdset bits "<sddl_antes.txt>"' -f $an.Faltan.Count, $an.Extra.Count) 'Green'
} else {
    Nota ('RESULTADO: queda algo por revisar (faltan {0}; perdidas: {1}). Descriptor anterior en {2}\sddl_antes.txt' -f $dn.Faltan.Count, ($perdidas -join ' '), $CarpetaCopia) 'Red'
}
$informe | Set-Content -Path (Join-Path $CarpetaCopia 'informe.txt') -Encoding UTF8
