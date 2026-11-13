# Aplicaciones de la Tienda, espacio en disco y seguridad (Defender, UAC, SMB1).

Registrar-Modulo @{
    Id = 'APPS'; Orden = 50; Grupo = 'Aplicaciones y espacio'; Nombre = 'Aplicaciones de Windows (Tienda, Inicio, Configuracion)'
    Descripcion = 'Paquetes del usuario con estado distinto de Ok (danados, modificados o pendientes de reparar). Solo se vuelven a registrar esos, no todos.'
    Diagnosticar = {
        $todas = @(Get-AppxPackage -ErrorAction SilentlyContinue)
        $mal = @($todas | Where-Object { "$($_.Status)" -ne 'Ok' })
        $clave = 'Microsoft.WindowsStore', 'Microsoft.Windows.StartMenuExperienceHost', 'Microsoft.Windows.ShellExperienceHost', 'windows.immersivecontrolpanel'
        $faltan = @($clave | Where-Object { $n = $_; -not ($todas | Where-Object Name -eq $n) })
        $d = @("Paquetes del usuario: $($todas.Count)") + @($mal | ForEach-Object { '{0} -> {1}' -f $_.Name, $_.Status })
        if ($faltan) { $d += 'Faltan paquetes basicos: ' + ($faltan -join ', ') }
        if ($mal) { return (Resultado 'Rojo' "$($mal.Count) aplicacion(es) en mal estado." $d) }
        if ($faltan) { return (Resultado 'Amarillo' ('Faltan aplicaciones basicas: ' + ($faltan -join ', ')) $d) }
        return (Resultado 'Verde' 'Todas las aplicaciones del usuario estan en buen estado.' $d)
    }
    Reparar = {
        param($ctx)
        foreach ($p in @(Get-AppxPackage | Where-Object { "$($_.Status)" -ne 'Ok' })) {
            $m = Join-Path $p.InstallLocation 'AppxManifest.xml'
            if (-not (Test-Path -LiteralPath $m)) { Log "  $($p.Name): no existe su manifiesto; hay que reinstalarla desde la Tienda." 'error'; continue }
            try { Add-AppxPackage -DisableDevelopmentMode -Register $m -ErrorAction Stop; Log "  $($p.Name): registrada de nuevo" 'bien' }
            catch { Log ("  {0}: {1}" -f $p.Name, $_.Exception.Message) 'error' }
        }
    }
}

function Global:Tamano-Carpeta([string]$Ruta) { if (-not (Test-Path -LiteralPath $Ruta)) { return 0 }; [double](Get-ChildItem -LiteralPath $Ruta -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum }

Registrar-Modulo @{
    Id = 'ESPACIO'; Orden = 51; Grupo = 'Aplicaciones y espacio'; Nombre = 'Espacio en el disco del sistema'
    Descripcion = 'Con poco espacio fallan las actualizaciones y el propio Windows. Limpia temporales de mas de 2 dias, la cache de Optimizacion de distribucion y los componentes de Windows sustituidos (sin /ResetBase). No toca documentos ni la papelera.'
    Diagnosticar = {
        $v = Get-Volume -DriveLetter ($env:SystemDrive.TrimEnd(':'))
        $libre = $v.SizeRemaining / 1GB; $pct = 100 * $v.SizeRemaining / $v.Size
        $t = [ordered]@{ 'Temporales del usuario' = (Tamano-Carpeta $env:TEMP); 'Temporales de Windows' = (Tamano-Carpeta "$env:windir\Temp"); 'Descargas de Windows Update' = (Tamano-Carpeta "$env:windir\SoftwareDistribution\Download"); 'Informes de errores (WER)' = (Tamano-Carpeta "$env:ProgramData\Microsoft\Windows\WER") }
        $d = @(('Libre: {0:N1} GB ({1:N0} %) de {2:N1} GB' -f $libre, $pct, ($v.Size / 1GB))) + @($t.Keys | ForEach-Object { '{0}: {1:N0} MB' -f $_, ($t[$_] / 1MB) })
        if ($libre -lt 5 -or $pct -lt 5) { return (Resultado 'Rojo' ('Espacio CRITICO: {0:N1} GB libres.' -f $libre) $d) }
        if ($libre -lt 15 -or $pct -lt 10) { return (Resultado 'Amarillo' ('Poco espacio: {0:N1} GB libres.' -f $libre) $d) }
        return (Resultado 'Verde' ('Espacio suficiente: {0:N1} GB libres.' -f $libre) $d)
    }
    Reparar = {
        param($ctx)
        $antes = (Get-Volume -DriveLetter ($env:SystemDrive.TrimEnd(':'))).SizeRemaining
        $limite = (Get-Date).AddDays(-2)
        foreach ($dir in @($env:TEMP, "$env:windir\Temp")) {
            $n = 0; Get-ChildItem -LiteralPath $dir -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $limite } | ForEach-Object { try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop; $n++ } catch { } }
            Log "  $dir`: $n archivo(s) temporal(es) de mas de 2 dias borrados (los que estaban en uso se dejan)"
        }
        try { Delete-DeliveryOptimizationCache -Force -ErrorAction Stop; Log '  Cache de Optimizacion de distribucion vaciada' } catch { Log ('  Optimizacion de distribucion: ' + $_.Exception.Message) 'aviso' }
        Log '  Limpieza de componentes sustituidos (DISM /StartComponentCleanup, sin /ResetBase: se pueden seguir desinstalando actualizaciones). Puede tardar varios minutos...'
        try { [void](Repair-WindowsImage -Online -StartComponentCleanup -NoRestart -ErrorAction Stop); Log '  Componentes limpiados' } catch { Log ('  DISM: ' + $_.Exception.Message) 'aviso' }
        $ganado = ((Get-Volume -DriveLetter ($env:SystemDrive.TrimEnd(':'))).SizeRemaining - $antes) / 1MB
        Log ('  Espacio recuperado: {0:N0} MB' -f $ganado) $(if ($ganado -gt 100) { 'bien' } else { 'aviso' })
        if ($ganado -le 100) { Log '  Casi no se recupero espacio: lo que ocupa el disco son programas y datos. Desinstala programas que no uses o amplia el disco.' 'aviso' }
    }
}

