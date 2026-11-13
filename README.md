<p align="center">
  <img src="docs/icono.png" width="128" alt="ReparaWin11">
</p>

<h1 align="center">ReparaWin11</h1>

<p align="center">
  <b>Diagnóstico y reparación de Windows 11 en una sola ventana.</b><br>
  Usa los solucionadores reales de Microsoft, pero con una red de seguridad que esquiva sus trampas conocidas.
</p>

<p align="center">
  <img alt="Windows 10/11" src="https://img.shields.io/badge/Windows-10%20%7C%2011-0078D6">
  <img alt="PowerShell 5.1" src="https://img.shields.io/badge/PowerShell-5.1-5391FE">
  <img alt="Licencia MIT" src="https://img.shields.io/badge/licencia-MIT-green">
  <img alt="Sin instalación" src="https://img.shields.io/badge/instalaci%C3%B3n-no%20necesita-brightgreen">
</p>

---

## Qué es

ReparaWin11 revisa **33 áreas** de Windows y las pone en **verde, amarillo o rojo**. Después repara lo que está mal: con un clic, o eligiendo qué reparar.

Nace de un laboratorio en el que se ejecutaron y documentaron **484 scripts de PowerShell que trae Windows 11**. Allí se encontraron **45 «callejones sin salida»**: reparaciones de Microsoft que dejan el sistema peor de lo que estaba. Algunos ejemplos:
- el solucionador de BITS deja la clave del servicio sin permisos para SYSTEM;
- el de Windows Update borra el historial;
- el de impresoras cancela los trabajos de todos los usuarios.

ReparaWin11 ejecuta esos solucionadores igualmente, porque son los que tienen poder para arreglar. Pero lo hace dentro de una **red de seguridad**:

1. **Antes:** copia lo que ese solucionador destruye o cambia sin dejar copia.
2. **Durante:** el solucionador real de Microsoft (`Invoke-TroubleshootingPack`) detecta y aplica sus reparaciones.
3. **Después:** un script de esquiva probado en el laboratorio deshace el daño conocido.
4. **Comprobación:** cada área se vuelve a diagnosticar. Nunca dice «reparado» sin haberlo comprobado.

## Descarga

Descarga **`ReparaWin11.exe`** desde [Releases](../../releases/latest). Haz doble clic y acepta el aviso de administrador. No hay que instalar nada.

> Windows SmartScreen puede avisar la primera vez porque el ejecutable no está firmado digitalmente. Pulsa *Más información* y luego *Ejecutar de todas formas*.

También puedes ejecutarlo desde el código fuente: clona el repositorio y abre `Iniciar_ReparaWin11.cmd`.

## Cómo se usa

| Botón | Qué hace |
|---|---|
| **1. Diagnosticar todo** | Revisa las 33 áreas. **No cambia nada.** |
| **2. Reparar lo marcado** | Repara lo marcado. Se marca solo lo que sale mal, y puedes cambiar la selección. |
| **Reparar todo** | Diagnostica y repara de una vez todo lo que salga en rojo o amarillo. |
| **Abrir informe** | Informe HTML con el estado inicial, lo que se hizo y el resultado. |

**Opciones**
- *Incluir análisis lentos:* SFC, DISM completo y análisis del disco (de 10 a 40 minutos).
- *Crear punto de restauración:* solo si hay al menos 10 GB libres.
- *Permitir reparaciones avanzadas:* reinicio de Winsock/IP, SMB1, disco y servicios deshabilitados. Pueden exigir reiniciar.

## Qué repara

### Solucionadores de Microsoft (con red de seguridad)
Windows Update · BITS · Impresoras · Sonido · Red · Búsqueda e indización · Hardware y dispositivos · Aplicaciones de la Tienda · Energía · Bluetooth · Reproducción de vídeo

### Reparaciones propias
| Área | Diagnóstico | Reparación |
|---|---|---|
| Imagen de Windows | `Repair-WindowsImage -CheckHealth / -ScanHealth` | `DISM /RestoreHealth` |
| Archivos del sistema | `sfc /verifyonly` (resultado leído de CBS.log, vale en cualquier idioma) | `sfc /scannow` |
| Disco | Salud del disco físico y del volumen, `Repair-Volume -Scan` | `Repair-Volume -SpotFix` o chkdsk al reiniciar |
| WMI | `winmgmt /verifyrepository` y consulta de prueba | Copia del repositorio y `/salvagerepository` |
| Windows Update | Servicios, BITS, fallos repetidos, AppData, hora | Arrancar lo parado sin cambiar tipos de inicio, almacén renombrado (no borrado), permisos de BITS, sincronizar la hora |
| Red | Adaptador → IP → puerta de enlace → DNS → HTTPS → proxy | Caché DNS y DHCP; avanzado: Winsock y TCP/IP |
| Servicios esenciales | 36 servicios con su tipo de inicio de fábrica | Arrancar los parados; los deshabilitados solo con opción avanzada |
| Impresión · Sonido · Dispositivos · Búsqueda | Estado real de cada servicio y dispositivo | Sin cortar trabajos, sin matar procesos, sin vaciar el índice |
| Aplicaciones | Paquetes con estado distinto de *Ok* | Volver a registrar solo los dañados |
| Espacio | Libre, temporales, descargas de Update, WER | Temporales antiguos, caché de Optimización de distribución, `StartComponentCleanup` |
| Seguridad | Defender, UAC, SMB1 | Firmas al día, UAC a su protección de fábrica, retirar SMB1 sin reiniciar por su cuenta |

## Seguridad

- **Copia antes de tocar nada:** registro, permisos, servicios y carpetas se copian en `C:\Copias_ReparaWin11\<fecha>\<área>\`.
- **No borra datos del usuario.** Lo que se reinicia se renombra o se mueve.
- **Respeta lo que el administrador eligió a propósito:** servicios deshabilitados, zonas de seguridad endurecidas, directivas.
- **No reinicia el equipo por su cuenta.** Avisa cuando hace falta reiniciar.
- **Registro completo** de cada acción en la carpeta `Informes`.

## Estructura

```
ReparaWin11.ps1            Ventana (WPF); el trabajo se hace en segundo plano
Nucleo.ps1                 Registro, copias, programas externos con límite de tiempo, punto de restauración, informe
Modulos/                   Un archivo por grupo de comprobaciones (Diagnosticar / Reparar)
Esquivas/                  Scripts que esquivan los callejones de Microsoft (CJ-xx), probados en el laboratorio
compilar/                  Compilar.ps1 genera dist/ReparaWin11.exe con csc.exe de .NET Framework (viene con Windows)
Iniciar_ReparaWin11.cmd    Abre la herramienta desde el código fuente como administrador
```

### Añadir una comprobación
Crea un archivo en `Modulos/` con:

```powershell
Registrar-Modulo @{
    Id = 'MIAREA'; Grupo = 'Mi grupo'; Nombre = 'Lo que se comprueba'; Orden = 70
    Diagnosticar = { Resultado 'Verde' 'Todo bien.' @('detalle') }
    Reparar      = { param($ctx) Log '  reparando...' }
}
```

### Compilar el ejecutable
```powershell
powershell -ExecutionPolicy Bypass -File compilar\Compilar.ps1
```

## Requisitos
Windows 10 u 11 de 64 bits con Windows PowerShell 5.1, que viene con Windows. Hace falta ser administrador.

## Licencia
[MIT](LICENSE)
