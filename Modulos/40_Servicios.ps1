# Servicios esenciales, impresion, audio, dispositivos con error y busqueda.

# Servicios sin los que Windows 11 no funciona bien, con su tipo de inicio de fabrica (2 = automatico, 3 = manual).
$Global:RWServiciosEsenciales = [ordered]@{
    RpcSs = 2; DcomLaunch = 2; RpcEptMapper = 2; EventLog = 2; Winmgmt = 2; CryptSvc = 2; Dhcp = 2; Dnscache = 2; NlaSvc = 2; nsi = 2
    BFE = 2; mpssvc = 2; LanmanWorkstation = 2; Schedule = 2; ProfSvc = 2; Power = 2; SamSs = 2; LSM = 2; AudioSrv = 2; AudioEndpointBuilder = 2
    Themes = 2; UserManager = 2; CoreMessagingRegistrar = 2; SystemEventsBroker = 2; BrokerInfrastructure = 2; EventSystem = 2; SENS = 2; Wcmsvc = 2
    BITS = 3; wuauserv = 3; TrustedInstaller = 3; msiserver = 3; AppXSvc = 3; ClipSVC = 3; Appinfo = 3; PlugPlay = 3
}

function Global:Estado-Servicios {
    $paradosAuto = @(); $deshab = @(); $faltan = @()
    foreach ($n in $Global:RWServiciosEsenciales.Keys) {
        $k = "HKLM:\SYSTEM\CurrentControlSet\Services\$n"
        if (-not (Test-Path $k)) { $faltan += $n; continue }
        $p = Get-ItemProperty $k
        $s = Get-Service -Name $n -ErrorAction SilentlyContinue
        if ($p.Start -eq 4) { $deshab += $n; continue }
        # automaticos parados: los de inicio por desencadenador (TriggerInfo) se paran solos cuando no hacen falta
        if ($p.Start -eq 2 -and $s -and $s.Status -ne 'Running' -and -not (Test-Path "$k\TriggerInfo")) { $paradosAuto += $n }
    }
    return [pscustomobject]@{ Parados = $paradosAuto; Deshabilitados = $deshab; Faltan = $faltan }
}

Registrar-Modulo @{
    Id = 'SERVICIOS'; Orden = 40; Grupo = 'Servicios y dispositivos'; Nombre = 'Servicios esenciales de Windows'
    Descripcion = 'Servicios automaticos que estan parados y esenciales deshabilitados. Los deshabilitados solo se habilitan con "Permitir reparaciones avanzadas" (pueden estarlo a proposito).'
    Diagnosticar = {
        $e = Estado-Servicios
        $d = @("Comprobados: $($Global:RWServiciosEsenciales.Count) servicios esenciales")
        if ($e.Parados) { $d += 'Automaticos PARADOS: ' + ($e.Parados -join ', ') }
        if ($e.Deshabilitados) { $d += 'DESHABILITADOS: ' + ($e.Deshabilitados -join ', ') }
        if ($e.Faltan) { $d += 'NO EXISTEN en este equipo: ' + ($e.Faltan -join ', ') }
        if ($e.Parados -or $e.Faltan) { return (Resultado 'Rojo' ("Parados: {0}; deshabilitados: {1}; inexistentes: {2}" -f $e.Parados.Count, $e.Deshabilitados.Count, $e.Faltan.Count) $d) }
        if ($e.Deshabilitados) { return (Resultado 'Amarillo' ('Servicios esenciales deshabilitados: ' + ($e.Deshabilitados -join ', ')) $d) }
        return (Resultado 'Verde' 'Todos los servicios esenciales estan bien.' $d)
    }
    Reparar = {
        param($ctx)
        $e = Estado-Servicios; $c = Carpeta-Copia 'SERVICIOS'
        $lista = @($e.Parados); if ($ctx.Opciones.Avanzadas) { $lista += $e.Deshabilitados } elseif ($e.Deshabilitados) { Log ('  Deshabilitados que NO se tocan (activa "Permitir reparaciones avanzadas" para habilitarlos): ' + ($e.Deshabilitados -join ', ')) 'aviso' }
        foreach ($n in $lista) { try { [void](Copiar-Registro "HKLM\SYSTEM\CurrentControlSet\Services\$n" $c $n) } catch { Log "  $_" 'error' } }
        foreach ($n in $e.Deshabilitados) {
            if (-not $ctx.Opciones.Avanzadas) { continue }
            $t = $Global:RWServiciosEsenciales[$n]
            $x = Ejecutar-Nativo "$env:windir\System32\sc.exe" ("config {0} start= {1}" -f $n, $(if ($t -eq 2) { 'auto' } else { 'demand' })) 60
            Log ("  {0}: tipo de inicio de fabrica ({1}) -> codigo {2}" -f $n, $(if ($t -eq 2) { 'automatico' } else { 'manual' }), $x.Codigo)
        }
        foreach ($n in $lista) {
            if ($Global:RWServiciosEsenciales[$n] -ne 2) { continue }   # los manuales los arranca Windows cuando los necesita
            try { $sc = New-Object ServiceProcess.ServiceController $n; if ($sc.Status -ne 'Running') { $sc.Start(); $sc.WaitForStatus('Running', [TimeSpan]::FromSeconds(45)) }; Log "  $n en marcha" 'bien' }
            catch { Log ("  {0} no arranco: {1}" -f $n, $_.Exception.GetBaseException().Message) 'error' }
        }
    }
}

