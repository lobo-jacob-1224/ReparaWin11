# Nucleo.ps1 - funciones comunes de ReparaWin11 (Windows PowerShell 5.1, 64 bits, administrador).
# Se carga en el proceso de trabajo (runspace) y en la ventana. No cambia nada por si solo.

$Global:RWRaiz = Split-Path -Parent $MyInvocation.MyCommand.Path
$Global:RWModulos = New-Object System.Collections.ArrayList

function Registrar-Modulo([hashtable]$M) {
    foreach ($k in 'Id', 'Nombre', 'Grupo', 'Diagnosticar') { if (-not $M.ContainsKey($k)) { throw "Modulo sin $k" } }
    foreach ($k in 'Lento', 'Avanzado', 'Reinicio', 'VerificaAlReparar') { if (-not $M.ContainsKey($k)) { $M[$k] = $false } }
    if (-not $M.ContainsKey('Orden')) { $M.Orden = 500 }
    if (-not $M.ContainsKey('Descripcion')) { $M.Descripcion = '' }
    [void]$Global:RWModulos.Add($M)
}

function Cargar-Modulos {
    $Global:RWModulos.Clear()
    foreach ($f in (Get-ChildItem (Join-Path $Global:RWRaiz 'Modulos') -Filter '*.ps1' | Sort-Object Name)) { . $f.FullName }
    return @($Global:RWModulos | Sort-Object { $_.Orden })
}

# ---------- registro de lo que pasa ----------
# $Global:RWSync lo crea la ventana (cola compartida); si no existe (uso por consola) se escribe en pantalla.
function Log([string]$Texto, [string]$Nivel = 'info') {
    $linea = '{0}|{1}|{2}' -f (Get-Date -Format 'HH:mm:ss'), $Nivel, $Texto
    if ($Global:RWSync) { $Global:RWSync.Cola.Enqueue($linea) } else { Write-Host $linea }
    if ($Global:RWLogArchivo) { Add-Content -LiteralPath $Global:RWLogArchivo -Value $linea -Encoding UTF8 }
}

function Resultado([ValidateSet('Verde', 'Amarillo', 'Rojo', 'Gris')][string]$Estado, [string]$Resumen, $Detalle = @()) {
    [pscustomobject]@{ Estado = $Estado; Resumen = $Resumen; Detalle = @($Detalle | ForEach-Object { "$_" }) }
}

function Es-Admin { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }

