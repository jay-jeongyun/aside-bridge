# Architecture

## The problem: error -10827 inside an agent sandbox

Agents such as the one in the Aside browser run their shell inside a macOS sandbox
(`sandbox-exec` style profile). The profile typically denies:

- **Apple Events** to other apps. `osascript -e 'tell application "System Events" ...'` fails.
- **LaunchServices** lookups and launches. `open -a Safari` fails with
  `LSOpenURLsWithRole() failed with error -10827` (`kLSServerCommunicationErr`), because the
  sandboxed process cannot talk to the `lsd` / `launchservicesd` services.
- `launchctl bootstrap` into the GUI domain, so the agent cannot install a helper by itself.
- Inherited privacy (TCC) permissions: even if the parent app has Accessibility or Screen
  Recording, a sandboxed child usually does not get them for arbitrary binaries.

The sandbox CAN still read and write files in the user's home directory and connect to a unix
socket it is allowed to reach. AsideBridge uses exactly that.

## Components

```
┌──────────────── agent sandbox ─────────────────┐
│ bridgectl.py (Python 3 stdlib)                 │
│   1. connect ~/.asidebridge/run/bridged.sock   │──────────┐ fast path (~1-200 ms)
│   2. or write ~/.asidebridge/inbox/<id>.json   │──┐       │
└────────────────────────────────────────────────┘  │       │
                                                    ▼       ▼
                    ┌───────────────────────┐   ┌──────────────────────────┐
  launchd ─────────>│ AsideBridge.app       │──>│ AsideBridgeWorker.app    │
  (LaunchAgent,     │ folder queue, 0.3 s   │   │ (bridged) unix socket    │
   KeepAlive, Aqua) │ poll, serial jobs     │   │ server, concurrent       │
                    └───────────────────────┘   └──────────────────────────┘
                         │ osascript / zsh            │ CGEvent, CGWindowList,
                         ▼                            ▼ screencapture, Vision
                       other apps (Apple Events, Accessibility, Screen Recording)
```

### AsideBridge.app (the bridge)

- Runs as a per-user LaunchAgent (`RunAtLoad`, `KeepAlive` on failure, Aqua session only),
  so it lives in the user's GUI login session, outside any sandbox.
- If opened by hand from Finder and a LaunchAgent plist exists, it bootstraps the agent with
  `launchctl` and exits, so the launchd copy is the only one running.
- Polls `inbox/` every 0.3 s. A job is claimed with an atomic `rename()` into `work/`,
  run with `osascript` / `osascript -l JavaScript` / `zsh`, and the result is written
  atomically to `outbox/<id>.json`. Output is capped at 1 MB, timeouts at 900 s.
- Writes a heartbeat to `status.json` every 5 s (`running` = heartbeat younger than 20 s).
- Kinds: `applescript`, `jxa`, `shell`, `ping`, `quit` (exit; launchd restarts it).
- Jobs run serially. A job stuck on a permission prompt blocks the queue, which is why
  `bridgectl --bg` launches the script detached and polls for its result files instead.

### AsideBridgeWorker.app (`bridged`, the resident worker)

- Started **through the bridge** (`bridgectl daemon start` submits a shell job that runs it).
  Because macOS attributes child processes to the responsible app, the worker uses
  AsideBridge's Accessibility, Automation and Screen Recording grants.
- Listens on `run/bridged.sock` (mode 0600). Protocol: one JSON object per connection, newline
  terminated; one JSON reply. Each connection is handled on its own thread.
- Commands: `ping as jxa sh type paste key click dclick rclick move drag scroll clicktext clip
  front idle wins shot ocr wait watch activate notify sysinfo quit`.
- OCR uses `VNRecognizeTextRequest` (accurate level; the fast level is Latin-only) and returns
  text with screen-point coordinates. `--find` uses an LCS similarity score (default ≥ 0.75), so
  small OCR mistakes still match. Window captures use `screencapture -l <windowid>`, which works
  even when the window is covered.
- Shows a menu bar pill (red / blue / orange / gray) and offers STOP / Resume.
- Housekeeping: deletes screenshots and work files older than 2 days, rotates logs over 5 MB.

### Why two processes

The bridge's ad-hoc code signature is what macOS uses to remember the privacy grants.
Rebuilding the bridge invalidates them and the user must approve again. The worker holds all
the frequently changing logic, so it can be rebuilt and restarted freely while the bridge
stays untouched. If the worker is down, `as`/`jxa`/`sh` fall back to the folder queue.

### Permission inheritance in practice

| Need | Granted to | Used by |
| --- | --- | --- |
| Accessibility | AsideBridge | input events, System Events UI scripting |
| Automation (Apple Events) | AsideBridge, per target app | `as`, `jxa` |
| Screen Recording | AsideBridge | `shot`, `ocr`, `clicktext`, `wait text`, `watch` |

Grant them once in System Settings > Privacy & Security. `bridgectl status` reports
`axTrusted`.

## Files in `$ASIDEBRIDGE_HOME` (default `~/.asidebridge`)

| Path | Purpose |
| --- | --- |
| `token` | shared secret, 0600 |
| `status.json` | bridge heartbeat |
| `STOP` | pause switch: while present, no queue job and no input action runs |
| `inbox/ outbox/ work/` | folder queue |
| `run/bridged.sock` | worker socket |
| `logs/bridge.log`, `logs/bridged.log` | job logs |
| `recipes.json` | remembered `seq` recipes |
| `app/` | installed apps (by `scripts/install.sh`) |
| `bridgectl.py` | installed CLI |