Registrar-Modulo @{
    Id = 'DEFENDER'; Orden = 60; Grupo = 'Seguridad'; Nombre = 'Antivirus (Microsoft Defender)'
    Descripcion = 'Proteccion en tiempo real y firmas al dia. Si hay otro antivirus instalado, Defender queda en pasivo y se informa. La reparacion actualiza las firmas; no cambia directivas.'
    Diagnosticar = {
        $otros = @(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction SilentlyContinue | Where-Object { $_.displayName -notmatch 'Windows Defender|Microsoft Defender' } | ForEach-Object displayName)
        try { $m = Get-MpComputerStatus -ErrorAction Stop } catch { if ($otros) { return (Resultado 'Verde' ('Antivirus de terceros: ' + ($otros -join ', ')) @()) }; return (Resultado 'Rojo' ('No se puede consultar Defender: ' + $_.Exception.Message) @()) }
        $d = @("Servicio antimalware: $($m.AMServiceEnabled) | tiempo real: $($m.RealTimeProtectionEnabled) | antivirus: $($m.AntivirusEnabled)", ('Firmas: version {0}, de hace {1} dia(s)' -f $m.AntivirusSignatureVersion, $m.AntivirusSignatureAge))
        if ($otros) { $d += 'Otro antivirus registrado: ' + ($otros -join ', ') }
        if ($otros -and -not $m.RealTimeProtectionEnabled) { return (Resultado 'Verde' ('Protege otro antivirus: ' + ($otros -join ', ')) $d) }
        if (-not $m.AMServiceEnabled -or -not $m.RealTimeProtectionEnabled) { return (Resultado 'Rojo' 'La proteccion en tiempo real esta DESACTIVADA y no hay otro antivirus.' $d) }
        if ($m.AntivirusSignatureAge -gt 3) { return (Resultado 'Amarillo' "Firmas antiguas ($($m.AntivirusSignatureAge) dias)." $d) }
        return (Resultado 'Verde' 'Defender activo y con firmas al dia.' $d)
    }
    Reparar = {
        param($ctx)
        try { Update-MpSignature -ErrorAction Stop; Log '  Firmas de Defender actualizadas' 'bien' } catch { Log ('  Update-MpSignature: ' + $_.Exception.Message) 'error' }
        $m = Get-MpComputerStatus -ErrorAction SilentlyContinue
        if ($m -and -not $m.RealTimeProtectionEnabled) {
            $pol = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection' -ErrorAction SilentlyContinue
            if ($pol.DisableRealtimeMonitoring -eq 1) { Log '  El tiempo real esta apagado POR DIRECTIVA (HKLM\SOFTWARE\Policies\...\Real-Time Protection). No se cambia: revisa quien la puso (posible malware).' 'aviso' }
            else { try { Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction Stop; Log '  Proteccion en tiempo real activada' 'bien' } catch { Log ('  No se pudo activar el tiempo real (Proteccion contra alteraciones o directiva): ' + $_.Exception.Message) 'aviso' } }
        }
    }
}

