# ReparaWin11.ps1 - ventana principal. Abrir con Iniciar_ReparaWin11.cmd (pide administrador una vez).
# El trabajo se hace en un proceso de fondo (runspace) para que la ventana no se congele.
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$raiz = Split-Path -Parent $MyInvocation.MyCommand.Path

function Aviso([string]$t) { [void][System.Windows.MessageBox]::Show($t, 'ReparaWin11', 'OK', 'Warning') }
if (-not [Environment]::Is64BitProcess) { Aviso 'Abre la herramienta con Iniciar_ReparaWin11.cmd (necesita PowerShell de 64 bits).'; return }
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { Aviso 'La herramienta necesita permisos de administrador. Abrela con Iniciar_ReparaWin11.cmd y pulsa Si.'; return }

Add-Type -TypeDefinition @"
using System.ComponentModel;
public class FilaRW : INotifyPropertyChanged {
    public event PropertyChangedEventHandler PropertyChanged;
    void C(string p) { if (PropertyChanged != null) PropertyChanged(this, new PropertyChangedEventArgs(p)); }
    bool _m; string _e = "Sin mirar", _c = "#9E9E9E", _r = "", _a = "";
    public string Id { get; set; } public string Grupo { get; set; } public string Nombre { get; set; } public string Descripcion { get; set; }
    public bool PuedeReparar { get; set; } public bool Avanzado { get; set; } public bool Lento { get; set; }
    public string[] Detalle { get; set; } public string EstadoInicial { get; set; }
    public bool Marcar { get { return _m; } set { _m = value; C("Marcar"); } }
    public string Estado { get { return _e; } set { _e = value; C("Estado"); } }
    public string Color { get { return _c; } set { _c = value; C("Color"); } }
    public string Resumen { get { return _r; } set { _r = value; C("Resumen"); } }
    public string Accion { get { return _a; } set { _a = value; C("Accion"); } }
}
"@

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="ReparaWin11 - diagnostico y reparacion de Windows 11" Width="1180" Height="780" MinWidth="900" MinHeight="600"
        WindowStartupLocation="CenterScreen" Background="#F4F5F7" FontFamily="Segoe UI" FontSize="13">
  <Grid Margin="14">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="200"/></Grid.RowDefinitions>
    <StackPanel Grid.Row="0">
      <TextBlock Text="ReparaWin11" FontSize="24" FontWeight="SemiBold" Foreground="#1F2937"/>
      <TextBlock x:Name="Equipo" Foreground="#4B5563" Margin="0,2,0,8"/>
    </StackPanel>
    <WrapPanel Grid.Row="1" Margin="0,0,0,8">
      <Button x:Name="BDiag" Content="1. Diagnosticar todo" Padding="14,7" Margin="0,0,8,6" Background="#1565C0" Foreground="White" BorderThickness="0" FontWeight="SemiBold"/>
      <Button x:Name="BRep" Content="2. Reparar lo marcado" Padding="14,7" Margin="0,0,8,6" Background="#2E7D32" Foreground="White" BorderThickness="0" FontWeight="SemiBold" IsEnabled="False"/>
      <Button x:Name="BTodo" Content="Reparar todo (diagnostica y repara lo que este mal)" Padding="14,7" Margin="0,0,16,6" Background="#C62828" Foreground="White" BorderThickness="0" FontWeight="SemiBold"/>
      <CheckBox x:Name="OLentos" Content="Incluir analisis lentos (SFC, DISM completo, disco)" VerticalAlignment="Center" Margin="0,0,14,6"/>
      <CheckBox x:Name="OPunto" Content="Crear punto de restauracion antes de reparar" IsChecked="True" VerticalAlignment="Center" Margin="0,0,14,6"/>
      <CheckBox x:Name="OAvanz" Content="Permitir reparaciones avanzadas (red, SMB1, disco, servicios deshabilitados)" VerticalAlignment="Center" Margin="0,0,14,6"/>
      <Button x:Name="BInforme" Content="Abrir informe" Padding="10,5" Margin="0,0,8,6" IsEnabled="False"/>
      <Button x:Name="BCopias" Content="Abrir copias" Padding="10,5" Margin="0,0,8,6"/>
    </WrapPanel>
    <ListView x:Name="Lista" Grid.Row="2" Background="White" BorderBrush="#D1D5DB">
      <ListView.View><GridView>
        <GridViewColumn Header="Reparar" Width="64"><GridViewColumn.CellTemplate><DataTemplate>
          <CheckBox IsChecked="{Binding Marcar, Mode=TwoWay}" IsEnabled="{Binding PuedeReparar}" HorizontalAlignment="Center"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
        <GridViewColumn Header="Estado" Width="110"><GridViewColumn.CellTemplate><DataTemplate>
          <StackPanel Orientation="Horizontal"><Ellipse Width="14" Height="14" Fill="{Binding Color}" Margin="0,0,6,0"/><TextBlock Text="{Binding Estado}"/></StackPanel></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
        <GridViewColumn Header="Area" Width="160" DisplayMemberBinding="{Binding Grupo}"/>
        <GridViewColumn Header="Comprobacion" Width="260" DisplayMemberBinding="{Binding Nombre}"/>
        <GridViewColumn Header="Resultado (doble clic para ver el detalle)" Width="540"><GridViewColumn.CellTemplate><DataTemplate>
          <TextBlock Text="{Binding Resumen}" TextWrapping="Wrap" MaxWidth="530"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
      </GridView></ListView.View>
    </ListView>
    <Grid Grid.Row="3" Margin="0,8,0,6">
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="300"/></Grid.ColumnDefinitions>
      <TextBlock x:Name="Situacion" Text="Pulsa Diagnosticar todo para empezar. No se cambia nada hasta que pulses Reparar." Foreground="#374151" VerticalAlignment="Center"/>
      <ProgressBar x:Name="Barra" Grid.Column="1" Height="16" Minimum="0" Maximum="100"/>
    </Grid>
    <TextBox x:Name="Registro" Grid.Row="4" IsReadOnly="True" FontFamily="Consolas" FontSize="12" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" Background="#111827" Foreground="#E5E7EB" TextWrapping="NoWrap"/>
  </Grid>