Registrar-Modulo @{
    Id = 'IMPRESION'; Orden = 41; Grupo = 'Servicios y dispositivos'; Nombre = 'Impresion'
    Descripcion = 'Cola de impresion en automatico y en marcha sin tocar el escaner (CJ-18) y trabajos atascados sin cortar los de nadie (CJ-19).'
    Diagnosticar = {
        $a = Resultado-Esquiva (Ejecutar-Esquiva 'CJ-18' @{} -Silencioso) 'No hace falta cambiar nada|no existe' 'Servicio de impresion'
        $b = Resultado-Esquiva (Ejecutar-Esquiva 'CJ-19' @{} -Silencioso) 'No hace falta cambiar nada' 'Cola de impresion'
        $e = if ($a.Estado -eq 'Verde' -and $b.Estado -eq 'Verde') { 'Verde' } else { 'Amarillo' }
        Resultado $e ("Servicio: {0} | Cola: {1}" -f $a.Resumen, $b.Resumen) (@('--- servicio (CJ-18) ---') + $a.Detalle + @('--- cola (CJ-19) ---') + $b.Detalle)
    }
    Reparar = {
        param($ctx)
        [void](Ejecutar-Esquiva 'CJ-18' @{ Reparar = $true; CarpetaCopia = (Carpeta-Copia 'IMPRESION_servicio') })
        [void](Ejecutar-Esquiva 'CJ-19' @{ Reparar = $true; CarpetaCopia = (Carpeta-Copia 'IMPRESION_cola') })
    }
}

Registrar-Modulo @{
    Id = 'AUDIO'; Orden = 42; Grupo = 'Servicios y dispositivos'; Nombre = 'Sonido'
    Descripcion = 'Servicio de audio caido o colgado (CJ-22, sin matar procesos) y altavoz silenciado o sin volumen (CJ-25).'
    Diagnosticar = {
        $a = Resultado-Esquiva (Ejecutar-Esquiva 'CJ-22' @{} -Silencioso) 'No hace falta reiniciar nada' 'Servicio de audio'
        $b = Resultado-Esquiva (Ejecutar-Esquiva 'CJ-25' @{} -Silencioso) 'audio comprobado' 'Dispositivos de audio'
        $e = if ($a.Estado -eq 'Verde' -and $b.Estado -eq 'Verde') { 'Verde' } else { 'Amarillo' }
        Resultado $e ("Servicio: {0} | Dispositivos: {1}" -f $a.Resumen, $b.Resumen) (@('--- servicio (CJ-22) ---') + $a.Detalle + @('--- dispositivos (CJ-25) ---') + $b.Detalle)
    }
    Reparar = {
        param($ctx)
        [void](Ejecutar-Esquiva 'CJ-22' @{ Reparar = $true; CarpetaCopia = (Carpeta-Copia 'AUDIO_servicio') })
        [void](Ejecutar-Esquiva 'CJ-25' @{ Reparar = $true; CarpetaCopia = (Carpeta-Copia 'AUDIO_dispositivos') })
    }
}

