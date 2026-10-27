// 3dxGC.exe - opens the control panel, the way 3dxGC.bat does without the
// console window.
//
// Asks for administrator once, because the system-wide memory operations need
// it. If the UAC prompt is declined the panel still opens, unelevated: per-
// process trimming and caps on the user's own apps need no privileges, so
// declining costs the system-wide operations, not the tool.
//
// The exe itself asks for nothing (asInvoker), so it can sit in the Run key:
// Windows skips Run entries whose manifest demands elevation.
//
//   3dxGC.exe [-Minimized] [-noelevate] [other Start-Gui.ps1 arguments]
//
// -noelevate opens the panel without the UAC prompt. -elevated is internal:
// the relaunch through UAC carries it so the prompt can never come twice.
// Neither reaches Start-Gui.ps1, which has no such parameters and refuses to
// start on them.
//
// C# 5 for the .NET Framework 4 csc.exe that ships with Windows.

using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Security.Principal;
using System.Text;
using System.Windows.Forms;

static class Launcher
{
    [STAThread]
    static int Main(string[] args)
    {
        string root = AppDomain.CurrentDomain.BaseDirectory;
        string gui = Path.Combine(root, @"gui\Start-Gui.ps1");
        if (!File.Exists(gui))
        {
            MessageBox.Show(
                "3dxGC's files are missing - gui\\Start-Gui.ps1 is not next to 3dxGC.exe.\n\n" +
                "Reinstall 3dxGC to repair it.",
                "3dxGC", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }

        bool askForAdmin = true;
        var passThrough = new StringBuilder();
        foreach (string a in args)
        {
            if (a.Equals("-elevated", StringComparison.OrdinalIgnoreCase) ||
                a.Equals("-noelevate", StringComparison.OrdinalIgnoreCase))
            {
                askForAdmin = false;
                continue;
            }
            passThrough.Append(' ').Append(Quote(a));
        }

        if (askForAdmin && !IsElevated())
        {
            try
            {
                var self = new ProcessStartInfo(Application.ExecutablePath, "-elevated" + passThrough);
                self.UseShellExecute = true;
                self.Verb = "runas";
                self.WorkingDirectory = root;
                Process.Start(self);
                return 0;
            }
            catch (Win32Exception)
            {
                // Declined (ERROR_CANCELLED) or UAC unavailable - open unelevated.
            }
        }

        // The 64-bit PowerShell by full path: this exe is AnyCPU, and the
        // memory APIs the panel calls need a process of the OS's own bitness.
        string ps = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");
        var psi = new ProcessStartInfo(ps,
            "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " + Quote(gui) + passThrough);
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.WorkingDirectory = root;
        Process.Start(psi);
        return 0;
    }

    static bool IsElevated()
    {
        using (var id = WindowsIdentity.GetCurrent())
            return new WindowsPrincipal(id).IsInRole(WindowsBuiltInRole.Administrator);
    }

    // CommandLineToArgvW's rules: quote when needed, double the backslashes
    // that end up before a quote, escape embedded quotes.
    static string Quote(string arg)
    {
        if (arg.Length > 0 && arg.IndexOfAny(new[] { ' ', '\t', '"' }) < 0) return arg;
        var sb = new StringBuilder("\"");
        int slashes = 0;
        foreach (char c in arg)
        {
            if (c == '\\') { slashes++; continue; }
            if (c == '"') sb.Append('\\', slashes * 2 + 1);
            else sb.Append('\\', slashes);
            slashes = 0;
            sb.Append(c);
        }
        sb.Append('\\', slashes * 2).Append('"');
        return sb.ToString();
    }
}
