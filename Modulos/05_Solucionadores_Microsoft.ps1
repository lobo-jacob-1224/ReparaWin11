# Solucionadores REALES de Microsoft (los que contienen los scripts rojos y naranjas del laboratorio).
# Se ejecutan con Invoke-TroubleshootingPack en modo automatico: detectan y APLICAN sus reparaciones.
# Alrededor de cada uno hay una red de seguridad basada en los callejones medidos en el laboratorio:
#   Antes   -> copia de lo que ese solucionador destruye o cambia sin copia.
#   Despues -> los scripts de esquiva probados deshacen el dano conocido (permisos, servicios, nombres...).

function Global:Ejecutar-PaqueteMS([string]$Paquete, [string]$Copia) {
    $pk = Get-TroubleshootingPack -Path "$env:windir\diagnostics\system\$Paquete" -ErrorAction Stop
    $res = Join-Path $Copia 'informe_microsoft'
    Log "  Ejecutando el solucionador de Microsoft '$($pk.Name)' en modo automatico (detecta y aplica sus reparaciones)..."
    Invoke-TroubleshootingPack -Pack $pk -Unattended -Result $res -ErrorAction Stop | Out-Null
    $f = Join-Path $res 'ResultReport.xml'
    if (-not (Test-Path $f)) { return (Resultado 'Amarillo' 'El solucionador termino sin dejar informe.' @()) }
    [xml]$x = Get-Content $f -Raw -Encoding UTF8
    $det = @(); $encontrados = 0; $arreglados = 0; $sinArreglar = 0
    foreach ($rc in $x.SelectNodes('//RootCause')) {
        $st = ($rc.SelectSingleNode("Data[@id='Status']")).InnerText
        if ($st -in 'Not Checked', 'Not Present', 'Not Detected') { continue }   # solo cuentan los detectados
        $encontrados++
        $resol = @($rc.SelectNodes('ResolutionInformation/Resolution') | ForEach-Object { '{0} -> {1}' -f $_.name, ($_.SelectSingleNode("Data[@id='Status']")).InnerText })
        if ($st -match 'Fixed' -and $st -notmatch 'Not Fixed') { $arreglados++ } else { $sinArreglar++ }
        $det += ('[{0}] {1}' -f $st, $rc.name); $det += @($resol | ForEach-Object { '      ' + $_ })
        Log ('    {0}: {1}' -f $st, $rc.name) $(if ($st -match 'Not Fixed|Detected') { 'aviso' } else { 'detalle' })
    }
    $det += "Informe de Microsoft completo: $f"
    if ($encontrados -eq 0) { return (Resultado 'Verde' "Microsoft no encontro problemas en '$($pk.Name)'." $det) }
    if ($sinArreglar -eq 0) { return (Resultado 'Verde' "Microsoft encontro $encontrados problema(s) y los arreglo." $det) }
    return (Resultado 'Amarillo' "Microsoft encontro $encontrados problema(s): arreglados $arreglados, sin arreglar $sinArreglar." $det)
}

