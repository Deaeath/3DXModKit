// 3DXModKit Runtime - BepInEx 6 (IL2CPP) plugin for 3DXChat
// Target: Unity 2021.3.45f2, IL2CPP, x64
//
// This is the in-process half of the framework. It exists because the external
// host tier can only move pages around: EmptyWorkingSet evicts resident pages
// to the standby list, but the game's *committed* memory is unchanged, so the
// pages fault straight back in.
//
// Only code running inside the process can actually release memory:
//
//   Resources.UnloadUnusedAssets()  drops assets with no live references -
//                                   textures, meshes, audio clips left behind
//                                   by previous rooms and avatars. This is
//                                   where a multi-GB idle footprint lives.
//   GC.Collect()                    reclaims the managed heap afterwards.
//   QualitySettings.streamingMipmapsMemoryBudget
//                                   caps the texture streaming pool.
//
// Host and runtime cooperate over a named pipe: the host knows when you have
// alt-tabbed away, and asks the runtime to unload; the runtime does the real
// release; the host then trims the now-smaller working set.
//
// Client-side only. No hooks on networking, no protocol access, no writes to
// game state. Every Harmony patch is routed through ClientOnlyGuard.

using System;
using System.Collections.Concurrent;
using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Threading;
using BepInEx;
using BepInEx.Configuration;
using BepInEx.Unity.IL2CPP;
using Il2CppInterop.Runtime.Injection;
using UnityEngine;

namespace ThreeDX.ModKit.Runtime
{
    [BepInPlugin(PluginGuid, PluginName, PluginVersion)]
    public class ModKitRuntimePlugin : BasePlugin
    {
        public const string PluginGuid    = "com.3dxmodkit.runtime";
        public const string PluginName    = "3DXModKit Runtime";
        public const string PluginVersion = "1.0.0";

        public const string PipeName = "3dxmodkit-runtime";

        internal static ModKitRuntimePlugin Instance;
        internal static BepInEx.Logging.ManualLogSource Log;

        // Unity APIs are main-thread only. The pipe server runs on a worker,
        // so commands are queued here and drained by the pump component.
        internal static readonly ConcurrentQueue<string> CommandQueue = new ConcurrentQueue<string>();

        internal static volatile string LastResult = "{}";

        private ConfigEntry<bool>  _autoUnloadOnBackground;
        private ConfigEntry<int>   _minSecondsBetweenUnloads;
        private ConfigEntry<int>   _streamingBudgetMB;
        private ConfigEntry<bool>  _enablePipe;

        private Thread _pipeThread;
        private volatile bool _running;

        public override void Load()
        {
            Instance = this;
            Log = base.Log;

            _autoUnloadOnBackground = Config.Bind("General", "AutoUnloadOnBackground", true,
                "Run an asset unload when the host reports the game has been backgrounded.");
            _minSecondsBetweenUnloads = Config.Bind("General", "MinSecondsBetweenUnloads", 60,
                "Rate limit. UnloadUnusedAssets is a synchronous stall of 100-800ms; do not run it often.");
            _streamingBudgetMB = Config.Bind("General", "StreamingMipmapsBudgetMB", 0,
                "Texture streaming pool cap in MB. 0 leaves the game's own setting alone.");
            _enablePipe = Config.Bind("General", "EnableHostPipe", true,
                "Listen for commands from the external 3DXModKit host on a named pipe.");

            Log.LogInfo(PluginName + " v" + PluginVersion + " loading");

            // Inject the pump MonoBehaviour so we have a main-thread heartbeat.
            try
            {
                ClassInjector.RegisterTypeInIl2Cpp<MainThreadPump>();
                var go = new GameObject("3DXModKit.Pump");
                UnityEngine.Object.DontDestroyOnLoad(go);
                go.hideFlags = HideFlags.HideAndDontSave;
                go.AddComponent<MainThreadPump>();
                Log.LogInfo("main-thread pump injected");
            }
            catch (Exception ex)
            {
                Log.LogError("failed to inject pump: " + ex);
                return;
            }

            if (_streamingBudgetMB.Value > 0)
            {
                CommandQueue.Enqueue("setbudget:" + _streamingBudgetMB.Value);
            }

            if (_enablePipe.Value)
            {
                _running = true;
                _pipeThread = new Thread(PipeServerLoop);
                _pipeThread.IsBackground = true;
                _pipeThread.Name = "3DXModKit.Pipe";
                _pipeThread.Start();
                Log.LogInfo("host pipe listening on \\\\.\\pipe\\" + PipeName);
            }
        }

        public override bool Unload()
        {
            _running = false;
            return true;
        }

        internal int MinSecondsBetweenUnloads { get { return _minSecondsBetweenUnloads.Value; } }
        internal bool AutoUnloadOnBackground  { get { return _autoUnloadOnBackground.Value; } }

        /// <summary>
        /// One connection at a time, request/response, plain text. Deliberately
        /// local-only: NamedPipeServerStream with no remote access.
        /// </summary>
        private void PipeServerLoop()
        {
            while (_running)
            {
                try
                {
                    using (var server = new NamedPipeServerStream(
                        PipeName, PipeDirection.InOut, 1,
                        PipeTransmissionMode.Byte, PipeOptions.Asynchronous))
                    {
                        server.WaitForConnection();

                        using (var reader = new StreamReader(server, Encoding.UTF8, false, 1024, true))
                        using (var writer = new StreamWriter(server, new UTF8Encoding(false), 1024, true))
                        {
                            writer.AutoFlush = true;
                            string line = reader.ReadLine();
                            if (string.IsNullOrEmpty(line)) continue;

                            CommandQueue.Enqueue(line.Trim());

                            // Give the pump a moment to service it, then report
                            // the most recent result. Commands are advisory;
                            // the host does not block on precise ordering.
                            Thread.Sleep(120);
                            writer.WriteLine(LastResult);
                        }
                    }
                }
                catch (Exception ex)
                {
                    if (_running) Log.LogWarning("pipe error: " + ex.Message);
                    Thread.Sleep(500);
                }
            }
        }
    }