# ---------- carpeta de copias de esta sesion ----------
function Carpeta-Copia([string]$Modulo) {
    if (-not $Global:RWCopias) { $Global:RWCopias = Join-Path $env:SystemDrive ('Copias_ReparaWin11\' + (Get-Date -Format 'yyyyMMdd-HHmmss')) }
    $d = Join-Path $Global:RWCopias $Modulo
    New-Item -ItemType Directory -Force $d | Out-Null
    return $d
}

# ---------- programas externos con limite de tiempo ----------
# Devuelve Codigo, Salida (lineas), Agotado. Decodifica la salida UTF-16 (sfc, winmgmt) o la de la consola OEM.
function Ejecutar-Nativo([string]$Exe, [string]$Argumentos = '', [int]$Segundos = 600) {
    $o = [IO.Path]::GetTempFileName(); $e = [IO.Path]::GetTempFileName()
    try {
        $p = Start-Process -FilePath $Exe -ArgumentList $Argumentos -RedirectStandardOutput $o -RedirectStandardError $e -WindowStyle Hidden -PassThru
        $null = $p.Handle   # sin esto, en Windows PowerShell 5.1 ExitCode llega vacio con -PassThru
        $agotado = -not $p.WaitForExit($Segundos * 1000)
        if ($agotado) { try { $p.Kill() } catch { } }
        $lineas = @()
        foreach ($f in $o, $e) {
            $b = [IO.File]::ReadAllBytes($f); if ($b.Length -eq 0) { continue }
            $ceros = 0; for ($i = 1; $i -lt [Math]::Min($b.Length, 400); $i += 2) { if ($b[$i] -eq 0) { $ceros++ } }
            $txt = if ($ceros -gt 20) { [Text.Encoding]::Unicode.GetString($b) } else { [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage).GetString($b) }
            $lineas += @($txt -split "`r?`n" | ForEach-Object { ($_ -replace "`0", '').TrimEnd() } | Where-Object { $_ -ne '' })
        }
        $codigo = if ($agotado) { -1 } else { $p.ExitCode }
        return [pscustomobject]@{ Codigo = $codigo; Salida = $lineas; Agotado = $agotado }
    } finally { Remove-Item $o, $e -Force -ErrorAction SilentlyContinue }
}

# ---------- scripts de esquiva ya probados en el laboratorio (carpeta Esquivas) ----------
# Ejecuta el script, pasa cada linea al registro y devuelve las lineas y la linea RESULTADO.
function Ejecutar-Esquiva([string]$Nombre, [hashtable]$Parametros = @{}, [switch]$Silencioso) {
    $ruta = Join-Path $Global:RWRaiz "Esquivas\$Nombre.ps1"
    if (-not (Test-Path -LiteralPath $ruta)) { throw "Falta el script $Nombre en la carpeta Esquivas" }
    $lineas = New-Object System.Collections.ArrayList
    try {
        & $ruta @Parametros 6>&1 2>&1 | ForEach-Object { $t = "$_"; [void]$lineas.Add($t); if (-not $Silencioso) { Log ("    " + $t) 'detalle' } }
    } catch { $t = 'ERROR: ' + $_.Exception.Message; [void]$lineas.Add($t); Log ("    " + $t) 'error' }
    $res = @($lineas | Where-Object { $_ -match 'RESULTADO:' } | Select-Object -Last 1)
    return [pscustomobject]@{ Lineas = @($lineas); Resultado = $(if ($res) { $res[0].Trim() } else { '' }) }
}

# Convierte la comprobacion de un esquiva en un Resultado segun patrones de su linea RESULTADO.
function Resultado-Esquiva($Salida, [string]$PatronBien, [string]$Nombre) {
    $r = $Salida.Resultado
    $det = @($Salida.Lineas | Where-Object { $_ -notmatch '^\s*$' } | Select-Object -Last 25)
    if (-not $r) {
        # algunos esquivas, cuando encuentran algo que cambiar, terminan con la lista de CAMBIOS NECESARIOS en vez de RESULTADO
        $cambios = @($Salida.Lineas | Where-Object { $_ -match '^\s+-\s' } | ForEach-Object { $_.Trim().TrimStart('-').Trim() })
        if (@($Salida.Lineas | Where-Object { $_ -match 'CAMBIOS NECESARIOS|con -Reparar' }).Count) { return (Resultado 'Amarillo' ("$Nombre`: hay que corregir: " + ($cambios -join '; ')) $det) }
        return (Resultado 'Amarillo' "$Nombre`: no se pudo comprobar (sin resultado)." $det)
    }
    if ($r -match 'ERROR') { return (Resultado 'Rojo' $r $det) }
    if ($r -match $PatronBien) { return (Resultado 'Verde' ($r -replace '^RESULTADO:\s*', '') $det) }
    return (Resultado 'Amarillo' ($r -replace '^RESULTADO:\s*', '') $det)
}

# ---------- copia de una clave del registro ----------
function Copiar-Registro([string]$Clave, [string]$Carpeta, [string]$Nombre) {
    $f = Join-Path $Carpeta ($Nombre + '.reg')
    $r = Ejecutar-Nativo "$env:windir\System32\reg.exe" ("export `"{0}`" `"{1}`" /y" -f $Clave, $f) 60
    if ($r.Codigo -ne 0) { throw "No se pudo copiar $Clave (reg export $($r.Codigo))" }
    return $f
}

# ---------- punto de restauracion ----------
function Crear-PuntoRestauracion([switch]$ActivarSiHaceFalta) {
    $clave = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $previo = (Get-ItemProperty $clave -ErrorAction SilentlyContinue).SystemRestorePointCreationFrequency
    # Un punto de restauracion reserva espacio en el disco (instantaneas). Con poco espacio llenaria el disco: no se crea.
    $libreGB = (Get-Volume -DriveLetter ($env:SystemDrive.TrimEnd(':'))).SizeRemaining / 1GB
    if ($libreGB -lt 10) { Log ('  NO se crea punto de restauracion: solo hay {0:N1} GB libres (hacen falta 10). Se sigue con las copias de cada modulo.' -f $libreGB) 'aviso'; return $false }
    try {
        $antes = @(Get-ComputerRestorePoint -ErrorAction SilentlyContinue).Count
        try { Checkpoint-Computer -Description ('ReparaWin11 ' + (Get-Date -Format 'yyyy-MM-dd HH:mm')) -RestorePointType MODIFY_SETTINGS -ErrorAction Stop }
        catch {
            if (-not $ActivarSiHaceFalta) { throw }
            Log '  La Proteccion del sistema esta desactivada en C:. Se activa para poder crear el punto (se pidio en las opciones).' 'aviso'
            Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
            # Windows solo deja crear un punto cada 24 h; se permite uno ahora y se deja el valor como estaba
            New-ItemProperty $clave -Name SystemRestorePointCreationFrequency -PropertyType DWord -Value 0 -Force | Out-Null
            Checkpoint-Computer -Description ('ReparaWin11 ' + (Get-Date -Format 'yyyy-MM-dd HH:mm')) -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        }
        $despues = @(Get-ComputerRestorePoint -ErrorAction SilentlyContinue)
        if ($despues.Count -gt $antes) { Log ('  Punto de restauracion creado: ' + $despues[-1].Description) 'bien'; return $true }
        Log '  Windows no creo un punto nuevo (ya habia uno de hace menos de 24 h). Se sigue con las copias de cada modulo.' 'aviso'; return $true
    } catch { Log ('  No se pudo crear el punto de restauracion: ' + $_.Exception.Message) 'error'; return $false }
    finally {
        if ($null -eq $previo) { Remove-ItemProperty $clave -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue }
        else { New-ItemProperty $clave -Name SystemRestorePointCreationFrequency -PropertyType DWord -Value $previo -Force | Out-Null }
    }
}

# ---------- informe HTML ----------
function Escribir-Informe([array]$Filas, [string]$Archivo, [string[]]$Registro) {
    $h = { param($t) [System.Net.WebUtility]::HtmlEncode("$t") }
    $os = Get-CimInstance Win32_OperatingSystem
    $col = @{ Verde = '#2E7D32'; Amarillo = '#B26A00'; Rojo = '#C62828'; Gris = '#757575' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("<!doctype html><html lang='es'><head><meta charset='utf-8'><title>Informe ReparaWin11</title><style>body{font-family:Segoe UI,Arial;margin:24px;color:#222}table{border-collapse:collapse;width:100%}td,th{border:1px solid #ccc;padding:6px;vertical-align:top;font-size:13px}th{background:#eee}.e{font-weight:bold;color:#fff;padding:2px 6px;border-radius:3px}pre{background:#f6f6f6;padding:8px;font-size:12px;white-space:pre-wrap}</style></head><body>")
    [void]$sb.Append("<h1>Informe de ReparaWin11</h1><p>" + (& $h ("{0} {1} (compilacion {2}) - equipo {3} - {4}" -f $os.Caption, $os.OSArchitecture, $os.BuildNumber, $env:COMPUTERNAME, (Get-Date -Format 'dd/MM/yyyy HH:mm'))) + "</p>")
    if ($Global:RWCopias) { [void]$sb.Append('<p>Copias de seguridad: ' + (& $h $Global:RWCopias) + '</p>') }
    [void]$sb.Append('<table><tr><th>Area</th><th>Comprobacion</th><th>Estado</th><th>Que se hizo</th><th>Detalle</th></tr>')
    foreach ($f in $Filas) {
        [void]$sb.Append(('<tr><td>{0}</td><td>{1}</td><td><span class="e" style="background:{2}">{3}</span></td><td>{4}</td><td><pre>{5}</pre></td></tr>' -f (& $h $f.Grupo), (& $h $f.Nombre), $col[$f.Estado], (& $h $f.Estado), (& $h $f.Accion), (& $h (($f.Resumen) + "`n" + ($f.Detalle -join "`n")))))
    }
    [void]$sb.Append('</table><h2>Registro completo</h2><pre>' + (& $h ($Registro -join "`n")) + '</pre></body></html>')
    [IO.File]::WriteAllText($Archivo, $sb.ToString(), (New-Object Text.UTF8Encoding($true)))
}
