<#
.SYNOPSIS
    Esquiva el callejon de TS_LowVolume.ps1, TS_NotDefault.ps1 y TS_Mute.ps1: diagnostico de audio de solo
    lectura que comprueba primero que el dispositivo EXISTE y que dice «no se pudo mirar» cuando no puede mirar.
.DESCRIPTION
    Por defecto SOLO COMPRUEBA y no cambia nada:
      - Servicios AudioEndpointBuilder y Audiosrv (si no estan en marcha, no se puede leer el volumen).
      - Dispositivos de sonido (Win32_SoundDevice y Get-PnpDevice -Class MEDIA) y su codigo de problema.
      - Extremos de audio (altavoces, microfonos) leidos con la API de audio de Windows (MMDevice) por COM,
        sin la DLL del solucionador: estado, volumen, silencio y para que funciones es el predeterminado.
      - Con -DeviceId comprueba solo ese extremo. Si no existe lo dice y NO da ningun otro diagnostico
        sobre el (TS_LowVolume y TS_NotDefault daban «volumen bajo» y «no predeterminado» de uno inventado).
      - Si una lectura falla, el veredicto es «NO SE PUDO MIRAR», nunca «sin problema» (TS_Mute daba
        «sin silencio» cuando no podia cargar su DLL).
    Con -Reparar (sobre el extremo de -DeviceId o, si no se da, sobre el altavoz predeterminado):
      - Guarda antes volumen, silencio y predeterminados en un JSON de copia.
      - Quita el silencio si esta silenciado; sube el volumen a -Volumen si esta en el 10 % o menos.
      - Solo con -HacerPredeterminado lo pone como predeterminado (consola, multimedia y comunicaciones).
      - No toca nada que no haya podido leer, ni dispositivos deshabilitados (ver CJ-24), ni servicios (CJ-17/CJ-22).
      - Al final vuelve a leerlo todo y dice si se ha conseguido.
.EXAMPLE
    .\2_esquivar.ps1
    Diagnostico de todos los extremos activos.
.EXAMPLE
    .\2_esquivar.ps1 -DeviceId '{0.0.0.00000000}.{1c50284b-4d6f-4ba3-a49e-c6db9ee2ef59}'
    Diagnostico de un extremo concreto (el identificador que usa el solucionador de audio).
.EXAMPLE
    .\2_esquivar.ps1 -Reparar
    Quita el silencio y sube el volumen del altavoz predeterminado si hace falta.
.NOTES
    Libro «Lo que Microsoft no explica» - callejon CJ-25: diagnostico de audio falso en las dos direcciones.
    Windows PowerShell 5.1 de 64 bits. -Reparar no necesita ser administrador (volumen y silencio son del usuario),
    pero -HacerPredeterminado usa la misma interfaz que el panel Sonido (IPolicyConfig, no documentada).
