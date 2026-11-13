# Windows Update: servicios, BITS, almacen de datos, AppData del perfil del sistema y hora.
# Las reparaciones usan los scripts de esquiva probados en el laboratorio (carpeta Esquivas, callejones CJ-xx).

Registrar-Modulo @{
    Id = 'WU_SERVICIOS'; Orden = 20; Grupo = 'Windows Update'; Nombre = 'Servicios de Windows Update'
    Descripcion = 'CryptSvc, BITS, wuauserv y los que dependen de ellos. Arranca solo lo parado, sin cambiar tipos de inicio (CJ-05).'
    Diagnosticar = { Resultado-Esquiva (Ejecutar-Esquiva 'CJ-05' @{} -Silencioso) 'No hace falta cambiar nada' 'Servicios de Windows Update' }
    Reparar = { param($ctx) [void](Ejecutar-Esquiva 'CJ-05' @{ Reparar = $true; CarpetaCopia = (Carpeta-Copia 'WU_SERVICIOS') }) }
}

Registrar-Modulo @{
    Id = 'BITS'; Orden = 21; Grupo = 'Windows Update'; Nombre = 'BITS (transferencias en segundo plano)'
    Descripcion = 'Permisos de BITS en el registro (CJ-01) y descriptor de seguridad del servicio (CJ-36). Sin BITS no se descargan actualizaciones.'
    Diagnosticar = {
        $a = Resultado-Esquiva (Ejecutar-Esquiva 'CJ-01' @{} -Silencioso) 'No hace falta cambiar nada' 'BITS'
        $b = Resultado-Esquiva (Ejecutar-Esquiva 'CJ-36' @{} -Silencioso) 'No hace falta cambiar nada' 'Descriptor de BITS'
        $e = if ($a.Estado -eq 'Verde' -and $b.Estado -eq 'Verde') { 'Verde' } elseif ($a.Estado -eq 'Rojo' -or $b.Estado -eq 'Rojo') { 'Rojo' } else { 'Amarillo' }
        Resultado $e ("Registro: {0} | Servicio: {1}" -f $a.Resumen, $b.Resumen) (@('--- registro (CJ-01) ---') + $a.Detalle + @('--- descriptor del servicio (CJ-36) ---') + $b.Detalle)
    }
    Reparar = {
        param($ctx)
        Log '  Permisos de BITS en el registro (CJ-01)...'
        [void](Ejecutar-Esquiva 'CJ-01' @{ Reparar = $true; CarpetaCopia = (Carpeta-Copia 'BITS_registro') })
        Log '  Descriptor de seguridad del servicio BITS (CJ-36)...'
        [void](Ejecutar-Esquiva 'CJ-36' @{ Reparar = $true; CarpetaCopia = (Carpeta-Copia 'BITS_servicio') })
    }
}

Registrar-Modulo @{
    Id = 'WU_CACHE'; Orden = 22; Grupo = 'Windows Update'; Nombre = 'Errores de instalacion y almacen de Windows Update'
    Descripcion = 'Mira los fallos de instalacion de los ultimos 30 dias. La reparacion reinicia el almacen RENOMBRANDO SoftwareDistribution, sin borrar historial ni cache (CJ-07).'
    Diagnosticar = {
        $desde = (Get-Date).AddDays(-30)
        # despues de reiniciar el almacen (SoftwareDistribution nueva) solo cuentan los fallos posteriores
        $sdNueva = (Get-Item "$env:windir\SoftwareDistribution" -ErrorAction SilentlyContinue).CreationTime
        if ($sdNueva -and $sdNueva -gt $desde) { $desde = $sdNueva }
        $fallos = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WindowsUpdateClient'; Id = 20; StartTime = $desde } -ErrorAction SilentlyContinue)
        $bien = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WindowsUpdateClient'; Id = 19; StartTime = $desde } -ErrorAction SilentlyContinue)
        $d = @(('Instalaciones correctas en 30 dias: {0} | fallidas: {1}' -f $bien.Count, $fallos.Count))
        $d += @($fallos | Select-Object -First 8 | ForEach-Object { '{0:dd/MM HH:mm}  {1}' -f $_.TimeCreated, (($_.Message -split "`r?`n")[0]) })
        $sd = "$env:windir\SoftwareDistribution"
        if (Test-Path $sd) { $tam = (Get-ChildItem "$sd\DataStore" -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum; $d += ('DataStore: {0:N0} MB' -f ($tam / 1MB)) } else { $d += 'SoftwareDistribution no existe (Windows Update la crea al arrancar)' }
        # la misma actualizacion fallando una y otra vez es la senal clasica de almacen o descarga danados
        $repetidas = @($fallos | ForEach-Object { if ($_.Message -match '(KB\d+)') { $Matches[1] } } | Group-Object | Where-Object Count -ge 2)
        if ($repetidas.Count) { return (Resultado 'Rojo' ('Actualizaciones que fallan una y otra vez: ' + (($repetidas | ForEach-Object { "$($_.Name) ($($_.Count) veces)" }) -join ', ')) $d) }
        if ($fallos.Count) { return (Resultado 'Amarillo' "$($fallos.Count) instalacion(es) fallida(s) en 30 dias." $d) }
        return (Resultado 'Verde' 'Sin fallos de instalacion en los ultimos 30 dias.' $d)
    }
    Reparar = { param($ctx) [void](Ejecutar-Esquiva 'CJ-07' @{ Reparar = $true; Forzar = $true; CarpetaCopia = (Carpeta-Copia 'WU_CACHE') }) }
}

Registrar-Modulo @{
    Id = 'WU_APPDATA'; Orden = 23; Grupo = 'Windows Update'; Nombre = 'AppData del perfil del sistema'
    Descripcion = 'Valor AppData de HKU\.DEFAULT: debe ser %USERPROFILE%\AppData\Roaming como REG_EXPAND_SZ (CJ-38).'
    Diagnosticar = { Resultado-Esquiva (Ejecutar-Esquiva 'CJ-38' @{} -Silencioso) 'no hay nada que cambiar' 'AppData' }
    Reparar = { param($ctx) [void](Ejecutar-Esquiva 'CJ-38' @{ Reparar = $true; CarpetaCopia = (Carpeta-Copia 'WU_APPDATA') }) }
}

Registrar-Modulo @{
    Id = 'HORA'; Orden = 24; Grupo = 'Windows Update'; Nombre = 'Hora del equipo'
    Descripcion = 'Con la hora desfasada fallan Windows Update, los certificados y el inicio de sesion. Mide contra el servidor configurado y sincroniza sin cambiar el servicio (CJ-20).'
    Diagnosticar = { Resultado-Esquiva (Ejecutar-Esquiva 'CJ-20' @{ ConsultarServidor = $true } -Silencioso) 'la hora esta bien' 'Hora' }
    Reparar = { param($ctx) [void](Ejecutar-Esquiva 'CJ-20' @{ Reparar = $true; CarpetaCopia = (Carpeta-Copia 'HORA') }) }
}