</Window>
"@
$ventana = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$c = @{}; foreach ($n in 'Equipo', 'BDiag', 'BRep', 'BTodo', 'OLentos', 'OPunto', 'OAvanz', 'BInforme', 'BCopias', 'Lista', 'Situacion', 'Barra', 'Registro') { $c[$n] = $ventana.FindName($n) }

# ---------- datos de los modulos ----------
. (Join-Path $raiz 'Nucleo.ps1')
$modulos = Cargar-Modulos
$filas = New-Object System.Collections.ObjectModel.ObservableCollection[FilaRW]
foreach ($m in $modulos) {
    $f = New-Object FilaRW
    $f.Id = $m.Id; $f.Grupo = $m.Grupo; $f.Nombre = $m.Nombre; $f.Descripcion = $m.Descripcion
    $f.PuedeReparar = [bool]$m.Reparar; $f.Avanzado = [bool]$m.Avanzado; $f.Lento = [bool]$m.Lento; $f.Detalle = @()
    $f.Resumen = $(if ($m.Avanzado) { '(avanzado) ' } else { '' }) + $m.Descripcion
    $filas.Add($f)
}
$c.Lista.ItemsSource = $filas
$os = Get-CimInstance Win32_OperatingSystem
$c.Equipo.Text = '{0} | compilacion {1} | {2} | equipo {3} | {4} comprobaciones' -f $os.Caption, $os.BuildNumber, $os.OSArchitecture, $env:COMPUTERNAME, $filas.Count

