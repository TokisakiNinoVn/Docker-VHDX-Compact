// DockerCompact.exe - tiny launcher so the app has its own icon and
// executable instead of a powershell.exe shortcut.
// It starts DockerCompact-UI.ps1 (next to this exe) elevated and hidden.
// Built by build.ps1 with the .NET Framework C# compiler (csc.exe).

using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

[assembly: AssemblyTitle("Docker VHDX Compact")]
[assembly: AssemblyProduct("Docker VHDX Compact")]
[assembly: AssemblyDescription("Compacts Docker Desktop's WSL2 virtual disk")]
[assembly: AssemblyCopyright("MIT License")]
[assembly: AssemblyVersion(BuildInfo.Version)]
[assembly: AssemblyFileVersion(BuildInfo.Version)]

static class Program
{
    [STAThread]
    static int Main()
    {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(dir, "DockerCompact-UI.ps1");

        if (!File.Exists(script))
        {
            MessageBox.Show("Cannot find " + script, "Docker VHDX Compact",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }

        string powershell = Path.Combine(Environment.SystemDirectory,
            @"WindowsPowerShell\v1.0\powershell.exe");

        ProcessStartInfo psi = new ProcessStartInfo(powershell,
            "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" + script + "\"");
        psi.UseShellExecute = true;
        psi.Verb = "runas";               // DiskPart and wsl --shutdown need admin
        psi.WindowStyle = ProcessWindowStyle.Hidden;
        psi.WorkingDirectory = dir;

        try
        {
            Process.Start(psi);
            return 0;
        }
        catch (Win32Exception ex)
        {
            if (ex.NativeErrorCode == 1223) return 2;   // user cancelled UAC
            MessageBox.Show(ex.Message, "Docker VHDX Compact",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
