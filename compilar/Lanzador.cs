// Lanzador de ReparaWin11: lleva la herramienta dentro (app.zip), la descomprime en
// %LOCALAPPDATA%\ReparaWin11\app_<huella> y abre la ventana con Windows PowerShell 5.1 de 64 bits.
// El manifiesto pide administrador al abrir (requireAdministrator).
using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Security.Cryptography;
using System.Windows.Forms;

[assembly: AssemblyTitle("ReparaWin11")]
[assembly: AssemblyDescription("Diagnostico y reparacion de Windows 11")]
[assembly: AssemblyProduct("ReparaWin11")]
[assembly: AssemblyCopyright("Licencia MIT")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]

static class Lanzador
{
    [STAThread]
    static int Main()
    {
        try
        {
            Assembly asm = Assembly.GetExecutingAssembly();
            byte[] zip;
            using (Stream s = asm.GetManifestResourceStream("app.zip"))
            using (MemoryStream m = new MemoryStream()) { s.CopyTo(m); zip = m.ToArray(); }
            string huella;
            using (SHA256 sha = SHA256.Create()) { huella = BitConverter.ToString(sha.ComputeHash(zip)).Replace("-", "").Substring(0, 12); }

            string baseDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ReparaWin11");
            string dir = Path.Combine(baseDir, "app_" + huella);
            if (!File.Exists(Path.Combine(dir, "ReparaWin11.ps1")))
            {
                string tmp = dir + ".tmp";
                if (Directory.Exists(tmp)) Directory.Delete(tmp, true);
                Directory.CreateDirectory(tmp);
                string zf = Path.Combine(baseDir, "app_" + huella + ".zip");
                File.WriteAllBytes(zf, zip);
                ZipFile.ExtractToDirectory(zf, tmp);
                File.Delete(zf);
                if (Directory.Exists(dir)) Directory.Delete(dir, true);
                Directory.Move(tmp, dir);
            }

            string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), @"System32\WindowsPowerShell\v1.0\powershell.exe");
            ProcessStartInfo psi = new ProcessStartInfo(ps,
                "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" + Path.Combine(dir, "ReparaWin11.ps1") + "\"");
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.WorkingDirectory = dir;
            Process.Start(psi);
            return 0;
        }
        catch (Exception e)
        {
            MessageBox.Show("No se pudo abrir ReparaWin11:\n\n" + e.Message, "ReparaWin11", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
