# Red: diagnostico capa a capa (adaptador, IP, puerta de enlace, DNS, HTTPS) y reparaciones por niveles.

function Global:Probar-Tcp([string]$Equipo, [int]$Puerto, [int]$Ms = 3000) {
    $c = New-Object Net.Sockets.TcpClient
    try { $a = $c.BeginConnect($Equipo, $Puerto, $null, $null); if (-not $a.AsyncWaitHandle.WaitOne($Ms)) { return $false }; $c.EndConnect($a); return $true } catch { return $false } finally { $c.Close() }
}

function Global:Diagnostico-Red {
    $d = @(); $fallo = $null
    $ad = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up')
    $d += 'Adaptadores fisicos conectados: ' + $(if ($ad) { ($ad | ForEach-Object { "$($_.Name) ($($_.LinkSpeed))" }) -join ', ' } else { 'NINGUNO' })
    if (-not $ad) { $fallo = 'ningun adaptador de red fisico conectado (cable, Wi-Fi o controlador)' }
    $cfg = @(Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object { $_.NetAdapter.Status -eq 'Up' })
    $ips = @($cfg | ForEach-Object { $_.IPv4Address.IPAddress } | Where-Object { $_ })
    $d += 'IPv4: ' + $(if ($ips) { $ips -join ', ' } else { 'ninguna' })
    $apipa = @($ips | Where-Object { $_ -like '169.254.*' })
    if (-not $fallo -and $ips.Count -eq 0) { $fallo = 'sin direccion IPv4' }
    if (-not $fallo -and $apipa.Count -eq $ips.Count) { $fallo = 'solo hay direccion 169.254.x.x: el servidor DHCP no respondio' }
    $gw = @($cfg | ForEach-Object { $_.IPv4DefaultGateway.NextHop } | Where-Object { $_ } | Select-Object -Unique)
    $d += 'Puerta de enlace: ' + $(if ($gw) { $gw -join ', ' } else { 'ninguna' })
    if (-not $fallo -and -not $gw) { $fallo = 'sin puerta de enlace' }
    if ($gw) { $p = Test-Connection -ComputerName $gw[0] -Count 2 -Quiet -ErrorAction SilentlyContinue; $d += "Respuesta de la puerta de enlace (ping): $p (algunos routers no responden al ping)" }
    $dns = $null; try { $dns = @(Resolve-DnsName 'www.microsoft.com' -Type A -QuickTimeout -ErrorAction Stop | Where-Object IPAddress) } catch { }
    $srv = @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object ServerAddresses | Select-Object -Unique)
    $d += 'Servidores DNS: ' + $(if ($srv) { $srv -join ', ' } else { 'ninguno' }) + ' | resolucion de www.microsoft.com: ' + $(if ($dns) { 'correcta' } else { 'FALLA' })
    if (-not $fallo -and -not $dns) { $fallo = 'el DNS no resuelve nombres' }
    $https = Probar-Tcp 'www.microsoft.com' 443
    $d += "Conexion HTTPS a www.microsoft.com:443: $https"
    if (-not $fallo -and -not $https) { $fallo = 'el DNS resuelve pero no hay conexion HTTPS (cortafuegos, proxy o bloqueo)' }
    $px = (Ejecutar-Nativo "$env:windir\System32\netsh.exe" 'winhttp show proxy' 30).Salida | Where-Object { $_ -match ':' } | Select-Object -Last 2
    $d += 'Proxy WinHTTP (el que usan Windows Update y los servicios): ' + ($px -join ' ')
    $ie = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
    $d += 'Proxy del usuario: ' + $(if ($ie.ProxyEnable -eq 1) { "ACTIVADO -> $($ie.ProxyServer)" } else { 'desactivado' })
    return [pscustomobject]@{ Fallo = $fallo; Detalle = $d; Apipa = ($ips.Count -gt 0 -and $apipa.Count -eq $ips.Count) }
}