    /// <summary>
    /// Injected MonoBehaviour: drains the command queue on Unity's main thread.
    /// </summary>
    public class MainThreadPump : MonoBehaviour
    {
        public MainThreadPump(IntPtr ptr) : base(ptr) { }

        private float _lastUnloadTime = -9999f;

        private void Update()
        {
            string cmd;
            while (ModKitRuntimePlugin.CommandQueue.TryDequeue(out cmd))
            {
                try { Execute(cmd); }
                catch (Exception ex)
                {
                    ModKitRuntimePlugin.Log.LogError("command '" + cmd + "' failed: " + ex.Message);
                    ModKitRuntimePlugin.LastResult = "{\"ok\":false,\"error\":\"" + Escape(ex.Message) + "\"}";
                }
            }
        }

        private void Execute(string cmd)
        {
            if (cmd.Equals("unload", StringComparison.OrdinalIgnoreCase))
            {
                DoUnload(false);
            }
            else if (cmd.Equals("unload:force", StringComparison.OrdinalIgnoreCase))
            {
                DoUnload(true);
            }
            else if (cmd.Equals("stats", StringComparison.OrdinalIgnoreCase))
            {
                ModKitRuntimePlugin.LastResult = BuildStats(0, 0);
            }
            else if (cmd.StartsWith("setbudget:", StringComparison.OrdinalIgnoreCase))
            {
                int mb;
                if (int.TryParse(cmd.Substring("setbudget:".Length), out mb) && mb > 0)
                {
                    QualitySettings.streamingMipmapsMemoryBudget = mb;
                    ModKitRuntimePlugin.Log.LogInfo("streaming mipmap budget set to " + mb + " MB");
                    ModKitRuntimePlugin.LastResult = "{\"ok\":true,\"budgetMB\":" + mb + "}";
                }
            }
            else
            {
                ModKitRuntimePlugin.LastResult = "{\"ok\":false,\"error\":\"unknown command\"}";
            }
        }

        private void DoUnload(bool force)
        {
            float minGap = ModKitRuntimePlugin.Instance.MinSecondsBetweenUnloads;
            if (!force && (Time.realtimeSinceStartup - _lastUnloadTime) < minGap)
            {
                ModKitRuntimePlugin.LastResult =
                    "{\"ok\":false,\"error\":\"rate-limited\"}";
                return;
            }

            long before = GC.GetTotalMemory(false);
            long monoBefore = UnityEngine.Profiling.Profiler.GetMonoUsedSizeLong();

            // Order matters: drop unreferenced assets first, then collect the
            // managed heap that referenced them.
            Resources.UnloadUnusedAssets();
            GC.Collect();
            GC.WaitForPendingFinalizers();
            GC.Collect();

            _lastUnloadTime = Time.realtimeSinceStartup;

            long after = GC.GetTotalMemory(false);
            long monoAfter = UnityEngine.Profiling.Profiler.GetMonoUsedSizeLong();

            long freedManaged = (before - after) / 1048576;
            long freedMono = (monoBefore - monoAfter) / 1048576;

            ModKitRuntimePlugin.Log.LogInfo(
                "unload complete: managed heap " + (before / 1048576) + " -> " + (after / 1048576) +
                " MB (freed " + freedManaged + " MB), mono freed " + freedMono + " MB");

            ModKitRuntimePlugin.LastResult = BuildStats(freedManaged, freedMono);
        }

        private static string BuildStats(long freedManagedMB, long freedMonoMB)
        {
            var sb = new StringBuilder();
            sb.Append("{\"ok\":true");
            sb.Append(",\"freedManagedMB\":").Append(freedManagedMB);
            sb.Append(",\"freedMonoMB\":").Append(freedMonoMB);
            sb.Append(",\"managedHeapMB\":").Append(GC.GetTotalMemory(false) / 1048576);
            sb.Append(",\"monoUsedMB\":").Append(UnityEngine.Profiling.Profiler.GetMonoUsedSizeLong() / 1048576);
            sb.Append(",\"monoHeapMB\":").Append(UnityEngine.Profiling.Profiler.GetMonoHeapSizeLong() / 1048576);
            sb.Append(",\"totalReservedMB\":").Append(UnityEngine.Profiling.Profiler.GetTotalReservedMemoryLong() / 1048576);
            sb.Append(",\"totalAllocatedMB\":").Append(UnityEngine.Profiling.Profiler.GetTotalAllocatedMemoryLong() / 1048576);
            sb.Append(",\"totalUnusedReservedMB\":").Append(UnityEngine.Profiling.Profiler.GetTotalUnusedReservedMemoryLong() / 1048576);
            sb.Append("}");
            return sb.ToString();
        }

        private static string Escape(string s)
        {
            if (string.IsNullOrEmpty(s)) return "";
            return s.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\n", " ").Replace("\r", " ");
        }
    }
}