Registrar-Modulo @{
    Id = 'DISPOSITIVOS'; Orden = 43; Grupo = 'Servicios y dispositivos'; Nombre = 'Dispositivos con error'
    Descripcion = 'Dispositivos presentes con codigo de error en el Administrador de dispositivos. Los deshabilitados (codigo 22) se respetan. La reparacion vuelve a detectar el hardware sin desinstalar nada.'
    Diagnosticar = {
        $mal = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { [int]$_.ConfigManagerErrorCode -ne 0 })
        $desh = @($mal | Where-Object { [int]$_.ConfigManagerErrorCode -eq 22 }); $err = @($mal | Where-Object { [int]$_.ConfigManagerErrorCode -ne 22 })
        $sig = @{ 1 = 'mal configurado'; 3 = 'controlador danado'; 10 = 'no puede iniciarse'; 18 = 'reinstalar controlador'; 19 = 'registro danado'; 28 = 'SIN controlador'; 31 = 'controlador no carga'; 39 = 'controlador danado o ausente'; 43 = 'el dispositivo informo de un fallo'; 45 = 'no conectado'; 52 = 'firma del controlador no valida' }
        $d = @($err | ForEach-Object { '{0} | codigo {1} ({2}) | {3}' -f $_.FriendlyName, [int]$_.ConfigManagerErrorCode, $sig[[int]$_.ConfigManagerErrorCode], $_.InstanceId })
        $d += @($desh | ForEach-Object { 'deshabilitado (se respeta): {0}' -f $_.FriendlyName })
        if ($err) { return (Resultado 'Rojo' "$($err.Count) dispositivo(s) con error." $d) }
        if ($desh) { return (Resultado 'Verde' "Ningun dispositivo con error ($($desh.Count) deshabilitado(s) a proposito)." $d) }
        return (Resultado 'Verde' 'Ningun dispositivo con error.' $d)
    }
    Reparar = {
        param($ctx)
        Log '  pnputil /scan-devices: Windows vuelve a detectar el hardware y busca controlador para lo que no lo tiene...'
        $x = Ejecutar-Nativo "$env:windir\System32\pnputil.exe" '/scan-devices' 300
        Log ('  codigo ' + $x.Codigo)
        Log '  Si siguen dispositivos SIN controlador (codigo 28), instala el controlador del fabricante o los controladores opcionales de Windows Update.' 'aviso'
    }
}

Registrar-Modulo @{
    Id = 'BUSQUEDA'; Orden = 44; Grupo = 'Servicios y dispositivos'; Nombre = 'Busqueda de Windows'
    Descripcion = 'Servicio WSearch e indice. La reparacion guarda alcance y permisos y reinicia el servicio sin vaciar el indice (CJ-15).'
    Diagnosticar = {
        $s = Get-Service WSearch -ErrorAction SilentlyContinue
        if (-not $s) { return (Resultado 'Amarillo' 'El servicio de busqueda (WSearch) no existe en este equipo.' @()) }
        $p = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\WSearch'
        $r = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Search' -ErrorAction SilentlyContinue
        $dir = if ($r.DataDirectory) { $r.DataDirectory } else { "$env:ProgramData\Microsoft\Search\Data\" }
        $sinAcceso = $false
        try { $db = @(Get-ChildItem (Join-Path $dir 'Applications\Windows') -Filter 'Windows.*' -File -ErrorAction Stop) } catch [UnauthorizedAccessException] { $sinAcceso = $true; $db = @() } catch { $db = @() }
        if ($sinAcceso) { return (Resultado 'Gris' 'No se puede leer la carpeta del indice (hace falta administrador).' @("WSearch: $($s.Status)")) }
        $d = @("WSearch: $($s.Status), inicio $($s.StartType)", "SetupCompletedSuccessfully = $($r.SetupCompletedSuccessfully)", ('Indice: ' + $(if ($db) { ($db | ForEach-Object { '{0} {1:N1} MB' -f $_.Name, ($_.Length / 1MB) }) -join ', ' } else { 'no encontrado' })))
        if ($p.Start -eq 4) { return (Resultado 'Amarillo' 'La busqueda esta deshabilitada (puede ser a proposito).' $d) }
        if ($s.Status -ne 'Running') { return (Resultado 'Rojo' 'El servicio de busqueda esta parado.' $d) }
        if ($r.SetupCompletedSuccessfully -eq 0) { return (Resultado 'Amarillo' 'El indice esta marcado para reconstruirse (SetupCompletedSuccessfully=0).' $d) }
        if (-not $db) { return (Resultado 'Amarillo' 'No se encuentra el archivo del indice.' $d) }
        return (Resultado 'Verde' 'La busqueda funciona y el indice existe.' $d)
    }
    Reparar = { param($ctx) [void](Ejecutar-Esquiva 'CJ-15' @{ Reparar = $true; CarpetaCopia = (Carpeta-Copia 'BUSQUEDA') }) }
}