#>
[CmdletBinding()]
param(
    [string]$DeviceId,
    [switch]$Reparar,
    [ValidateRange(11, 100)][int]$Volumen = 50,
    [switch]$HacerPredeterminado,
    [string]$CarpetaCopia = ("$env:SystemDrive\Copias_Audio\" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
)

$ErrorActionPreference = 'Stop'
$informe = New-Object System.Collections.ArrayList
function Nota($texto, $color = 'Gray') { [void]$informe.Add($texto); Write-Host $texto -ForegroundColor $color }
if (-not [Environment]::Is64BitProcess) { throw 'Usa Windows PowerShell de 64 bits ([Environment]::Is64BitProcess debe ser True).' }
if ($HacerPredeterminado -and -not $Reparar) { throw '-HacerPredeterminado cambia el sistema: usalo junto con -Reparar.' }

$FuenteCore = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
namespace EsqAudio
{
    // Core Audio (MMDevice API) por COM, sin la DLL del solucionador.
    [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator
    {
        [PreserveSig] int EnumAudioEndpoints(int dataFlow, int stateMask, out IMMDeviceCollection devices);
        [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice endpoint);
        [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
    }
    [Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceCollection
    {
        [PreserveSig] int GetCount(out int count);
        [PreserveSig] int Item(int index, out IMMDevice device);
    }
    [Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice
    {
        [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
        [PreserveSig] int OpenPropertyStore(int access, out IntPtr store);
        [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetState(out int state);
    }
    [Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioEndpointVolume
    {
        [PreserveSig] int RegisterControlChangeNotify(IntPtr p);
        [PreserveSig] int UnregisterControlChangeNotify(IntPtr p);
        [PreserveSig] int GetChannelCount(out int n);
        [PreserveSig] int SetMasterVolumeLevel(float db, ref Guid ctx);
        [PreserveSig] int SetMasterVolumeLevelScalar(float level, ref Guid ctx);
        [PreserveSig] int GetMasterVolumeLevel(out float db);
        [PreserveSig] int GetMasterVolumeLevelScalar(out float level);
        [PreserveSig] int SetChannelVolumeLevel(int ch, float db, ref Guid ctx);
        [PreserveSig] int SetChannelVolumeLevelScalar(int ch, float level, ref Guid ctx);
        [PreserveSig] int GetChannelVolumeLevel(int ch, out float db);
        [PreserveSig] int GetChannelVolumeLevelScalar(int ch, out float level);
        [PreserveSig] int SetMute([MarshalAs(UnmanagedType.Bool)] bool mute, ref Guid ctx);
        [PreserveSig] int GetMute([MarshalAs(UnmanagedType.Bool)] out bool mute);
    }
    // IPolicyConfig: interfaz no documentada que usa el panel Sonido (mmsys.cpl) para el predeterminado y para habilitar.
    [Guid("f8679f50-850a-41cf-9c72-430f290290c8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPolicyConfig
    {
        [PreserveSig] int GetMixFormat(string id, IntPtr f);
        [PreserveSig] int GetDeviceFormat(string id, int def, IntPtr f);
        [PreserveSig] int ResetDeviceFormat(string id);
        [PreserveSig] int SetDeviceFormat(string id, IntPtr f1, IntPtr f2);
        [PreserveSig] int GetProcessingPeriod(string id, int def, IntPtr a, IntPtr b);
        [PreserveSig] int SetProcessingPeriod(string id, IntPtr a);
        [PreserveSig] int GetShareMode(string id, IntPtr m);
        [PreserveSig] int SetShareMode(string id, IntPtr m);
        [PreserveSig] int GetPropertyValue(string id, IntPtr k, IntPtr v);
        [PreserveSig] int SetPropertyValue(string id, IntPtr k, IntPtr v);
        [PreserveSig] int SetDefaultEndpoint([MarshalAs(UnmanagedType.LPWStr)] string id, int role);
        [PreserveSig] int SetEndpointVisibility([MarshalAs(UnmanagedType.LPWStr)] string id, [MarshalAs(UnmanagedType.Bool)] bool visible);
    }
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumeratorCom { }
    [ComImport, Guid("870af99c-171d-4f9e-af0d-e63df40c2bc9")] class PolicyConfigCom { }

    public class Extremo { public string Id; public int Flujo; public int Estado; }

    public static class Core
    {
        // Flujo: 0 = reproduccion (Render), 1 = captura (Capture). Rol: 0 consola, 1 multimedia, 2 comunicaciones.
        // Estado: 1 activo, 2 deshabilitado, 4 no presente, 8 desenchufado.
        static IMMDeviceEnumerator En() { return (IMMDeviceEnumerator)(new MMDeviceEnumeratorCom()); }

        public static List<Extremo> Listar()
        {
            List<Extremo> r = new List<Extremo>();
            IMMDeviceEnumerator en = En();
            for (int f = 0; f <= 1; f++)
            {
                IMMDeviceCollection c;
                if (en.EnumAudioEndpoints(f, 0xF, out c) != 0) continue;
                int n; c.GetCount(out n);
                for (int i = 0; i < n; i++)
                {
                    IMMDevice d; if (c.Item(i, out d) != 0) continue;
                    Extremo e = new Extremo(); e.Flujo = f;
                    d.GetId(out e.Id); d.GetState(out e.Estado);
                    r.Add(e);
                }
            }
            return r;
        }
        // Devuelve null si no hay predeterminado (E_NOTFOUND).
        public static string Predeterminado(int flujo, int rol)
        {
            IMMDevice d;
            if (En().GetDefaultAudioEndpoint(flujo, rol, out d) != 0 || d == null) return null;
            string id; d.GetId(out id); return id;
        }
        // Estado del extremo; -1 si el identificador no existe.
        public static int Estado(string id)
        {
            IMMDevice d;
            if (En().GetDevice(id, out d) != 0 || d == null) return -1;
            int s; if (d.GetState(out s) != 0) return -1; return s;
        }
        static IAudioEndpointVolume Vol(string id)
        {
            IMMDevice d;
            int hr = En().GetDevice(id, out d);
            if (hr != 0 || d == null) throw new COMException("El extremo no existe", hr);
            Guid iid = typeof(IAudioEndpointVolume).GUID; object o;
            hr = d.Activate(ref iid, 23, IntPtr.Zero, out o);
            if (hr != 0) throw new COMException("No se pudo abrir el volumen del extremo", hr);
            return (IAudioEndpointVolume)o;
        }
        // Volumen 0-100. Lanza excepcion si no se puede leer (nunca devuelve un valor inventado).
        public static int Volumen(string id)
        {
            float v; int hr = Vol(id).GetMasterVolumeLevelScalar(out v);
            if (hr != 0) throw new COMException("No se pudo leer el volumen", hr);
            return (int)Math.Round(v * 100);
        }
        public static bool Silenciado(string id)
        {
            bool m; int hr = Vol(id).GetMute(out m);
            if (hr != 0) throw new COMException("No se pudo leer el silencio", hr);
            return m;
        }
        public static int PonerVolumen(string id, int porcentaje) { Guid g = Guid.Empty; return Vol(id).SetMasterVolumeLevelScalar(porcentaje / 100.0f, ref g); }
        public static int PonerSilencio(string id, bool silencio) { Guid g = Guid.Empty; return Vol(id).SetMute(silencio, ref g); }
        public static int PonerPredeterminado(string id, int rol) { return ((IPolicyConfig)(new PolicyConfigCom())).SetDefaultEndpoint(id, rol); }
        public static int PonerVisible(string id, bool visible) { return ((IPolicyConfig)(new PolicyConfigCom())).SetEndpointVisibility(id, visible); }
    }
}
'@
if (-not ('EsqAudio.Core' -as [type])) { Add-Type -TypeDefinition $FuenteCore }

$MM = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio'
$Roles = @('consola', 'multimedia', 'comunicaciones')
function Nombre-Extremo([string]$Id) {
    $flujo = $(if ($Id -like '{0.0.0.*') { 'Render' } else { 'Capture' })
    $i = $Id.IndexOf('}.'); if ($i -lt 0) { return '(identificador no valido)' }
    $p = Get-ItemProperty -LiteralPath ('{0}\{1}\{2}\Properties' -f $MM, $flujo, $Id.Substring($i + 2)) -ErrorAction SilentlyContinue
    if (-not $p) { return '(sin nombre en el registro)' }
    $a = $p.'{a45c254e-df1c-4efd-8020-67d146a850e0},2'; $b = $p.'{b3f8fa53-0004-438e-9003-51a46e139bfc},6'
    if ($b) { return "$a ($b)" } else { return "$a" }
}
function Texto-Estado([int]$e) { switch ($e) { 1 { 'activo' } 2 { 'DESHABILITADO' } 4 { 'no presente' } 8 { 'desenchufado' } -1 { 'NO EXISTE' } default { "estado $e" } } }
function Leer-Extremo([string]$Id) {
    # Devuelve lo que se pudo leer; lo que no, queda en $null con el motivo en Fallo.
    $r = [ordered]@{ Id = $Id; Nombre = (Nombre-Extremo $Id); Estado = [EsqAudio.Core]::Estado($Id); Volumen = $null; Silencio = $null; Roles = @(); Fallo = '' }
    if ($r.Estado -eq 1) {
        try { $r.Volumen = [EsqAudio.Core]::Volumen($Id) } catch { $r.Fallo += 'volumen: ' + $_.Exception.GetBaseException().Message + '. ' }
        try { $r.Silencio = [EsqAudio.Core]::Silenciado($Id) } catch { $r.Fallo += 'silencio: ' + $_.Exception.GetBaseException().Message + '. ' }
    }
    $f = $(if ($Id -like '{0.0.0.*') { 0 } else { 1 })
    $r.Roles = @(0, 1, 2 | Where-Object { [EsqAudio.Core]::Predeterminado($f, $_) -eq $Id } | ForEach-Object { $Roles[$_] })
    return [pscustomobject]$r
}
function Veredicto($x, [bool]$elegido) {
    $v = @()
    if ($x.Estado -eq -1) { return @('NO EXISTE: ningun diagnostico sobre este identificador es valido') }
    if ($x.Estado -ne 1) { return @(("{0}: no se puede mirar su volumen ni su silencio" -f (Texto-Estado $x.Estado))) }
    if ($null -eq $x.Volumen) { $v += 'volumen: NO SE PUDO MIRAR' } elseif ($x.Volumen -le 10) { $v += ("VOLUMEN BAJO ({0} %)" -f $x.Volumen) }
    if ($null -eq $x.Silencio) { $v += 'silencio: NO SE PUDO MIRAR' } elseif ($x.Silencio) { $v += 'SILENCIADO' }
    if ($elegido -and $x.Roles.Count -lt 3) { $v += ('no es el predeterminado en: ' + ((@($Roles) | Where-Object { $x.Roles -notcontains $_ }) -join ', ')) }
    return $v
}
function Mostrar($x, [bool]$elegido) {
    $vol = $(if ($null -ne $x.Volumen) { "$($x.Volumen) %" } else { '?' })
    $sil = $(if ($null -ne $x.Silencio) { "$($x.Silencio)" } else { '?' })
    $pre = $(if ($x.Roles.Count) { $x.Roles -join ',' } else { 'no' })
    Nota ("  {0}`n      {1} | {2} | volumen={3} silencio={4} predeterminado={5}" -f $x.Nombre, $x.Id, (Texto-Estado $x.Estado), $vol, $sil, $pre)
    $v = @(Veredicto $x $elegido)
    if ($v.Count) { $v | ForEach-Object { Nota "      -> $_" 'Yellow' } } else { Nota '      -> bien (comprobado, no supuesto)' 'Green' }
    if ($x.Fallo) { Nota "      (detalle: $($x.Fallo))" 'DarkYellow' }
    return $v
}

# ---------------------------------------------------------------- comprobacion
Nota '== Diagnostico de audio (solo lectura) ==' 'Cyan'
$problemas = @()
foreach ($n in 'AudioEndpointBuilder', 'Audiosrv') {
    $w = Get-CimInstance -ClassName Win32_Service -Filter ("Name='{0}'" -f $n) -ErrorAction SilentlyContinue
    if (-not $w) { Nota "  servicio $n NO EXISTE" 'Red'; $problemas += "servicio $n no existe"; continue }
    Nota ("  servicio {0,-21} inicio={1,-9} estado={2}" -f $n, $w.StartMode, $w.State)
    if ($w.State -ne 'Running') { $problemas += "servicio $n $($w.State) ($($w.StartMode)): sin el no hay sonido ni se puede leer el volumen (ver CJ-22 / CJ-17)" }
}
foreach ($d in @(Get-CimInstance -ClassName Win32_SoundDevice -ErrorAction SilentlyContinue)) {
    Nota ("  dispositivo de sonido: {0} | {1} | codigo {2} | {3}" -f $d.Name, $d.Status, $d.ConfigManagerErrorCode, $d.PNPDeviceID)
    if ($d.ConfigManagerErrorCode -ne 0) { $problemas += ("dispositivo {0} con codigo de problema {1} (22 = deshabilitado, ver CJ-24; otros: ver CJ-23)" -f $d.Name, $d.ConfigManagerErrorCode) }
}
$extremos = $null
try { $extremos = @([EsqAudio.Core]::Listar()) } catch { $problemas += ('NO SE PUDO MIRAR la lista de extremos de audio: ' + $_.Exception.GetBaseException().Message) }

$elegidoId = $null
$vistos = @()
if ($null -ne $extremos) {
    if ($DeviceId) {
        $x = Leer-Extremo $DeviceId
        Nota '== Extremo pedido ==' 'Cyan'
        $v = Mostrar $x $true
        $problemas += @($v | ForEach-Object { "$($x.Nombre): $_" })
        if ($x.Estado -eq 1) { $elegidoId = $DeviceId }
        $vistos += $x
    } else {
        Nota '== Extremos activos ==' 'Cyan'
        foreach ($e in @($extremos | Where-Object { $_.Estado -eq 1 })) {
            $x = Leer-Extremo $e.Id
            $v = Mostrar $x $false
            $problemas += @($v | ForEach-Object { "$($x.Nombre): $_" })
            $vistos += $x
        }
        foreach ($flujo in 0, 1) {
            $nom = $(if ($flujo -eq 0) { 'reproduccion' } else { 'grabacion' })
            if (@($extremos | Where-Object { $_.Flujo -eq $flujo -and $_.Estado -eq 1 }).Count -eq 0) { $problemas += "no hay ningun dispositivo de $nom activo" }
            elseif (-not [EsqAudio.Core]::Predeterminado($flujo, 0)) { $problemas += "no hay dispositivo de $nom predeterminado" }
        }
        $elegidoId = [EsqAudio.Core]::Predeterminado(0, 0)
        $desact = @($extremos | Where-Object { $_.Estado -eq 2 })
        if ($desact.Count) { Nota ("  Extremos deshabilitados (se respetan; ver CJ-24): {0}" -f (($desact | ForEach-Object { Nombre-Extremo $_.Id }) -join '; ')) 'DarkYellow' }
    }
}

if ($problemas.Count -eq 0) { Nota 'RESULTADO: audio comprobado: servicios en marcha, dispositivos sin problema, volumen y silencio leidos y correctos.' 'Green'; return }
Nota 'PROBLEMAS ENCONTRADOS (o cosas que no se pudieron mirar):' 'Yellow'; $problemas | ForEach-Object { Nota "  - $_" 'Yellow' }
if (-not $Reparar) {
    # la pista de -Reparar solo se da si hay algo que -Reparar sabe arreglar (no, p. ej., un dispositivo que NO EXISTE)
    $arreglables = @($problemas | Where-Object { $_ -match 'volumen|silencio|predeterminado' -and $_ -notmatch 'NO EXISTE|NO SE PUDO' })
    if ($arreglables.Count) { Nota 'Volumen bajo, silencio y predeterminado se pueden arreglar con -Reparar (y -HacerPredeterminado). Lo demas se indica arriba.' 'Yellow' }
    else { Nota 'RESULTADO: lo encontrado no se arregla con -Reparar; revisa lo indicado arriba. No se ha cambiado nada.' 'Yellow' }
    return
}

# ---------------------------------------------------------------- reparar el extremo elegido
if (-not $elegidoId) { Nota 'RESULTADO: no hay un extremo activo sobre el que actuar (o el pedido no existe). No se ha cambiado nada.' 'Red'; return }
$x0 = Leer-Extremo $elegidoId
$hacer = @()
if ($x0.Silencio -eq $true) { $hacer += 'silencio' }
if (($null -ne $x0.Volumen) -and ($x0.Volumen -le 10)) { $hacer += 'volumen' }
if ($HacerPredeterminado -and $x0.Roles.Count -lt 3) { $hacer += 'predeterminado' }
if ($hacer.Count -eq 0) { Nota ("RESULTADO: en {0} no hay nada que este en manos de este script (lo que no se pudo leer no se toca). Para actuar sobre otro extremo, usa -DeviceId." -f $x0.Nombre) 'Yellow'; return }

New-Item -ItemType Directory -Force $CarpetaCopia | Out-Null
$copia = [pscustomobject]@{ fecha = (Get-Date).ToString('s'); extremo = $x0
    predeterminados = @(foreach ($f in 0, 1) { foreach ($r in 0, 1, 2) { [pscustomobject]@{ flujo = $f; rol = $r; id = [EsqAudio.Core]::Predeterminado($f, $r) } } }) }
[IO.File]::WriteAllText((Join-Path $CarpetaCopia 'audio_antes.json'), ($copia | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($true)))
Nota "Copia (volumen, silencio y predeterminados de antes) en $CarpetaCopia\audio_antes.json" 'Cyan'
$fallos = @()
if ($hacer -contains 'silencio') { $hr = [EsqAudio.Core]::PonerSilencio($elegidoId, $false); if ($hr -ne 0) { $fallos += ('quitar silencio: 0x{0:X8}' -f $hr) } else { Nota 'Hecho: silencio quitado.' 'Green' } }
if ($hacer -contains 'volumen') { $hr = [EsqAudio.Core]::PonerVolumen($elegidoId, $Volumen); if ($hr -ne 0) { $fallos += ('volumen: 0x{0:X8}' -f $hr) } else { Nota ("Hecho: volumen de {0} % a {1} %." -f $x0.Volumen, $Volumen) 'Green' } }
if ($hacer -contains 'predeterminado') {
    foreach ($r in 0, 1, 2) { $hr = [EsqAudio.Core]::PonerPredeterminado($elegidoId, $r); if ($hr -ne 0) { $fallos += ('predeterminado ({0}): 0x{1:X8}' -f $Roles[$r], $hr) } }
    Nota 'Hecho: puesto como predeterminado (consola, multimedia, comunicaciones).' 'Green'
}
Start-Sleep -Milliseconds 500

Nota '== Despues ==' 'Cyan'
$x1 = Leer-Extremo $elegidoId
$v1 = @(Mostrar $x1 $HacerPredeterminado)
$ok = ($fallos.Count -eq 0) -and ($v1.Count -eq 0)
foreach ($f in $fallos) { Nota "  FALLO: $f" 'Red' }
if ($ok) { Nota ("RESULTADO: {0} activo, sin silencio y con volumen {1} %; comprobado despues de cambiarlo." -f $x1.Nombre, $x1.Volumen) 'Green' }
else { Nota "RESULTADO: queda algo por revisar. Los valores de antes estan en $CarpetaCopia\audio_antes.json." 'Red' }
$informe | Set-Content (Join-Path $CarpetaCopia 'informe.txt')
