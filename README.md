# AsideBridge

**Let a sandboxed AI agent control native macOS apps, safely and locally.**

AsideBridge is a small macOS helper that runs AppleScript, JXA, shell commands, synthetic
keyboard/mouse input, screenshots and OCR **outside** an AI agent's sandbox. It was built for
the agent in the [Aside browser](https://aside.com), whose sandbox blocks Apple Events and
LaunchServices (`osascript` and `open -a` fail with error `-10827`), but it works with any
local agent that can run a Python script and write to a folder: it has also been used with
[Orca](https://github.com/stablyai/orca), and should work with Claude Code, Codex CLI or any other
sandboxed coding agent.

> **Unofficial community tool, not affiliated with At Your Side Inc. / Aside.**
> "Aside" is used only to describe compatibility.

```bash
bridgectl as 'tell application "System Events" to get name of every application process whose visible is true'
bridgectl ocr --win Safari --find "Sign in"      # OCR a window (even when covered), get click coordinates
bridgectl seq -f examples/seq/textedit-hello.txt # guarded multi-step UI sequence in one call
```

## Why

AI agents in browsers and coding tools increasingly run in a macOS sandbox. That is good for
safety, but it means the agent cannot drive desktop apps: no AppleScript to System Events,
no `open -a`, no Accessibility, no screen capture. AsideBridge is a narrow, token-protected
door through that wall:

- **One permission grant.** macOS privacy permissions (Accessibility, Automation, Screen Recording)
  are granted once to the AsideBridge app. Every job it runs inherits them.
- **Fast.** A resident worker answers over a unix socket: AppleScript ~0.17 s, shell ~0.1 s,
  window list / idle / front app ~1 ms, window OCR ~1 s.
- **Guarded input.** Every keyboard/mouse action checks a STOP switch, the lock screen,
  whether the human is using the Mac, and (optionally) which app is in front.
- **Visible.** A menu bar pill turns red while the agent controls the screen, blue for
  background jobs, orange when paused. Every job is logged.
- **No dependencies.** Two small Swift apps built with `swiftc`, and a CLI that uses only the
  Python 3 standard library.

## Works with

| Agent | Status |
| --- | --- |
| [Aside browser](https://aside.com) agent | daily use (the reason this exists) |
| [Orca](https://github.com/stablyai/orca) agents | used |
| Claude Code, Codex CLI, Gemini / Antigravity CLI, other sandboxed agents | should work: anything that can run `python3` and write to `~/.asidebridge` (untested) |

It also gives sandboxed agents a way to run Vercel Labs'
[agent-desktop](https://github.com/vercel-labs/agent-desktop) and
[agent-browser](https://github.com/vercel-labs/agent-browser), which need Accessibility or a
real Chrome that the sandbox normally blocks (see below).

## Security warning

AsideBridge deliberately gives an AI agent the ability to run code **outside its sandbox**
with your user's privacy permissions. Treat it like giving someone your keyboard.

- Local only: it listens on a unix socket and a folder in your home directory, never on the network.
- Every request needs a random token stored in `~/.asidebridge/token` (mode 0600).
  Anything that can read that file can control your Mac as you.
- `touch ~/.asidebridge/STOP` (or the menu bar item) pauses everything instantly.
- Keep human approval for irreversible actions (sending messages, deleting, paying).

Read [docs/security.md](docs/security.md) before installing.

## Install

Requirements: macOS 13+, Xcode Command Line Tools (`xcode-select --install`), Python 3.

```bash
git clone https://github.com/jay-jeongyun/aside-bridge.git && cd aside-bridge
scripts/build.sh                 # builds build/AsideBridge.app + build/AsideBridgeWorker.app (ad-hoc signed)
scripts/install.sh install       # run in Terminal.app, not inside an agent sandbox
```

Then allow **AsideBridge** in System Settings > Privacy & Security > Accessibility (and Screen
Recording for `shot`/`ocr`), and accept the Automation prompt for System Events. Check:

```bash
python3 ~/.asidebridge/bridgectl.py status    # "running": true, "axTrusted": true
```

Uninstall with `scripts/install.sh uninstall` (add `--purge` to delete the token, logs and recipes).

## Usage

```bash
alias bridgectl="python3 ~/.asidebridge/bridgectl.py"

# scripts
bridgectl as 'display notification "hi" with title "AsideBridge"'
bridgectl jxa 'Application("Finder").windows().length'
bridgectl sh 'open -a "System Settings"' --timeout 20
bridgectl as -f script.applescript --json          # full result object
bridgectl sh 'long_job.sh' --bg                    # detached; never blocks the queue

# input (guarded)
bridgectl type 'Hello 안녕 😀'          # any Unicode, input-method safe
bridgectl key cmd+shift+g
bridgectl click 640 400 --expect Safari
bridgectl clicktext 'Continue' --win Safari

# screen
bridgectl wins Safari | front | idle
bridgectl shot --win Safari --out /tmp/s.png
bridgectl wait text 'Done' --win Installer --timeout 30

# control
bridgectl stop | resume | status | daemon restart
```

Exit codes: `0` ok, `1` the command failed, `2` the bridge is unavailable.
Run `bridgectl --help` for every command and option.

## agent-desktop and agent-browser from inside a sandbox

`agent-desktop` (accessibility-tree desktop control: snapshot, then click `@ref`) and
`agent-browser` (CDP browser automation) are great agent tools, but from inside a sandboxed
agent they usually fail: no Accessibility permission, no way to launch Chrome. AsideBridge runs
them in its own context, where those permissions live:

```bash
npm i -g agent-desktop agent-browser          # or point AGENT_DESKTOP_BIN / AGENT_BROWSER_BIN at them
bridgectl desktop snapshot --app Finder       # alias: ad
bridgectl desktop click @s1:e12             # ref from the snapshot
bridgectl browser open https://example.com    # alias: web; uses a dedicated "aside-bridge" session
bridgectl browser snapshot -i
```

Use the bridge's own `as` / `jxa` / `ocr` for quick one-offs, and agent-desktop when you want a
stable element tree to click by reference.

## Using it from the Aside browser (or another agent)

Copy [skill/SKILL.md](skill/SKILL.md) into your agent's skills folder. It teaches the agent
when to use the bridge (`-10827` errors, desktop apps), the commands, and the safety rules.

## How it works

```
 sandboxed agent ──bridgectl.py──┬─ unix socket ──> AsideBridgeWorker (bridged)  fast path
                                 └─ inbox/*.json ─> AsideBridge (LaunchAgent)     fallback
                                                      │ starts the worker, so it inherits
                                                      └ Accessibility / Automation / Screen Recording
```

Details in [docs/architecture.md](docs/architecture.md).

## Project layout

```
src/AsideBridge/main.swift        bridge app: folder queue, LaunchAgent handover, worker launcher
src/AsideBridgeWorker/main.swift  resident worker: socket server, input, windows, capture, OCR
cli/bridgectl.py                  CLI (Python 3 stdlib only)
scripts/build.sh, install.sh      build from source, install/uninstall the LaunchAgent
examples/                         AppleScript, JXA, OCR, window list, sequences, an app case study
skill/SKILL.md                    agent skill
docs/                             architecture, security model, topics
```

## Configuration

| Variable | Default | Used by |
| --- | --- | --- |
| `ASIDEBRIDGE_HOME` | `~/.asidebridge` | all (data dir: token, queue, logs, socket) |
| `ASIDEBRIDGE_WORKER` | `$ASIDEBRIDGE_HOME/app/AsideBridgeWorker.app/Contents/MacOS/bridged` | CLI |
| `ASIDEBRIDGE_IDLE` | `3` | CLI: seconds the user must be idle before input |
| `ASIDEBRIDGE_OCR_LANGS` | `en-US,ko-KR` | worker: Vision OCR languages |
| `BUNDLE_PREFIX` | `io.github.jay-jeongyun` | build/install: bundle ids and LaunchAgent label |

If your agent's sandbox remaps `~`, set `ASIDEBRIDGE_HOME` to the absolute path.

## License

MIT, see [LICENSE](LICENSE). Copyright (c) 2026 jay-jeongyun.

Keywords: Aside browser, AI agent, computer use, macOS automation, AppleScript, JXA,
sandbox, Accessibility, OCR, LaunchAgent.
