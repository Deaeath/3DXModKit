// 3DXModKit - Native memory management layer
//
// Implements the five operations exposed by Sysinternals RAMMap's "Empty" menu,
// plus the telemetry needed to drive them from a policy instead of by hand.
//
// RAMMap menu item            -> implementation here
// --------------------------------------------------------------------------
// Empty Working Sets          -> EmptyAllWorkingSets()      NtSetSystemInformation cmd 2
// Empty System Working Set    -> EmptySystemWorkingSet()    SetSystemFileCacheSize(-1,-1)
// Empty Modified Page List    -> FlushModifiedPageList()    cmd 3
// Empty Standby List          -> PurgeStandbyList()         cmd 4
// Empty Priority 0 Standby    -> PurgeLowPriorityStandby()  cmd 5
//
// TrimProcess() is the targeted primitive and the only one that needs no
// elevation - you may always trim the working set of a process you own. Every
// system-wide operation needs admin plus an explicitly enabled privilege, so
// each returns a structured MemOpResult instead of throwing, letting policy
// degrade gracefully when unelevated.
//
// Everything here is read-only with respect to the game: no process memory is
// written, no handles are opened for VM_WRITE, no modules are touched. This is
// the same surface Task Manager uses.
//
// C# 5 syntax for Windows PowerShell 5.1's in-box CodeDom compiler.