Registrar-Modulo @{
    Id = 'RED'; Orden = 30; Grupo = 'Red'; Nombre = 'Conexion a Internet'
    Descripcion = 'Adaptador, direccion IP, puerta de enlace, DNS y HTTPS. Reparacion basica: vaciar la cache DNS y pedir de nuevo la direccion si no hay ninguna valida.'
    Diagnosticar = {
        $r = Diagnostico-Red
        if ($r.Fallo) { return (Resultado 'Rojo' ('La red falla en: ' + $r.Fallo) $r.Detalle) }
        return (Resultado 'Verde' 'La red funciona: IP, puerta de enlace, DNS y HTTPS correctos.' $r.Detalle)
    }
    Reparar = {
        param($ctx)
        $r0 = Diagnostico-Red
        Log '  ipconfig /flushdns (vacia la cache de nombres; no corta la conexion)'
        $x = Ejecutar-Nativo "$env:windir\System32\ipconfig.exe" '/flushdns' 60; Log ('  codigo ' + $x.Codigo)
        if ($r0.Apipa) {
            Log '  Sin direccion valida (169.254.x.x): se pide de nuevo al DHCP (ipconfig /renew)...'
            $x = Ejecutar-Nativo "$env:windir\System32\ipconfig.exe" '/renew' 120; Log ('  codigo ' + $x.Codigo)
        }
    }
}

Registrar-Modulo @{
    Id = 'RED_RESET'; Orden = 31; Grupo = 'Red'; Nombre = 'Reinicio de Winsock y TCP/IP (avanzado)'; Avanzado = $true; Reinicio = $true
    Descripcion = 'Ultimo recurso cuando la red falla con el adaptador bien: devuelve Winsock y TCP/IP a su estado de fabrica. Borra IP fija y LSP de terceros (VPN, antivirus antiguos). Exige reiniciar.'
    Diagnosticar = {
        $r = Diagnostico-Red
        $lsp = (Ejecutar-Nativo "$env:windir\System32\netsh.exe" 'winsock show catalog' 60).Salida | Where-Object { $_ -match 'Description|Descripci' }
        $terceros = @($lsp | Where-Object { $_ -notmatch 'MSAFD|Hyper-V|RSVP|VMCI' })
        $d = $r.Detalle + @("Proveedores Winsock: $(@($lsp).Count) (de terceros: $($terceros.Count))") + $terceros
        if ($r.Fallo -and $r.Fallo -notmatch 'adaptador') { return (Resultado 'Amarillo' ('La red falla (' + $r.Fallo + '). Si la reparacion basica no basta, este reinicio es el siguiente paso.') $d) }
        return (Resultado 'Verde' 'No hace falta: la red funciona o el fallo es del adaptador.' $d)
    }
    Reparar = {
        param($ctx)
        $c = Carpeta-Copia 'RED_RESET'
        (Ejecutar-Nativo "$env:windir\System32\netsh.exe" 'winsock show catalog' 60).Salida | Set-Content (Join-Path $c 'winsock_catalogo_antes.txt') -Encoding UTF8
        Get-NetIPConfiguration -Detailed | Out-String | Set-Content (Join-Path $c 'ip_antes.txt') -Encoding UTF8
        Get-NetIPAddress | Where-Object PrefixOrigin -eq 'Manual' | Format-List * | Out-String | Set-Content (Join-Path $c 'ip_fijas_antes.txt') -Encoding UTF8
        Log "  Configuracion de red anterior guardada en $c (incluidas las IP fijas, para volver a ponerlas)"
        $a = Ejecutar-Nativo "$env:windir\System32\netsh.exe" 'winsock reset' 120; Log ('  netsh winsock reset: codigo ' + $a.Codigo)
        $b = Ejecutar-Nativo "$env:windir\System32\netsh.exe" ('int ip reset "{0}"' -f (Join-Path $c 'netsh_ip_reset.log')) 120; Log ('  netsh int ip reset: codigo ' + $b.Codigo)
        if ($a.Codigo -eq 0 -and $b.Codigo -eq 0) { return (Resultado 'Amarillo' 'Winsock y TCP/IP reiniciados. REINICIA el equipo para que surta efecto y vuelve a diagnosticar.' @($a.Salida + $b.Salida)) }
        return (Resultado 'Rojo' "El reinicio no termino bien (winsock $($a.Codigo), ip $($b.Codigo))." @($a.Salida + $b.Salida))
    }
    VerificaAlReparar = $true
}