$Global:RWUacFabrica = [ordered]@{ EnableLUA = 1; ConsentPromptBehaviorAdmin = 5; PromptOnSecureDesktop = 1 }
Registrar-Modulo @{
    Id = 'UAC'; Orden = 61; Grupo = 'Seguridad'; Nombre = 'Control de cuentas de usuario (UAC)'
    Descripcion = 'UAC apagado o elevando sin preguntar deja cualquier programa como administrador. Solo se corrigen los valores debilitados; si se cambia EnableLUA hay que reiniciar.'
    Diagnosticar = {
        $p = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
        $d = @($Global:RWUacFabrica.Keys | ForEach-Object { '{0} = {1} (fabrica {2})' -f $_, $p.$_, $Global:RWUacFabrica[$_] })
        if ($p.EnableLUA -eq 0) { return (Resultado 'Rojo' 'UAC esta APAGADO (EnableLUA=0).' $d) }
        if ($p.ConsentPromptBehaviorAdmin -eq 0) { return (Resultado 'Rojo' 'UAC eleva a los administradores SIN preguntar.' $d) }
        if ($p.PromptOnSecureDesktop -eq 0) { return (Resultado 'Amarillo' 'UAC pregunta fuera del escritorio seguro (mas facil de suplantar).' $d) }
        return (Resultado 'Verde' 'UAC con la proteccion de fabrica o mas estricta.' $d)
    }
    Reparar = {
        param($ctx)
        $c = Carpeta-Copia 'UAC'; [void](Copiar-Registro 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' $c 'Policies_System')
        $k = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'; $p = Get-ItemProperty $k
        foreach ($n in $Global:RWUacFabrica.Keys) {
            $debil = switch ($n) { 'EnableLUA' { $p.EnableLUA -eq 0 } 'ConsentPromptBehaviorAdmin' { $p.ConsentPromptBehaviorAdmin -eq 0 } 'PromptOnSecureDesktop' { $p.PromptOnSecureDesktop -eq 0 } }
            if ($debil) { Set-ItemProperty $k -Name $n -Value $Global:RWUacFabrica[$n] -Type DWord; Log ("  {0}: {1} -> {2}" -f $n, $p.$n, $Global:RWUacFabrica[$n]) 'bien' }
        }
        if ($p.EnableLUA -eq 0) { Log '  EnableLUA cambiado: REINICIA para que UAC vuelva a funcionar.' 'aviso' }
    }
}

Registrar-Modulo @{
    Id = 'SMB1'; Orden = 62; Grupo = 'Seguridad'; Nombre = 'Protocolo SMB1 (obsoleto e inseguro)'; Avanzado = $true; Reinicio = $true
    Descripcion = 'SMB1 es el protocolo que usaron WannaCry y NotPetya. Se comprueba el estado REAL de la caracteristica y se retira sin reiniciar por su cuenta (CJ-08). Ojo: algunos NAS y escaneres antiguos solo hablan SMB1.'
    Diagnosticar = {
        $f = @(Get-WindowsOptionalFeature -Online -ErrorAction Stop | Where-Object { $_.FeatureName -like 'SMB1Protocol*' })
        $act = @($f | Where-Object { "$($_.State)" -match 'Enabled' })
        $d = @($f | ForEach-Object { '{0}: {1}' -f $_.FeatureName, $_.State })
        if ($act) { return (Resultado 'Rojo' ('SMB1 esta instalado: ' + (($act | ForEach-Object FeatureName) -join ', ')) $d) }
        return (Resultado 'Verde' 'SMB1 no esta instalado.' $d)
    }
    Reparar = { param($ctx) [void](Ejecutar-Esquiva 'CJ-08' @{ Desinstalar = $true; CarpetaCopia = (Carpeta-Copia 'SMB1') }) }
}