function Global:Copiar-Carpeta([string]$Origen, [string]$Destino) {
    if (-not (Test-Path -LiteralPath $Origen)) { return }
    # no llenar el disco con la copia: se deja al menos 1 GB libre
    $tam = [double](Get-ChildItem -LiteralPath $Origen -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    $libre = (Get-Volume -DriveLetter ($env:SystemDrive.TrimEnd(':'))).SizeRemaining
    if ($tam -gt ($libre - 1GB)) { Log ("  NO se copia {0} ({1:N0} MB): no cabe dejando 1 GB libre ({2:N0} MB libres). Libera espacio si quieres esta copia." -f $Origen, ($tam / 1MB), ($libre / 1MB)) 'aviso'; return }
    $r = Ejecutar-Nativo "$env:windir\System32\robocopy.exe" ("`"{0}`" `"{1}`" /E /R:0 /W:0 /NP /NFL /NDL /XJ" -f $Origen, $Destino) 900
    Log ("  Copia de {0} -> {1} (robocopy {2})" -f $Origen, $Destino, $r.Codigo)
}

# Definicion de cada solucionador: paquete, modulos de diagnostico relacionados, callejones, red de seguridad.
$Global:RWPaquetesMS = @(
    @{ Id = 'MS_WU'; Paquete = 'WindowsUpdate'; Nombre = 'Solucionador de Windows Update (Microsoft)'; Rel = 'WU_SERVICIOS', 'WU_CACHE', 'WU_APPDATA', 'HORA', 'BITS'
       Trampas = 'Rojos: RS_DataStore, RS_GENWUError, cl_Service. Callejones: borra cache e historial (CJ-07), para AppLocker (CJ-05), cambia la hora y el servicio (CJ-20), AppData (CJ-38).'
       Antes = { param($c) Copiar-Carpeta "$env:windir\SoftwareDistribution\DataStore" (Join-Path $c 'DataStore'); Copy-Item "$env:windir\SoftwareDistribution\ReportingEvents.log" $c -ErrorAction SilentlyContinue
                 Get-Service AppIDSvc, applockerfltr, CryptSvc, W32Time -ErrorAction SilentlyContinue | Select-Object Name, Status, StartType | Export-Csv (Join-Path $c 'servicios_antes.csv') -NoTypeInformation -Encoding UTF8 }
       Despues = { param($c) $antes = @(Import-Csv (Join-Path $c 'servicios_antes.csv') -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Running' } | ForEach-Object Name)
                   [void](Ejecutar-Esquiva 'CJ-05' @{ Reparar = $true; ArrancarTambien = @($antes | Where-Object { $_ -in 'AppIDSvc', 'applockerfltr' }); CarpetaCopia = (Join-Path $c 'esquiva_CJ-05') }) } }
    @{ Id = 'MS_BITS'; Paquete = 'BITS'; Nombre = 'Solucionador de BITS (Microsoft)'; Rel = 'BITS'
       Trampas = 'Rojos: RS_BITSRegKeys, RS_BITSACL. Callejon CJ-01: deja la clave de BITS sin permisos para SYSTEM; CJ-36: pisa el descriptor del servicio.'
       Antes = { param($c) [void](Copiar-Registro 'HKLM\SYSTEM\CurrentControlSet\Services\BITS' $c 'BITS'); (Get-Acl -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\BITS\Parameters').GetSecurityDescriptorSddlForm('All') | Set-Content (Join-Path $c 'Parameters_sddl.txt'); (Ejecutar-Nativo "$env:windir\System32\sc.exe" 'sdshow BITS' 30).Salida | Set-Content (Join-Path $c 'BITS_sd.txt') }
       Despues = { param($c) [void](Ejecutar-Esquiva 'CJ-01' @{ Reparar = $true; CarpetaCopia = (Join-Path $c 'esquiva_CJ-01') }); [void](Ejecutar-Esquiva 'CJ-36' @{ Reparar = $true; CarpetaCopia = (Join-Path $c 'esquiva_CJ-36') }) } }
    @{ Id = 'MS_PRINTER'; Paquete = 'Printer'; Nombre = 'Solucionador de impresoras (Microsoft)'; Rel = 'IMPRESION'
       Trampas = 'Rojos: RS_CancelAllJobs, RS_DeletePrintJobs, RS_ProcessPrinterjobs. Callejones: borra los trabajos de todos (CJ-19), Spooler y escaner a automatico con nombre fijo (CJ-18).'
       Antes = { param($c) Copiar-Carpeta "$env:windir\System32\spool\PRINTERS" (Join-Path $c 'trabajos_en_cola'); [void](Copiar-Registro 'HKLM\SYSTEM\CurrentControlSet\Services\Spooler' $c 'Spooler'); [void](Copiar-Registro 'HKLM\SYSTEM\CurrentControlSet\Services\StiSvc' $c 'StiSvc') }
       Despues = { param($c) [void](Ejecutar-Esquiva 'CJ-18' @{ Reparar = $true; CarpetaCopia = (Join-Path $c 'esquiva_CJ-18') }) } }
    @{ Id = 'MS_AUDIO'; Paquete = 'Audio'; Nombre = 'Solucionador de sonido (Microsoft)'; Rel = 'AUDIO'
       Trampas = 'Rojos: RS_APOLoadFailure, RS_HDAudioDriver, RS_NotDefault. Callejones: corta el sonido 20 s (CJ-22), cambia el dispositivo predeterminado (CJ-23), reactiva lo deshabilitado (CJ-24).'
       Antes = { param($c) [void](Copiar-Registro 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio' $c 'MMDevices_Audio'); [void](Copiar-Registro 'HKLM\SYSTEM\CurrentControlSet\Services\AudioSrv' $c 'AudioSrv') }
       Despues = { param($c) [void](Ejecutar-Esquiva 'CJ-22' @{ Reparar = $true; CarpetaCopia = (Join-Path $c 'esquiva_CJ-22') }) } }
    @{ Id = 'MS_NETWORK'; Paquete = 'Networking'; Nombre = 'Diagnostico de red de Windows (Microsoft)'; Rel = 'RED'
       Trampas = 'Rojo: NetworkDiagnosticsResolve. Callejon CJ-41: el informe puede decir que hubo un error sin haberlo; se vuelve a medir la red al terminar.'
       Antes = { param($c) Get-NetIPConfiguration -Detailed | Out-String | Set-Content (Join-Path $c 'ip_antes.txt') -Encoding UTF8 }
       Despues = { param($c) } }
    @{ Id = 'MS_SEARCH'; Paquete = 'Search'; Nombre = 'Solucionador de busqueda e indizacion (Microsoft)'; Rel = 'BUSQUEDA'
       Trampas = 'Rojos: RS_ResetWindowsSearchApp, RS_RestorePermissions. Callejones: vacia el indice (CJ-15), pierde los permisos anadidos de la carpeta del indice (CJ-35), borra la cache de la app de busqueda (CJ-34).'
       Antes = { param($c) [void](Copiar-Registro 'HKLM\SOFTWARE\Microsoft\Windows Search' $c 'Windows_Search'); $d = "$env:ProgramData\Microsoft\Search\Data"; [void](Ejecutar-Nativo "$env:windir\System32\icacls.exe" ("`"{0}`" /save `"{1}`" /t /c /q" -f $d, (Join-Path $c 'permisos_indice.acl')) 600) }
       Despues = { param($c) Log "  Si se perdieron permisos del indice: icacls `"$env:ProgramData\Microsoft\Search`" /restore `"$c\permisos_indice.acl`"" 'aviso' } }
    @{ Id = 'MS_MAINT'; Paquete = 'Maintenance'; Nombre = 'Mantenimiento del sistema (Microsoft)'; Rel = 'ESPACIO'
       Trampas = 'Rojos: RS_MachineWERQueue, RS_UserWERQueue, RS_AdminDiagnosticHistory, RS_UserDiagnosticHistory. Callejon CJ-12: borra informes de errores e historiales sin copia.'
       Antes = { param($c) Copiar-Carpeta "$env:ProgramData\Microsoft\Windows\WER" (Join-Path $c 'WER_equipo'); Copiar-Carpeta "$env:LOCALAPPDATA\Microsoft\Windows\WER" (Join-Path $c 'WER_usuario'); Copiar-Carpeta "$env:LOCALAPPDATA\Diagnostics" (Join-Path $c 'historial_diagnostico') }
       Despues = { param($c) } }
    @{ Id = 'MS_DEVICE'; Paquete = 'Device'; Nombre = 'Solucionador de hardware y dispositivos (Microsoft)'; Rel = 'DISPOSITIVOS'
       Trampas = 'Rojo: RS_DeviceDriverNeedsUpdate. Callejones: cambia la directiva de descarga de controladores (CJ-26), no mira el dispositivo elegido (CJ-27).'
       Antes = { param($c) [void](Copiar-Registro 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching' $c 'DriverSearching'); Get-PnpDevice | Select-Object InstanceId, Status, ConfigManagerErrorCode, FriendlyName | Export-Csv (Join-Path $c 'dispositivos_antes.csv') -NoTypeInformation -Encoding UTF8 }
       Despues = { param($c) } }
    @{ Id = 'MS_APPS'; Paquete = 'Apps'; Nombre = 'Solucionador de aplicaciones de la Tienda (Microsoft)'; Rel = 'APPS', 'UAC'
       Trampas = 'Rojo: RS_UAC. Callejon CJ-09: devuelve UAC a fabrica a ciegas; CJ-32: cambia la ruta de la cache de Internet.'
       Antes = { param($c) [void](Copiar-Registro 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' $c 'Policies_System'); [void](Copiar-Registro 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' $c 'User_Shell_Folders') }
       Despues = { param($c) } }
    @{ Id = 'MS_POWER'; Paquete = 'Power'; Nombre = 'Solucionador de energia (Microsoft)'; Rel = @()
       Trampas = 'Naranjas: RS_Balanced, RS_DisableScreensaver, RS_ResetIdle*. Callejones: cambia el plan y los tiempos (CJ-11), quita el protector de pantalla (CJ-39).'
       Antes = { param($c) [void](Ejecutar-Nativo "$env:windir\System32\powercfg.exe" ("/export `"{0}`" scheme_current" -f (Join-Path $c 'plan_actual.pow')) 60); [void](Copiar-Registro 'HKCU\Control Panel\Desktop' $c 'Desktop') }
       Despues = { param($c) Log "  Para volver al plan anterior: powercfg /import `"$c\plan_actual.pow`"" 'aviso' } }
    @{ Id = 'MS_BLUETOOTH'; Paquete = 'Bluetooth'; Nombre = 'Solucionador de Bluetooth (Microsoft)'; Rel = @()
       Trampas = 'Rojos: RS_DriverProblem, CL_Utility. Callejon CJ-14: "restablecer" quita el adaptador y puede no volver; CJ-44: siempre dice radio apagada.'
       Antes = { param($c) Get-PnpDevice -Class Bluetooth -ErrorAction SilentlyContinue | Select-Object InstanceId, Status, FriendlyName | Export-Csv (Join-Path $c 'bluetooth_antes.csv') -NoTypeInformation -Encoding UTF8 }
       Despues = { param($c) } }
    @{ Id = 'MS_VIDEO'; Paquete = 'Video'; Nombre = 'Solucionador de reproduccion de video (Microsoft)'; Rel = @()
       Trampas = 'Rojo: CL_MutexVerifiers. Callejon CJ-42: no avisa del controlador basico en Windows no ingles; borra un valor de audio protegido sin copia.'
       Antes = { param($c) [void](Copiar-Registro 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Audio' $c 'Audio') }
       Despues = { param($c) } }
)

$o = -100   # delante de todo lo demas
foreach ($p in $Global:RWPaquetesMS) {
    $def = $p
    if (-not (Test-Path "$env:windir\diagnostics\system\$($def.Paquete)")) { continue }   # este Windows no trae ese solucionador
    Registrar-Modulo @{
        Id = $def.Id; Orden = $o; Grupo = 'Solucionadores de Microsoft (rojos y naranjas)'; Nombre = $def.Nombre; Vinculados = @($def.Rel)
        Descripcion = "Ejecuta el solucionador REAL de Microsoft y aplica sus reparaciones. $($def.Trampas) Red de seguridad: copia previa y esquivas despues."
        Diagnosticar = ([scriptblock]::Create(@"
`$pk = Get-TroubleshootingPack -Path "`$env:windir\diagnostics\system\$($def.Paquete)" -ErrorAction Stop
`$n = (@(`$pk.RootCauses) | ForEach-Object { @(`$_.Resolutions).Count } | Measure-Object -Sum).Sum
Resultado 'Gris' ("Listo: {0} causas y {1} reparaciones de Microsoft. Se marca solo si sus areas salen mal; puedes marcarlo a mano." -f @(`$pk.RootCauses).Count, `$n) @(`$pk.RootCauses | ForEach-Object { '{0}: {1}' -f `$_.Id, `$_.Name })
"@))
        Reparar = ([scriptblock]::Create(@"
param(`$ctx)
`$def = `$Global:RWPaquetesMS | Where-Object Id -eq '$($def.Id)'
`$c = Carpeta-Copia '$($def.Id)'
Log '  RED DE SEGURIDAD (antes): copia de lo que este solucionador cambia o borra...'
try { & `$def.Antes `$c } catch { Log ('  Copia previa incompleta: ' + `$_.Exception.Message) 'aviso' }
`$r = Ejecutar-PaqueteMS '$($def.Paquete)' `$c
Log '  RED DE SEGURIDAD (despues): deshacer el dano conocido de este solucionador...'
try { & `$def.Despues `$c } catch { Log ('  Esquiva posterior: ' + `$_.Exception.Message) 'aviso' }
`$r
"@))
        VerificaAlReparar = $true
    }
    $o++
}
