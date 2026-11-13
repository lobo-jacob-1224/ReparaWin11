# Base del sistema: reinicio pendiente, imagen de Windows (DISM), archivos protegidos (SFC), disco y WMI.

Registrar-Modulo @{
    Id = 'REINICIO'; Orden = 5; Grupo = 'Base del sistema'; Nombre = 'Reinicio pendiente'
    Descripcion = 'Si Windows espera un reinicio, muchas reparaciones no se completan hasta reiniciar.'
    Diagnosticar = {
        $m = @()
        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $m += 'Mantenimiento de componentes (CBS) espera reinicio' }
        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $m += 'Windows Update espera reinicio' }
        $pfr = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction SilentlyContinue).PendingFileRenameOperations
        if ($pfr) { $m += ('Hay {0} archivos pendientes de reemplazar al reiniciar' -f [int](@($pfr).Count / 2)) }
        $arranque = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
        $d = @(('Ultimo arranque: {0:dd/MM/yyyy HH:mm} (hace {1:N1} dias)' -f $arranque, ((Get-Date) - $arranque).TotalDays)) + $m
        if ($m.Count) { return (Resultado 'Amarillo' 'Windows espera un reinicio. Reinicia y vuelve a diagnosticar antes de reparar.' $d) }
        return (Resultado 'Verde' 'No hay ningun reinicio pendiente.' $d)
    }
}

Registrar-Modulo @{
    Id = 'IMAGEN'; Orden = 10; Grupo = 'Base del sistema'; Nombre = 'Imagen de Windows (DISM)'
    Descripcion = 'Almacen de componentes de Windows. Si esta danado, SFC no puede reparar los archivos del sistema.'
    Diagnosticar = {
        param($ctx)
        if ($ctx.Opciones.Lentos) { Log '  DISM /ScanHealth: analisis completo, puede tardar de 5 a 20 minutos...'; $r = Repair-WindowsImage -Online -ScanHealth -NoRestart -ErrorAction Stop }
        else { $r = Repair-WindowsImage -Online -CheckHealth -NoRestart -ErrorAction Stop }
        $tipo = if ($ctx.Opciones.Lentos) { 'analisis completo (ScanHealth)' } else { 'comprobacion rapida (CheckHealth); el analisis completo se hace marcando "Incluir analisis lentos"' }
        switch ("$($r.ImageHealthState)") {
            'Healthy' { return (Resultado 'Verde' 'La imagen de Windows esta sana.' @("Metodo: $tipo")) }
            'Repairable' { return (Resultado 'Rojo' 'La imagen de Windows esta danada y se puede reparar (DISM /RestoreHealth).' @("Metodo: $tipo")) }
            'NonRepairable' { return (Resultado 'Rojo' 'La imagen de Windows esta danada y Windows dice que NO se puede reparar en linea: hace falta reparar con el medio de instalacion.' @("Metodo: $tipo")) }
            default { return (Resultado 'Amarillo' "Estado de la imagen: $($r.ImageHealthState)" @("Metodo: $tipo")) }
        }
    }
    Reparar = {
        param($ctx)
        Log '  DISM /RestoreHealth: descarga lo danado desde Windows Update. Puede tardar de 10 a 40 minutos; la ventana sigue respondiendo.'
        $r = Repair-WindowsImage -Online -RestoreHealth -NoRestart -ErrorAction Stop
        Log ("  DISM termino. Estado: {0}; reinicio necesario: {1}" -f $r.ImageHealthState, $r.RestartNeeded)
        if ("$($r.ImageHealthState)" -eq 'Healthy') { return (Resultado 'Verde' 'Imagen de Windows reparada y comprobada (Healthy).' @("RestartNeeded=$($r.RestartNeeded)")) }
        return (Resultado 'Rojo' "DISM no pudo dejar la imagen sana (estado $($r.ImageHealthState)). Sin conexion a Windows Update hace falta el medio de instalacion (DISM /Source)." @())
    }
    VerificaAlReparar = $true
}