# ---------- estado compartido con el proceso de fondo ----------
$sync = [hashtable]::Synchronized(@{ Cola = New-Object System.Collections.Concurrent.ConcurrentQueue[string]; Cambios = New-Object System.Collections.Concurrent.ConcurrentQueue[object]; Fin = $true; Progreso = 0; Informe = ''; Texto = '' })
$registroCompleto = New-Object System.Collections.ArrayList
$informes = Join-Path $raiz 'Informes'; New-Item -ItemType Directory -Force $informes | Out-Null
$Global:RWLogSesion = Join-Path $informes ('registro_' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt')

$trabajo = {
    param($sync, $raiz, $accion, $ids, $opciones, $logArchivo, $copias)
    $Global:RWSync = $sync; $Global:RWLogArchivo = $logArchivo; $Global:RWCopias = $copias
    try {
        . (Join-Path $raiz 'Nucleo.ps1')
        $mods = @(Cargar-Modulos)
        $ctx = @{ Opciones = $opciones }
        $porId = @{}; foreach ($m in $mods) { $porId[$m.Id] = $m }
        $hechos = 0
        $diag = {
            param($m)
            $sync.Cambios.Enqueue(@{ Id = $m.Id; Estado = 'Mirando'; Resumen = 'Comprobando...' })
            try { $r = & $m.Diagnosticar $ctx } catch { $r = Resultado 'Amarillo' ('No se pudo comprobar: ' + $_.Exception.Message) @($_.ScriptStackTrace) }
            if (-not $r) { $r = Resultado 'Amarillo' 'La comprobacion no devolvio resultado.' @() }
            $r = @($r)[-1]
            $sync.Cambios.Enqueue(@{ Id = $m.Id; Estado = $r.Estado; Resumen = $r.Resumen; Detalle = $r.Detalle })
            Log ('[{0}] {1}: {2}' -f $r.Estado.ToUpper(), $m.Nombre, $r.Resumen) $(switch ($r.Estado) { 'Verde' { 'bien' } 'Rojo' { 'error' } 'Amarillo' { 'aviso' } default { 'info' } })
            return $r
        }
        if ($accion -eq 'Diagnosticar' -or $accion -eq 'Todo') {
            Log '=== DIAGNOSTICO (no se cambia nada) ===' 'titulo'
            $lista = @($mods | Where-Object { $ids -contains $_.Id })
            $malos = @(); $areasMal = @()
            foreach ($m in $lista) {
                $sync.Texto = "Comprobando: $($m.Nombre)"
                $r = & $diag $m
                if ($r.Estado -in 'Rojo', 'Amarillo') { $areasMal += $m.Id }
                if ($r.Estado -in 'Rojo', 'Amarillo' -and $m.Reparar -and ($opciones.Avanzadas -or -not $m.Avanzado)) { $malos += $m.Id }
                $hechos++; $sync.Progreso = [int](100 * $hechos / [Math]::Max(1, $lista.Count) / $(if ($accion -eq 'Todo') { 2 } else { 1 }))
            }
            # los solucionadores de Microsoft se marcan cuando sale mal alguna de sus areas
            foreach ($m in $mods) {
                $v = @($m.Vinculados | Where-Object { $areasMal -contains $_ })
                if ($m.Vinculados -and $v.Count) {
                    if ($malos -notcontains $m.Id) { $malos += $m.Id }
                    $nom = @($mods | Where-Object { $v -contains $_.Id } | ForEach-Object Nombre)
                    $sync.Cambios.Enqueue(@{ Id = $m.Id; Estado = 'Amarillo'; Resumen = ('RECOMENDADO: salen mal ' + ($nom -join ', ') + '. Se ejecutara con su red de seguridad.') })
                    Log ('[RECOMENDADO] {0} (por: {1})' -f $m.Nombre, ($nom -join ', ')) 'aviso'
                }
            }
            $sync.Marcar = $malos
            if ($accion -eq 'Todo') { $ids = $malos; if (-not $ids) { Log 'No hay nada que reparar.' 'bien' } }
        }
        if (($accion -eq 'Reparar' -or $accion -eq 'Todo') -and $ids) {
            Log '=== REPARACION ===' 'titulo'
            Log "Copias de seguridad de esta sesion: $Global:RWCopias" 'info'
            if ($opciones.Punto) { Log 'Creando punto de restauracion...'; [void](Crear-PuntoRestauracion -ActivarSiHaceFalta) }
            $lista = @($mods | Where-Object { $ids -contains $_.Id -and $_.Reparar })
            $base = $sync.Progreso; $i = 0
            foreach ($m in $lista) {
                $i++; $sync.Texto = "Reparando: $($m.Nombre)"
                $sync.Cambios.Enqueue(@{ Id = $m.Id; Estado = 'Reparando'; Resumen = 'Reparando...'; Accion = 'reparado' })
                Log ("--- Reparando: {0}" -f $m.Nombre) 'titulo'
                $rr = $null
                try { $rr = & $m.Reparar $ctx } catch { Log ('  ERROR: ' + $_.Exception.Message) 'error' }
                $rr = @($rr | Where-Object { $_ -and $_.PSObject.Properties['Estado'] })
                if ($m.VerificaAlReparar -and $rr) {
                    $r = $rr[-1]; $sync.Cambios.Enqueue(@{ Id = $m.Id; Estado = $r.Estado; Resumen = $r.Resumen; Detalle = $r.Detalle })
                    Log ('[{0}] {1}: {2}' -f $r.Estado.ToUpper(), $m.Nombre, $r.Resumen) $(if ($r.Estado -eq 'Verde') { 'bien' } else { 'aviso' })
                } else {
                    Log '  Comprobando el resultado...'
                    [void](& $diag $m)
                }
                $sync.Progreso = [int]($base + (100 - $base) * $i / $lista.Count)
            }
        }
        $sync.Progreso = 100
        Log '=== TERMINADO ===' 'titulo'
    } catch { Log ('ERROR GENERAL: ' + $_.Exception.Message + ' ' + $_.ScriptStackTrace) 'error' }
    finally { $sync.Fin = $true }
}

$Global:RWCopiasSesion = Join-Path $env:SystemDrive ('Copias_ReparaWin11\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))

function Lanzar([string]$Accion, [string[]]$Ids) {
    if (-not $sync.Fin) { return }
    $sync.Fin = $false; $sync.Progreso = 0; $sync.Marcar = $null
    foreach ($b in 'BDiag', 'BRep', 'BTodo') { $c[$b].IsEnabled = $false }
    $op = @{ Lentos = [bool]$c.OLentos.IsChecked; Punto = [bool]$c.OPunto.IsChecked; Avanzadas = [bool]$c.OAvanz.IsChecked }
    $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'STA'; $rs.Open()
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript($trabajo).AddArgument($sync).AddArgument($raiz).AddArgument($Accion).AddArgument($Ids).AddArgument($op).AddArgument($Global:RWLogSesion).AddArgument($Global:RWCopiasSesion)
    $Script:tarea = @{ PS = $ps; RS = $rs; H = $ps.BeginInvoke(); Accion = $Accion }
}

$colores = @{ Verde = '#2E7D32'; Amarillo = '#F9A825'; Rojo = '#C62828'; Gris = '#9E9E9E'; Mirando = '#1565C0'; Reparando = '#6A1B9A' }
$nombresEstado = @{ Verde = 'Bien'; Amarillo = 'Revisar'; Rojo = 'Mal'; Gris = 'Sin mirar'; Mirando = 'Mirando...'; Reparando = 'Reparando...' }
$porId = @{}; foreach ($f in $filas) { $porId[$f.Id] = $f }

$reloj = New-Object System.Windows.Threading.DispatcherTimer
$reloj.Interval = [TimeSpan]::FromMilliseconds(250)
$reloj.Add_Tick({
    $l = $null; $nuevo = New-Object System.Text.StringBuilder
    while ($sync.Cola.TryDequeue([ref]$l)) { [void]$registroCompleto.Add($l); $p = $l -split '\|', 3; [void]$nuevo.AppendLine(('{0}  {1}' -f $p[0], $p[2])) }
    if ($nuevo.Length) { $c.Registro.AppendText($nuevo.ToString()); $c.Registro.ScrollToEnd() }
    $x = $null
    while ($sync.Cambios.TryDequeue([ref]$x)) {
        $f = $porId[$x.Id]; if (-not $f) { continue }
        $f.Estado = $nombresEstado[$x.Estado]; $f.Color = $colores[$x.Estado]; $f.Resumen = $x.Resumen
        if ($x.Detalle) { $f.Detalle = [string[]]$x.Detalle }
        if ($x.Estado -in 'Verde', 'Amarillo', 'Rojo', 'Gris' -and -not $f.EstadoInicial) { $f.EstadoInicial = $x.Estado }
        if ($x.Accion) { $f.Accion = $x.Accion }
    }
    $c.Barra.Value = $sync.Progreso
    if (-not $sync.Fin) { $c.Situacion.Text = $sync.Texto }
    if ($sync.Fin -and $Script:tarea) {
        try { $Script:tarea.PS.EndInvoke($Script:tarea.H) } catch { $c.Registro.AppendText("ERROR: $($_.Exception.Message)`r`n") }
        $Script:tarea.PS.Dispose(); $Script:tarea.RS.Close()
        $acc = $Script:tarea.Accion; $Script:tarea = $null
        if ($sync.Marcar) { foreach ($f in $filas) { $f.Marcar = ($sync.Marcar -contains $f.Id) } }
        foreach ($b in 'BDiag', 'BTodo') { $c[$b].IsEnabled = $true }; $c.BRep.IsEnabled = $true
        $malos = @($filas | Where-Object { $_.Estado -in 'Mal', 'Revisar' }).Count
        $c.Situacion.Text = $(if ($acc -eq 'Diagnosticar') { "Diagnostico terminado: $malos comprobacion(es) en rojo o amarillo. Las reparables estan marcadas; pulsa Reparar lo marcado." } else { "Reparacion terminada. Quedan $malos en rojo o amarillo. Mira el informe." })
        # informe
        $datos = @($filas | ForEach-Object { [pscustomobject]@{ Grupo = $_.Grupo; Nombre = $_.Nombre; Estado = $(switch ($_.Estado) { 'Bien' { 'Verde' } 'Revisar' { 'Amarillo' } 'Mal' { 'Rojo' } default { 'Gris' } }); Accion = $(if ($_.Accion) { $_.Accion } else { 'solo diagnostico' }); Resumen = $_.Resumen; Detalle = @($_.Detalle) } })
        $Script:informe = Join-Path $informes ('informe_' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.html')
        $Global:RWCopias = $Global:RWCopiasSesion
        try { Escribir-Informe $datos $Script:informe @($registroCompleto); $c.BInforme.IsEnabled = $true; $c.Registro.AppendText("Informe: $Script:informe`r`n") } catch { $c.Registro.AppendText("No se pudo escribir el informe: $($_.Exception.Message)`r`n") }
    }
})
$reloj.Start()

$c.BDiag.Add_Click({ Lanzar 'Diagnosticar' @($filas | ForEach-Object Id) })
$c.BRep.Add_Click({
    $ids = @($filas | Where-Object Marcar | ForEach-Object Id)
    if (-not $ids) { Aviso 'No hay nada marcado para reparar.'; return }
    $av = @($filas | Where-Object { $_.Marcar -and $_.Avanzado } | ForEach-Object Nombre)
    $t = "Se van a reparar $($ids.Count) comprobacion(es):`n`n" + (($filas | Where-Object Marcar | ForEach-Object { '- ' + $_.Nombre }) -join "`n")
    if ($av) { $t += "`n`nAVANZADAS (pueden exigir reiniciar): " + ($av -join ', ') }
    $t += "`n`nSe guarda copia de todo lo que se toque en $Global:RWCopiasSesion. Continuar?"
    if ([System.Windows.MessageBox]::Show($t, 'ReparaWin11', 'YesNo', 'Question') -eq 'Yes') { Lanzar 'Reparar' $ids }
})
$c.BTodo.Add_Click({
    $t = 'Se va a diagnosticar todo y se reparara automaticamente lo que salga en rojo o amarillo' + $(if ($c.OAvanz.IsChecked) { ', INCLUIDAS las reparaciones avanzadas' } else { ' (sin las avanzadas)' }) + ".`n`nSe guarda copia de todo lo que se toque" + $(if ($c.OPunto.IsChecked) { ' y se crea un punto de restauracion' } else { '' }) + '. Continuar?'
    if ([System.Windows.MessageBox]::Show($t, 'ReparaWin11', 'YesNo', 'Question') -eq 'Yes') { Lanzar 'Todo' @($filas | ForEach-Object Id) }
})
$c.BInforme.Add_Click({ if ($Script:informe -and (Test-Path $Script:informe)) { Start-Process $Script:informe } })
$c.BCopias.Add_Click({ $d = Join-Path $env:SystemDrive 'Copias_ReparaWin11'; if (Test-Path $d) { Start-Process explorer.exe $d } else { Aviso 'Todavia no hay copias (se crean al reparar).' } })
$c.Lista.Add_MouseDoubleClick({
    $f = $c.Lista.SelectedItem; if (-not $f) { return }
    $t = $f.Nombre + "`n`n" + $f.Descripcion + "`n`nResultado: " + $f.Resumen + "`n`n" + (@($f.Detalle) -join "`n")
    [void][System.Windows.MessageBox]::Show($t, 'Detalle', 'OK', 'Information')
})
$ventana.Add_Closing({ param($s, $e) if (-not $sync.Fin) { if ([System.Windows.MessageBox]::Show('Hay un trabajo en marcha. Si cierras ahora puede quedar a medias. Cerrar igualmente?', 'ReparaWin11', 'YesNo', 'Warning') -ne 'Yes') { $e.Cancel = $true } } })
[void]$ventana.ShowDialog()
$reloj.Stop()
