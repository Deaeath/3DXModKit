// 3DXModKit Runtime - client-side-only enforcement
//
// The host tier refuses manifests that declare network or protocol
// capabilities. This is the same rule enforced a second time, inside the game
// process, where it actually matters: a runtime mod asks the guard to approve
// every Harmony patch target, and the guard refuses anything that resolves
// into a networking, protocol, or account namespace.
//
// Defence in depth is the point. The manifest check can be bypassed by someone
// hand-editing a mod.json; this check cannot, because the patch simply never
// gets applied.

using System;
using System.Collections.Generic;
using System.Reflection;

namespace ThreeDX.ModKit.Runtime
{
    public static class ClientOnlyGuard
    {
        /// <summary>
        /// Namespaces no runtime mod may patch. Matched as a prefix against the
        /// declaring type's full name.
        /// </summary>
        private static readonly string[] ForbiddenNamespaces =
        {
            "System.Net",
            "System.Web",
            "UnityEngine.Networking",
            "Photon",
            "ExitGames",
            "LiteNetLib",
            "Telepathy",
            "Mirror",
            "BestHTTP",
            "WebSocketSharp",
            "SocketIO",
            "Steamworks",
        };

        /// <summary>
        /// Type-name fragments that indicate protocol or account surface even
        /// when the namespace looks innocuous (e.g. a game-specific
        /// "NetworkManager" sitting in the global namespace).
        /// </summary>
        private static readonly string[] ForbiddenTypeFragments =
        {
            "Socket",
            "Packet",
            "Protocol",
            "NetworkManager",
            "Connection",
            "Session",
            "Auth",
            "Login",
            "Credential",
            "Token",
        };

        private static readonly List<string> _denied = new List<string>();

        /// <summary>Every patch target the guard has refused this session.</summary>
        public static IReadOnlyList<string> DeniedTargets { get { return _denied; } }

        /// <summary>
        /// Returns true when patching this member is permitted. Callers must
        /// treat false as fatal for that patch, not as a warning.
        /// </summary>
        public static bool IsPatchAllowed(MethodBase target, out string reason)
        {
            reason = null;

            if (target == null)
            {
                reason = "null patch target";
                return false;
            }

            Type declaring = target.DeclaringType;
            if (declaring == null)
            {
                reason = "patch target has no declaring type";
                return false;
            }

            string full = declaring.FullName ?? declaring.Name;

            foreach (string ns in ForbiddenNamespaces)
            {
                if (full.StartsWith(ns, StringComparison.OrdinalIgnoreCase))
                {
                    reason = "declaring type '" + full + "' is in forbidden namespace '" + ns + "'";
                    Deny(full + "::" + target.Name, reason);
                    return false;
                }
            }

            foreach (string frag in ForbiddenTypeFragments)
            {
                if (declaring.Name.IndexOf(frag, StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    reason = "declaring type '" + declaring.Name + "' matches forbidden fragment '" + frag + "'";
                    Deny(full + "::" + target.Name, reason);
                    return false;
                }
            }

            return true;
        }

        private static void Deny(string target, string reason)
        {
            string entry = target + " (" + reason + ")";
            if (!_denied.Contains(entry)) _denied.Add(entry);
        }
    }
}