# SFC: el resultado se lee del registro CBS.log (en ingles en cualquier idioma de Windows), no de la pantalla.
function Global:Lineas-CBS([datetime]$Desde) {
    $f = "$env:windir\Logs\CBS\CBS.log"
    if (-not (Test-Path $f)) { return @() }
    $fs = [IO.File]::Open($f, 'Open', 'Read', 'ReadWrite'); $sr = New-Object IO.StreamReader($fs)
    try { $todo = $sr.ReadToEnd() } finally { $sr.Close() }
    $out = @()
    foreach ($l in ($todo -split "`r?`n")) {
        if ($l -match '^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)') { $t = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', $null); if ($t -ge $Desde -and $l -match '\[SR\]') { $out += $l } }
    }
    return $out
}
function Global:Juzgar-SFC([string[]]$L) {
    $noRep = @($L | Where-Object { $_ -match 'Cannot repair member file' }).Count
    $rep = @($L | Where-Object { $_ -match 'Repairing corrupted file|Repaired file' }).Count
    $mal = @($L | Where-Object { $_ -match 'do not match actual file|Corrupt|corrupt' }).Count
    return [pscustomobject]@{ NoReparables = $noRep; Reparados = $rep; Danados = $mal; Lineas = $L.Count }
}

Registrar-Modulo @{
    Id = 'ARCHIVOS'; Orden = 11; Grupo = 'Base del sistema'; Nombre = 'Archivos protegidos del sistema (SFC)'; Lento = $true
    Descripcion = 'Comprueba que los archivos de Windows no estan danados ni sustituidos. Conviene reparar antes la imagen (DISM).'
    Diagnosticar = {
        param($ctx)
        if (-not $ctx.Opciones.Lentos) { return (Resultado 'Gris' 'No comprobado: es un analisis lento (5-15 min). Marca "Incluir analisis lentos".' @()) }
        $t0 = (Get-Date).AddSeconds(-2)
        Log '  sfc /verifyonly: comprobando los archivos del sistema (5-15 minutos)...'
        $r = Ejecutar-Nativo "$env:windir\System32\sfc.exe" '/verifyonly' 3600
        if ($r.Agotado) { return (Resultado 'Amarillo' 'SFC no termino en 60 minutos.' $r.Salida) }
        $j = Juzgar-SFC (Lineas-CBS $t0)
        $d = @("Lineas [SR] del registro CBS: $($j.Lineas)") + @($r.Salida | Select-Object -Last 4)
        if ($j.Lineas -eq 0) { return (Resultado 'Amarillo' 'SFC no dejo resultados en CBS.log; revisa el detalle.' $d) }
        if ($j.Danados -gt 0) { return (Resultado 'Rojo' "SFC encontro archivos danados ($($j.Danados) avisos). Se reparan con sfc /scannow." $d) }
        return (Resultado 'Verde' 'SFC no encontro archivos danados.' $d)
    }
    Reparar = {
        param($ctx)
        $t0 = (Get-Date).AddSeconds(-2)
        Log '  sfc /scannow: reparando los archivos del sistema (10-20 minutos)...'
        $r = Ejecutar-Nativo "$env:windir\System32\sfc.exe" '/scannow' 5400
        if ($r.Agotado) { return (Resultado 'Rojo' 'sfc /scannow no termino en 90 minutos.' $r.Salida) }
        $j = Juzgar-SFC (Lineas-CBS $t0)
        $d = @("Reparados: $($j.Reparados) | No reparables: $($j.NoReparables)") + @($r.Salida | Select-Object -Last 4)
        if ($j.NoReparables -gt 0) { return (Resultado 'Rojo' "SFC no pudo reparar $($j.NoReparables) archivo(s). Repara primero la imagen (DISM) y vuelve a ejecutar." $d) }
        if ($j.Reparados -gt 0) { return (Resultado 'Verde' "SFC reparo $($j.Reparados) archivo(s). Reinicia para terminar." $d) }
        return (Resultado 'Verde' 'SFC termino sin encontrar nada que reparar.' $d)
    }
    VerificaAlReparar = $true
}

Registrar-Modulo @{
    Id = 'DISCO'; Orden = 12; Grupo = 'Base del sistema'; Nombre = 'Disco del sistema'
    Descripcion = 'Salud del disco fisico, del volumen C: y del sistema de archivos.'
    Diagnosticar = {
        param($ctx)
        $d = @(); $estado = 'Verde'; $res = @()
        $v = Get-Volume -DriveLetter ($env:SystemDrive.TrimEnd(':')) -ErrorAction SilentlyContinue
        if ($v) { $d += ('Volumen {0}: {1} | libre {2:N1} GB de {3:N1} GB' -f $v.DriveLetter, $v.HealthStatus, ($v.SizeRemaining / 1GB), ($v.Size / 1GB)); if ("$($v.HealthStatus)" -ne 'Healthy') { $estado = 'Rojo'; $res += "volumen $($v.HealthStatus)" } }
        foreach ($p in @(Get-PhysicalDisk -ErrorAction SilentlyContinue)) {
            $d += ('Disco fisico {0}: salud {1}, estado {2}, tipo {3}' -f $p.FriendlyName, $p.HealthStatus, $p.OperationalStatus, $p.MediaType)
            if ("$($p.HealthStatus)" -ne 'Healthy') { $estado = 'Rojo'; $res += "disco $($p.FriendlyName) $($p.HealthStatus): haz copia de tus datos YA; ningun programa repara un disco que falla" }
        }
        if ($ctx.Opciones.Lentos) {
            Log '  Repair-Volume -Scan (chkdsk en linea, sin desmontar): puede tardar varios minutos...'
            $s = Repair-Volume -DriveLetter ($env:SystemDrive.TrimEnd(':')) -Scan -ErrorAction SilentlyContinue
            $d += "Analisis del sistema de archivos: $s"
            if ("$s" -ne 'NoErrorsFound' -and "$s") { if ($estado -eq 'Verde') { $estado = 'Amarillo' }; $res += "el sistema de archivos tiene errores ($s)" }
        } else { $d += 'Sistema de archivos: no analizado (marca "Incluir analisis lentos")' }
        if ($estado -eq 'Verde') { return (Resultado 'Verde' 'Disco y volumen del sistema sanos.' $d) }
        return (Resultado $estado ('Problemas: ' + ($res -join '; ')) $d)
    }
    Reparar = {
        param($ctx)
        $letra = $env:SystemDrive.TrimEnd(':')
        try { $r = Repair-Volume -DriveLetter $letra -SpotFix -ErrorAction Stop; return (Resultado 'Verde' "Correccion puntual hecha: $r" @()) }
        catch {
            # el volumen del sistema no se puede bloquear con Windows en marcha: se programa la revision al reiniciar
            $x = Ejecutar-Nativo "$env:windir\System32\fsutil.exe" "dirty set $env:SystemDrive" 60
            if ($x.Codigo -eq 0) { return (Resultado 'Amarillo' 'C: esta en uso: la reparacion del sistema de archivos se hara en el proximo reinicio (chkdsk automatico).' $x.Salida) }
            return (Resultado 'Rojo' ('No se pudo programar la reparacion: ' + $_.Exception.Message) $x.Salida)
        }
    }
    VerificaAlReparar = $true; Avanzado = $true; Reinicio = $true
}

Registrar-Modulo @{
    Id = 'WMI'; Orden = 13; Grupo = 'Base del sistema'; Nombre = 'Instrumental de administracion (WMI)'
    Descripcion = 'Si WMI esta danado fallan el Administrador de dispositivos, las directivas, los antivirus y muchos scripts.'
    Diagnosticar = {
        $r = Ejecutar-Nativo "$env:windir\System32\wbem\winmgmt.exe" '/verifyrepository' 300
        $ok = $true; try { [void](Get-CimInstance Win32_OperatingSystem -ErrorAction Stop) } catch { $ok = $false }
        $d = @($r.Salida) + @("Consulta de prueba Win32_OperatingSystem: $(if ($ok) { 'responde' } else { 'FALLA' })")
        if ($r.Codigo -eq 0 -and $ok) { return (Resultado 'Verde' 'El repositorio de WMI es coherente y responde.' $d) }
        return (Resultado 'Rojo' "WMI tiene problemas (verifyrepository = $($r.Codigo); consulta $(if ($ok) { 'responde' } else { 'falla' }))." $d)
    }
    Reparar = {
        param($ctx)
        $c = Carpeta-Copia 'WMI'
        Log '  Copia del repositorio de WMI (winmgmt /backup)...'
        $b = Ejecutar-Nativo "$env:windir\System32\wbem\winmgmt.exe" ("/backup `"{0}`"" -f (Join-Path $c 'repositorio.bak')) 600
        Log "  copia: codigo $($b.Codigo)"
        Log '  winmgmt /salvagerepository: reconstruye el repositorio conservando lo que se pueda leer...'
        $r = Ejecutar-Nativo "$env:windir\System32\wbem\winmgmt.exe" '/salvagerepository' 900
        Log ("  salvagerepository: codigo {0}" -f $r.Codigo)
    }
}
