# Writing a 3DXModKit mod

A mod is a directory under `mods/` containing a `mod.json` and an entry script.

```
mods/my-mod/
├── mod.json              manifest - identity, tier, capabilities, dependencies
├── config.default.json   defaults (optional)
└── Mod.ps1               entry point
```

---

## 1. The manifest

```json
{
  "id": "my-mod",
  "name": "My Mod",
  "version": "1.0.0",
  "description": "What it does and when it acts.",
  "author": "you",
  "tier": "host",
  "entry": "Mod.ps1",
  "loadPriority": 100,
  "gameVersion": "471",
  "capabilities": ["process.query", "memory.trim.self"],
  "dependencies": [],
  "conflicts": []
}
```

| Field | Notes |
|---|---|
| `id` | kebab-case, unique. This is the config filename and dependency key. |
| `tier` | `host` (external) or `runtime` (in-process). A `host` mod may not declare in-process capabilities; a `runtime` mod must declare `runtime.load`. |
| `loadPriority` | Lower loads first. Ties break on `id`, so ordering is reproducible. |
| `dependencies` | `"other-mod"` or `"other-mod@>=1.2.0"`. Missing dependencies are a load error. |
| `conflicts` | Symmetric — if either side declares it and both are enabled, neither loads. |

Validate before running:

```powershell
.\modkit.ps1 validate
```

---

## 2. Capabilities are the access boundary

The context object is built from your declared capabilities. This is not documentation — the methods are physically absent otherwise.

```powershell
"capabilities": ["process.query"]          # $ctx.GetProcessMemory() exists
                                           # $ctx.PurgeStandbyList()  does NOT
```

See the full catalog:

```powershell
.\modkit.ps1 caps
```

| Capability | Grants |
|---|---|
| `process.query` | `GetGamePid`, `GetProcessMemory`, `GetSystemMemory`, `GetIdleSeconds`, `IsGameForeground`, `IsGameMinimized` |
| `memory.trim.self` | `TrimGame`, `TrimProcess`, `TrimByName` — no elevation needed |
| `memory.trim.system` | `PurgeStandbyList`, `FlushModifiedPageList`, `EmptySystemWorkingSet`, `EmptyAllWorkingSets`, `EmptyAll`, `IsElevated` — admin required |
| `process.priority` | `SetGamePriority` |
| `ipc.runtime` | `SendRuntimeCommand`, `IsRuntimeAvailable` — machine-local named pipe |
| `fs.write.config` | `SaveState`, `LoadState` |
| `ui.console` | logging (always available in practice) |

### Refused unconditionally

`net.*`, `game.protocol.*`, `game.state.*`, `account.*`, `runtime.patch.net*`

There is no override. A manifest declaring any of these fails validation and the mod does not load. Runtime-tier mods are additionally vetted at patch time by `ClientOnlyGuard`.

---

## 3. The entry script

The script is **invoked**, not dot-sourced, so each mod gets its own scope and two mods can define same-named helpers without colliding. It must return a hashtable:

```powershell
@{
    Initialize = {
        param($ctx)
        # subscribe here; do not block
    }

    Shutdown = {
        param($ctx)
        # optional
    }
}
```

### Closures matter

Handlers run later, long after `Initialize` has returned. Capture what you need with `.GetNewClosure()`, and define helpers *before* the handlers that use them:

```powershell
Initialize = {
    param($ctx)
    $cfg = $ctx.Config

    $state = [pscustomobject]@{ Count = 0 }     # reference type - mutations persist

    $doWork = {
        param($reason)
        $state.Count++
        $ctx.Log("worked: $reason (#$($state.Count))")
    }.GetNewClosure()                            # captures $ctx, $cfg, $state

    $ctx.On('game.minimized', {
        param($e)
        & $doWork 'minimized'
    }.GetNewClosure())                           # captures $doWork
}
```

Forgetting `.GetNewClosure()` produces `The variable '$x' cannot be retrieved because it has not been set` when the handler fires.

---

## 4. Events

| Event | Payload | Fires |
|---|---|---|
| `game.started` | `Pid`, `Process` | game process appears |
| `game.stopped` | `Pid` | game process exits |
| `game.focused` | `Pid` | game gains foreground |
| `game.blurred` | `Pid` | game loses foreground |
| `game.minimized` | `Pid` | window minimised |
| `game.restored` | `Pid` | window un-minimised |
| `system.lowmemory` | `AvailPercent`, `AvailGB`, `LoadPercent` | free RAM crosses below the threshold |
| `system.idle` | `IdleSeconds` | no desktop input for the configured period |
| `tick` | `Tick`, `Uptime` | every tick |

All state events are **edge-triggered** — they fire on transition, not on every tick while the condition holds. Use `tick` for anything you need polled.

A handler that throws is logged against your mod id and the loop continues; it will not take down the host or other mods.

---

## 5. Configuration

Three layers, lowest to highest:

1. `config.default.json` in your mod directory
2. the active profile's `config.<mod-id>` block
3. `config/<mod-id>.json` (user override)

Deep-merged on objects; scalars and arrays replace wholesale. The result arrives as `$ctx.Config`.

**Ship complete defaults.** Profiles usually override a subset, and code that reads a key no layer defined will see `$null`.

---

## 6. Testing without the game

Point the host at any process:

```powershell
Start-ModKit -ProfileName aggressive -GameProcessName 'notepad' -LogLevel Debug
```

The host governs the **largest** working set among matching processes, so helpers and crash handlers do not get picked by accident.