using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace ThreeDX.ModKit.Native
{
    #region Interop structures

    [StructLayout(LayoutKind.Sequential)]
    public struct MEMORYSTATUSEX
    {
        public uint dwLength;
        public uint dwMemoryLoad;
        public ulong ullTotalPhys;
        public ulong ullAvailPhys;
        public ulong ullTotalPageFile;
        public ulong ullAvailPageFile;
        public ulong ullTotalVirtual;
        public ulong ullAvailVirtual;
        public ulong ullAvailExtendedVirtual;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESS_MEMORY_COUNTERS_EX
    {
        public uint cb;
        public uint PageFaultCount;
        public IntPtr PeakWorkingSetSize;
        public IntPtr WorkingSetSize;
        public IntPtr QuotaPeakPagedPoolUsage;
        public IntPtr QuotaPagedPoolUsage;
        public IntPtr QuotaPeakNonPagedPoolUsage;
        public IntPtr QuotaNonPagedPoolUsage;
        public IntPtr PagefileUsage;
        public IntPtr PeakPagefileUsage;
        public IntPtr PrivateUsage;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct LUID { public uint LowPart; public int HighPart; }

    [StructLayout(LayoutKind.Sequential)]
    public struct LUID_AND_ATTRIBUTES { public LUID Luid; public uint Attributes; }

    [StructLayout(LayoutKind.Sequential)]
    public struct TOKEN_PRIVILEGES { public uint PrivilegeCount; public LUID_AND_ATTRIBUTES Privileges; }

    [StructLayout(LayoutKind.Sequential)]
    public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }

    #endregion

    #region Result types

    /// <summary>Outcome of one memory operation. Never throws; inspect Success/Error.</summary>
    public class MemOpResult
    {
        public string Operation;
        public bool Success;
        public string Error;
        public long BytesFreed;      // delta in system available physical memory
        public long DurationMs;
        public bool RequiredElevation;
        public int AffectedProcesses;

        public MemOpResult(string op)
        {
            Operation = op; Success = false; Error = null;
            BytesFreed = 0; DurationMs = 0;
            RequiredElevation = false; AffectedProcesses = 0;
        }

        public double FreedMB { get { return Math.Round(BytesFreed / 1048576.0, 1); } }

        public override string ToString()
        {
            return Operation + ": " + (Success ? "ok" : "FAILED " + Error)
                 + " (" + FreedMB + " MB, " + DurationMs + " ms)";
        }
    }

    public class SystemMemorySnapshot
    {
        public ulong TotalPhysBytes;
        public ulong AvailPhysBytes;
        public uint MemoryLoadPercent;
        public ulong TotalPageFileBytes;
        public ulong AvailPageFileBytes;

        public double TotalPhysGB { get { return Math.Round(TotalPhysBytes / 1073741824.0, 2); } }
        public double AvailPhysGB { get { return Math.Round(AvailPhysBytes / 1073741824.0, 2); } }
        public double AvailPercent
        {
            get
            {
                if (TotalPhysBytes == 0) return 0;
                return Math.Round((double)AvailPhysBytes / (double)TotalPhysBytes * 100.0, 1);
            }
        }
    }

    public class ProcessMemorySnapshot
    {
        public int ProcessId;
        public string ProcessName;
        public long WorkingSetBytes;
        public long PeakWorkingSetBytes;
        public long PrivateBytes;
        public long PagefileBytes;
        public uint PageFaultCount;

        public double WorkingSetMB { get { return Math.Round(WorkingSetBytes / 1048576.0, 1); } }
        public double PrivateMB { get { return Math.Round(PrivateBytes / 1048576.0, 1); } }
        public double PeakWorkingSetMB { get { return Math.Round(PeakWorkingSetBytes / 1048576.0, 1); } }
    }

    #endregion

    public static class MemOps
    {
        #region P/Invoke

        private const int SystemMemoryListInformation = 0x50;  // 80

        // SYSTEM_MEMORY_LIST_COMMAND
        private const int MemoryEmptyWorkingSets = 2;
        private const int MemoryFlushModifiedList = 3;
        private const int MemoryPurgeStandbyList = 4;
        private const int MemoryPurgeLowPriorityStandbyList = 5;

        private const uint SE_PRIVILEGE_ENABLED = 0x00000002;
        private const uint TOKEN_ADJUST_PRIVILEGES = 0x0020;
        private const uint TOKEN_QUERY = 0x0008;

        private const uint PROCESS_QUERY_INFORMATION = 0x0400;
        private const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
        private const uint PROCESS_SET_QUOTA = 0x0100;
        private const uint PROCESS_VM_READ = 0x0010;

        private const string SE_PROFILE_SINGLE_PROCESS = "SeProfileSingleProcessPrivilege";
        private const string SE_INCREASE_QUOTA = "SeIncreaseQuotaPrivilege";

        [DllImport("ntdll.dll", SetLastError = true)]
        private static extern int NtSetSystemInformation(int InfoClass, IntPtr Info, int Length);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX lpBuffer);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetSystemFileCacheSize(IntPtr min, IntPtr max, int flags);

        [DllImport("psapi.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool EmptyWorkingSet(IntPtr hProcess);

        [DllImport("psapi.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetProcessMemoryInfo(IntPtr hProcess,
                                                        out PROCESS_MEMORY_COUNTERS_EX counters,
                                                        uint size);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(uint access, bool inherit, int pid);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseHandle(IntPtr h);

        [DllImport("kernel32.dll")]
        private static extern IntPtr GetCurrentProcess();

        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool OpenProcessToken(IntPtr hProcess, uint access, out IntPtr hToken);

        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool LookupPrivilegeValue(string host, string name, out LUID luid);

        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool AdjustTokenPrivileges(IntPtr hToken, bool disableAll,
                                                         ref TOKEN_PRIVILEGES newState,
                                                         uint bufferLength, IntPtr prevState,
                                                         IntPtr returnLength);

        [DllImport("user32.dll")]
        private static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll", SetLastError = true)]
        private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out int pid);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool IsIconic(IntPtr hWnd);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);

        #endregion

        #region Privileges

        /// <summary>
        /// Enables a named privilege on the current process token. The system-wide
        /// memory list operations fail with STATUS_PRIVILEGE_NOT_HELD without this.
        /// </summary>
        public static bool EnablePrivilege(string privilegeName)
        {
            IntPtr token = IntPtr.Zero;
            try
            {
                if (!OpenProcessToken(GetCurrentProcess(),
                                      TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, out token))
                    return false;

                LUID luid;
                if (!LookupPrivilegeValue(null, privilegeName, out luid)) return false;

                TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
                tp.PrivilegeCount = 1;
                tp.Privileges.Luid = luid;
                tp.Privileges.Attributes = SE_PRIVILEGE_ENABLED;

                if (!AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero))
                    return false;

                // AdjustTokenPrivileges reports success even on partial assignment.
                return Marshal.GetLastWin32Error() == 0;
            }
            catch { return false; }
            finally { if (token != IntPtr.Zero) CloseHandle(token); }
        }

        public static bool IsElevated()
        {
            try
            {
                var id = System.Security.Principal.WindowsIdentity.GetCurrent();
                var pr = new System.Security.Principal.WindowsPrincipal(id);
                return pr.IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator);
            }
            catch { return false; }
        }

        #endregion

        #region Telemetry

        public static SystemMemorySnapshot GetSystemMemory()
        {
            MEMORYSTATUSEX st = new MEMORYSTATUSEX();
            st.dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX));
            var s = new SystemMemorySnapshot();
            if (GlobalMemoryStatusEx(ref st))
            {
                s.TotalPhysBytes = st.ullTotalPhys;
                s.AvailPhysBytes = st.ullAvailPhys;
                s.MemoryLoadPercent = st.dwMemoryLoad;
                s.TotalPageFileBytes = st.ullTotalPageFile;
                s.AvailPageFileBytes = st.ullAvailPageFile;
            }
            return s;
        }

        private static long AvailBytes() { return (long)GetSystemMemory().AvailPhysBytes; }

        public static ProcessMemorySnapshot GetProcessMemory(int pid)
        {
            IntPtr h = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, false, pid);
            if (h == IntPtr.Zero) h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
            if (h == IntPtr.Zero) return null;
            try
            {
                PROCESS_MEMORY_COUNTERS_EX c;
                uint size = (uint)Marshal.SizeOf(typeof(PROCESS_MEMORY_COUNTERS_EX));
                if (!GetProcessMemoryInfo(h, out c, size)) return null;

                var s = new ProcessMemorySnapshot();
                s.ProcessId = pid;
                s.WorkingSetBytes = c.WorkingSetSize.ToInt64();
                s.PeakWorkingSetBytes = c.PeakWorkingSetSize.ToInt64();
                s.PrivateBytes = c.PrivateUsage.ToInt64();
                s.PagefileBytes = c.PagefileUsage.ToInt64();
                s.PageFaultCount = c.PageFaultCount;
                try { s.ProcessName = Process.GetProcessById(pid).ProcessName; }
                catch { s.ProcessName = "?"; }
                return s;
            }
            finally { CloseHandle(h); }
        }

        /// <summary>PID owning the foreground window, or 0.</summary>
        public static int GetForegroundPid()
        {
            IntPtr hwnd = GetForegroundWindow();
            if (hwnd == IntPtr.Zero) return 0;
            int pid; GetWindowThreadProcessId(hwnd, out pid);
            return pid;
        }

        public static bool IsProcessMinimized(int pid)
        {
            try
            {
                var p = Process.GetProcessById(pid);
                if (p.MainWindowHandle == IntPtr.Zero) return false;
                return IsIconic(p.MainWindowHandle);
            }
            catch { return false; }
        }

        /// <summary>Seconds since the last user input anywhere on the desktop.</summary>
        public static double GetIdleSeconds()
        {
            LASTINPUTINFO lii = new LASTINPUTINFO();
            lii.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
            if (!GetLastInputInfo(ref lii)) return 0;
            uint ticks = (uint)Environment.TickCount;
            return (ticks - lii.dwTime) / 1000.0;
        }

        #endregion

        #region Operations

        /// <summary>
        /// Trims one process's working set. The safe, unprivileged primitive: pages
        /// move to the standby list and fault back in on demand, lowering resident
        /// footprint without changing the process's committed memory.
        /// </summary>
        public static MemOpResult TrimProcess(int pid)
        {
            var r = new MemOpResult("TrimProcess:" + pid);
            var sw = Stopwatch.StartNew();
            long before = AvailBytes();

            IntPtr h = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_SET_QUOTA, false, pid);
            if (h == IntPtr.Zero)
            {
                r.Error = "OpenProcess failed: " + new Win32Exception(Marshal.GetLastWin32Error()).Message;
                sw.Stop(); r.DurationMs = sw.ElapsedMilliseconds;
                return r;
            }
            try
            {
                if (!EmptyWorkingSet(h))
                    r.Error = "EmptyWorkingSet failed: " + new Win32Exception(Marshal.GetLastWin32Error()).Message;
                else { r.Success = true; r.AffectedProcesses = 1; }
            }
            finally { CloseHandle(h); }

            sw.Stop();
            r.DurationMs = sw.ElapsedMilliseconds;
            r.BytesFreed = AvailBytes() - before;
            return r;
        }

        /// <summary>Trims every process matching a name (no .exe). Unprivileged.</summary>
        public static MemOpResult TrimProcessesByName(string processName)
        {
            var r = new MemOpResult("TrimProcessesByName:" + processName);
            var sw = Stopwatch.StartNew();
            long before = AvailBytes();
            int hit = 0;
            var errors = new List<string>();

            Process[] procs;
            try { procs = Process.GetProcessesByName(processName); }
            catch (Exception ex)
            {
                r.Error = ex.Message;
                sw.Stop(); r.DurationMs = sw.ElapsedMilliseconds;
                return r;
            }

            foreach (var p in procs)
            {
                IntPtr h = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_SET_QUOTA, false, p.Id);
                if (h == IntPtr.Zero) { errors.Add("pid " + p.Id + ": access denied"); continue; }
                try { if (EmptyWorkingSet(h)) hit++; }
                finally { CloseHandle(h); }
            }

            r.Success = hit > 0 || procs.Length == 0;
            r.AffectedProcesses = hit;
            if (errors.Count > 0) r.Error = string.Join("; ", errors.ToArray());
            sw.Stop();
            r.DurationMs = sw.ElapsedMilliseconds;
            r.BytesFreed = AvailBytes() - before;
            return r;
        }

        private static MemOpResult MemoryListCommand(string opName, int command, string privilege)
        {
            var r = new MemOpResult(opName);
            r.RequiredElevation = true;
            var sw = Stopwatch.StartNew();

            if (!IsElevated())
            {
                r.Error = "requires elevation (run as Administrator)";
                sw.Stop(); r.DurationMs = sw.ElapsedMilliseconds;
                return r;
            }
            if (!EnablePrivilege(privilege))
            {
                r.Error = "could not enable " + privilege;
                sw.Stop(); r.DurationMs = sw.ElapsedMilliseconds;
                return r;
            }

            long before = AvailBytes();
            IntPtr buf = Marshal.AllocHGlobal(sizeof(int));
            try
            {
                Marshal.WriteInt32(buf, command);
                int status = NtSetSystemInformation(SystemMemoryListInformation, buf, sizeof(int));
                if (status != 0) r.Error = "NtSetSystemInformation -> 0x" + status.ToString("X8");
                else r.Success = true;
            }
            catch (Exception ex) { r.Error = ex.Message; }
            finally { Marshal.FreeHGlobal(buf); }

            sw.Stop();
            r.DurationMs = sw.ElapsedMilliseconds;
            r.BytesFreed = AvailBytes() - before;
            return r;
        }

        /// <summary>RAMMap: Empty Working Sets (system-wide). Elevation required.</summary>
        public static MemOpResult EmptyAllWorkingSets()
        { return MemoryListCommand("EmptyAllWorkingSets", MemoryEmptyWorkingSets, SE_PROFILE_SINGLE_PROCESS); }

        /// <summary>RAMMap: Empty Modified Page List. Elevation required.</summary>
        public static MemOpResult FlushModifiedPageList()
        { return MemoryListCommand("FlushModifiedPageList", MemoryFlushModifiedList, SE_PROFILE_SINGLE_PROCESS); }

        /// <summary>RAMMap: Empty Standby List. Elevation required.</summary>
        public static MemOpResult PurgeStandbyList()
        { return MemoryListCommand("PurgeStandbyList", MemoryPurgeStandbyList, SE_PROFILE_SINGLE_PROCESS); }

        /// <summary>RAMMap: Empty Priority 0 Standby List. Elevation required.</summary>
        public static MemOpResult PurgeLowPriorityStandby()
        { return MemoryListCommand("PurgeLowPriorityStandby", MemoryPurgeLowPriorityStandbyList, SE_PROFILE_SINGLE_PROCESS); }

        /// <summary>
        /// RAMMap: Empty System Working Set. Resets the system file cache working set
        /// via SetSystemFileCacheSize(-1,-1). Needs elevation + SeIncreaseQuotaPrivilege.
        /// </summary>
        public static MemOpResult EmptySystemWorkingSet()
        {
            var r = new MemOpResult("EmptySystemWorkingSet");
            r.RequiredElevation = true;
            var sw = Stopwatch.StartNew();

            if (!IsElevated())
            {
                r.Error = "requires elevation (run as Administrator)";
                sw.Stop(); r.DurationMs = sw.ElapsedMilliseconds;
                return r;
            }
            if (!EnablePrivilege(SE_INCREASE_QUOTA))
            {
                r.Error = "could not enable " + SE_INCREASE_QUOTA;
                sw.Stop(); r.DurationMs = sw.ElapsedMilliseconds;
                return r;
            }

            long before = AvailBytes();
            try
            {
                IntPtr neg1 = new IntPtr(-1);   // documented flush sentinel
                if (!SetSystemFileCacheSize(neg1, neg1, 0))
                    r.Error = "SetSystemFileCacheSize failed: "
                            + new Win32Exception(Marshal.GetLastWin32Error()).Message;
                else r.Success = true;
            }
            catch (Exception ex) { r.Error = ex.Message; }

            sw.Stop();
            r.DurationMs = sw.ElapsedMilliseconds;
            r.BytesFreed = AvailBytes() - before;
            return r;
        }

        /// <summary>
        /// Fires every RAMMap Empty operation in the order the GUI lists them.
        /// Operations needing elevation you lack are reported failed, never thrown.
        /// </summary>
        public static List<MemOpResult> EmptyAll()
        {
            var results = new List<MemOpResult>();
            results.Add(EmptyAllWorkingSets());
            results.Add(EmptySystemWorkingSet());
            results.Add(FlushModifiedPageList());
            results.Add(PurgeStandbyList());
            results.Add(PurgeLowPriorityStandby());
            return results;
        }

        #endregion
    }
}
