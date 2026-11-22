# AsideBridge for Windows

**Let an AI agent drive the Windows desktop through a narrow, token-protected local door.**

AsideBridge for Windows is the Windows counterpart of the macOS AsideBridge in this repository. It is
a small set of Windows PowerShell scripts that run in **your interactive desktop session**, started by
Task Scheduler at logon, and execute jobs that an agent drops into a folder: PowerShell, UI Automation,
Unicode keyboard and mouse input, window management, screenshots, OCR and Chromium DevTools.
It was built for the agent in the [Aside browser](https://aside.com) on Windows, and works with any local
agent that can run a Python script (or PowerShell) and write to a folder.

> **Unofficial community tool, not affiliated with At Your Side Inc. / Aside.**
> "Aside" is used only to describe compatibility.

```powershell
python bridgectl.py wins Notepad                         # window list: title, pid, rect, capture protection
python bridgectl.py uia tree --win "Notepad" --depth 4   # UI Automation tree with click coordinates
python bridgectl.py type "Hello 안녕 😀"                   # Unicode SendInput, IME-independent
python bridgectl.py ocr --win "Notepad" --find "Hello"   # OCR a window (even when covered), get coordinates
```

## Why

On Windows, only processes running inside the logged-in user's interactive desktop session can see
and drive that user's windows. Windows services run in the isolated **session 0**; SSH and other remote
shells, and scheduled tasks set to "run whether the user is logged on or not", also run outside the
interactive desktop. From there, `SendInput`, window enumeration, UI Automation, screen capture and
launching GUI apps fail or reach the wrong desktop. An agent's shell is often in such a context, or is
not elevated and therefore cannot touch elevated windows.

AsideBridge closes that gap with a process that lives in the right place:

- **Right session.** A logon task with an interactive principal runs the bridge in your desktop session,
  hidden (`wscript` + a one-line `.vbs`), optionally with administrator rights.
- **Fast and parallel.** Three warm PowerShell workers keep the native helpers loaded: a command takes
  about 0.2 s instead of about 1.2 s for a cold PowerShell. Each job has its own timeout; a stuck job is
  killed and its worker restarted, and never blocks the others.
- **Guarded input.** Every keyboard/mouse action checks a STOP switch, the lock screen / UAC secure
  desktop, whether you are using the PC (idle guard with a notification), and optionally which window
  is in front.
- **No dependencies.** Built-in Windows PowerShell 5.1, .NET Framework and WinRT only. The CLI uses the
  Python 3 standard library; a PowerShell client is included for PCs without Python.

## Security warning

AsideBridge deliberately lets an AI agent run code in your desktop session, **by default with
administrator rights**. Treat it like giving someone your keyboard and an admin prompt.

- Local only: jobs arrive through a folder under `%LOCALAPPDATA%`; nothing listens on the network.
  (`start-browser-cdp.ps1` opens a DevTools port on 127.0.0.1 only when you run it.)
- Every job needs a random 48-hex-character token in `<home>\token`. The folder is restricted to your
  user, SYSTEM and Administrators. Anything that can read the token can control your PC as you.
- `bridgectl stop` (or creating `<home>\STOP`) pauses everything at once; delete it (`bridgectl resume`) to continue.
- Install with `-Limited` if you do not need elevated control (see below).
- Keep human approval for irreversible actions (sending messages, deleting, paying) in the agent's rules.
- Logs (`<home>\logs\bridge.log`) contain a 160-character preview of each job, and screenshots in
  `<home>\work` contain whatever was on screen. Both are cleaned up after 2 days / rotated at 5 MB.

Read [../docs/security.md](../docs/security.md); the threat model is the same as on macOS.

## Requirements

- Windows 11 or Windows 10, x64 or ARM64 (it has been used on Windows 11 Pro x64, Windows 11 ARM64 and Windows 10 Home).
- Windows PowerShell 5.1 (built in). PowerShell 7 is not required and not used by the bridge.
- Optional: Python 3 for `bridgectl.py` (the Aside runtime's Python works). Without Python use `bridgectl.ps1`.
- Optional: OCR languages are the Windows language packs you have installed
  (Settings > Time & language > Language & region).

## Install

Run this yourself in a normal PowerShell window, not from inside an agent. It asks for UAC once.

```powershell
git clone https://github.com/jay-jeongyun/aside-bridge.git; cd aside-bridge
Get-ChildItem .\windows -Recurse | Unblock-File
Set-ExecutionPolicy -Scope Process Bypass -Force
.\windows\scripts\install.ps1                 # add -Limited for no admin rights, -Dir D:\ab for another folder
python "$env:LOCALAPPDATA\aside-bridge\bridgectl.py" status    # "running": true, "admin": true
```

The installer copies `windows\src` to `<home>\app`, the CLI to `<home>`, creates the token, locks the
folder ACL, and registers two tasks for your user:

| Task | Trigger | Does |
| --- | --- | --- |
| `AsideBridge` | at logon | starts `bridge.ps1` hidden in your interactive session (RunLevel Highest, or Limited with `-Limited`) |
| `AsideBridge-Watchdog` | every 5 minutes | starts the bridge again if it died; exits at once if it is running (single-instance mutex) |

Optional self test (opens Notepad and types into it; keep your hands off for 20 s):
`powershell -ExecutionPolicy Bypass -File .\windows\scripts\selftest.ps1`

Uninstall: `.\windows\scripts\uninstall.ps1` (elevated if installed with admin rights); add `-Purge` to
delete `<home>` (token, logs, recipes).

`-Limited` installs are not elevated and do not need UAC; such a bridge cannot control elevated windows
or write HKLM. This mode has seen less testing than the default.

## Usage

```powershell
function bridgectl { python "$env:LOCALAPPDATA\aside-bridge\bridgectl.py" @args }

# scripts (run with the bridge's rights)
bridgectl ps 'Get-Process | Sort-Object CPU -Descending | Select-Object -First 5'
bridgectl ps -f script.ps1 --timeout 120 --json
bridgectl cmd 'ipconfig'

# look
bridgectl wins | front | idle | sysinfo
bridgectl uia tree --win "Settings" --depth 5
bridgectl shot --win "Notepad" --out C:\temp\n.png
bridgectl ocr --win "Notepad" --find "Save"
bridgectl wait text "Done" --win "Installer" --timeout 30

# act (guarded)
bridgectl uia action --win "Notepad" --name "Save" --type Button --action invoke
bridgectl activate "Notepad"
bridgectl type "Hello 안녕 😀"
bridgectl paste "a long text"              # via clipboard, restores the old clipboard
bridgectl key ctrl+shift+s
bridgectl click 640 400 --expect Notepad
bridgectl clicktext "Continue" --win "Setup"

# apps, windows, dialogs, registry, browsers
bridgectl run --name "Calculator"          # Start menu app, normal user rights
bridgectl win max "Notepad"
bridgectl filedlg "C:\temp\report.txt"
bridgectl reg get "HKCU:\Control Panel\Desktop" WallPaper
.\windows\scripts\start-browser-cdp.ps1 edge; bridgectl cdp tabs --port 9223

# many steps in one job; stops at the first failure with a screenshot path
bridgectl seq -f windows\examples\seq\notepad-hello.txt
bridgectl recipe list

# control
bridgectl stop | resume | status | quit
```

Coordinates are physical pixels (the bridge is DPI aware), the same space for UI Automation, capture,
OCR and input. Exit codes: `0` ok, `1` the command failed, `2` the bridge is unavailable.
Run `bridgectl --help` for every command and option.

## Commands compared with macOS

The Windows CLI accepts the macOS names and option spellings (`--win`, `--out`, `--region`) where the
concept is the same. Windows-only names from the original tool still work as aliases.

| macOS `bridgectl` | Windows `bridgectl` | Notes |
| --- | --- | --- |
| `as` / `jxa` | `uia ...`, `ps` | no AppleScript; UI Automation is the Windows equivalent of AX scripting |
| `sh` | `ps` (alias `sh`), `cmd` | PowerShell 5.1 / cmd.exe |
| `type`, `paste`, `key` | `type`, `paste`, `key` (alias `keys`) | Unicode `SendInput` |
| `click` `dclick` `rclick` `move` `drag` | same | |
| `scroll DY [DX]` | `scroll X Y LINES [HLINES]` | Windows needs a position |
| `clicktext` | `clicktext` | OCR + click |
| `wins`, `front`, `idle` | `wins` (alias `windows`), `front`, `idle` | |
| `activate APP` | `activate TITLE` (alias `focus`) | by window title |
| `shot`, `ocr` | `shot`, `ocr` (+ `ocr PATH` for files) | `--bg` uses PrintWindow for covered windows |
| `wait text\|gone-text\|window\|gone-window` | same | |
| `watch` | `watch` | Windows waits until the area changes |
| `clip`, `notify`, `sysinfo` | same | `notifications` reads the toast history |
| `seq`, `recipe` | same | recipes are files in `<home>\recipes` |
| `stop`, `resume`, `status`, `version`, `quit` | same | `quit` stops the bridge; the watchdog restarts it within 5 min |
| `daemon ...` | not needed | the worker pool is managed by the bridge |
| `desktop` / `browser` | not ported | use `cdp` for Chromium browsers |
| | `win`, `run`, `filedlg`, `reg`, `cdp`, `steps` | Windows only |

## Configuration

| Item | Default | Meaning |
| --- | --- | --- |
| `ASIDEBRIDGE_HOME` | `%LOCALAPPDATA%\aside-bridge` | data and install folder (CLI also uses its own folder if it holds a token) |
| `<home>\settings.json` `idleGuardSec` | `3` | seconds you must be idle before input (0 disables) |
| `idleWaitSec` | `20` | how long input waits for you before `USER_ACTIVE` |
| `stepShots` | `false` | save a half-size screenshot before/after input steps to `work\steps` (see `bridgectl steps`) |
| `ocrLang` | `""` | OCR language tag such as `en-US`; empty = your profile languages |
| `sysinfoServices` | `[]` | service names whose status `sysinfo` should report (missing services report `null`) |

If your agent's sandbox cannot reach `%LOCALAPPDATA%`, install with `-Dir` to a folder it can reach and
set `ASIDEBRIDGE_HOME` for the agent.

## Limits

- Lock screen, UAC prompts and Ctrl+Alt+Del run on the secure desktop: no input or capture (`LOCKED`).
- Windows with display affinity (capture protection, common in managed work apps) capture as black.
  The bridge reports it; do not try to bypass it.
- Apps with a thin UI Automation tree (some x64 apps under ARM64 emulation, custom-drawn UIs): use
  `ocr` coordinates with `click`/`type`.
- A `ps` script with a top-level `return` ends without output.
- `filedlg` confirmation is not always reliable on every dialog; verify the result.

## How it works

```
 agent ──bridgectl.py / .ps1──> <home>\inbox\<id>.json
                                     │ token check, STOP check, log
         Task Scheduler (logon) ──> bridge.ps1  (interactive session, mutex, heartbeat status.json)
                                     ├─> warm worker w1..w3 (worker.ps1 -> runner.ps1)   ~0.2 s
                                     └─> fresh runner.ps1 when all workers are busy
                                            │ SendInput, UI Automation, PrintWindow, Windows.Media.Ocr
                                            ▼
                                     <home>\outbox\<id>.json
```

## Layout

```
windows/src/bridge.ps1        main loop: queue, token, workers, timeouts, heartbeat, housekeeping
windows/src/worker.ps1        warm worker
windows/src/runner.ps1        runs one job (all commands)
windows/src/lib/              Common.ps1 (OCR, UI Automation), Native.cs / Native2.cs (input, windows, capture)
windows/src/settings.json     default settings (copied to <home> once)
windows/cli/                  bridgectl.py (Python 3 stdlib), bridgectl.ps1 (no Python)
windows/scripts/              install.ps1, uninstall.ps1, selftest.ps1, start-browser-cdp.ps1
windows/skill/SKILL.md        agent skill
windows/examples/seq/         sample sequence
```

## License

MIT, see [../LICENSE](../LICENSE).
