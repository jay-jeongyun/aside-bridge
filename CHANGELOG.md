# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [0.1.0] - 2026-11-22
- `desktop` / `browser` commands (aliases `ad` / `web`): run Vercel agent-desktop and agent-browser outside the sandbox.

First public release, extracted from a tool used daily with the Aside browser agent.

### Added
- `AsideBridge.app`: folder-queue job runner (AppleScript, JXA, shell) outside the agent sandbox,
  token check, STOP switch, heartbeat `status.json`, job log, self-registration as a LaunchAgent,
  headless `--selftest-seconds` mode.
- `AsideBridgeWorker` (`bridged`): resident unix-socket worker started through the bridge so it
  inherits its permissions. Guarded synthetic input (type, paste, key, click, drag, scroll,
  clicktext), window list, front app, idle time, screenshots, Vision OCR with fuzzy text matching,
  wait/watch, clipboard, notifications, sysinfo, menu bar status pill, `--headless` mode.
- `bridgectl.py`: Python 3 standard-library CLI with `--json`, `--bg`, `--legacy`, sequences
  (`seq`) and recipes, exit codes 0/1/2.
- `scripts/build.sh` (swiftc + ad-hoc signing) and `scripts/install.sh` (LaunchAgent install,
  uninstall, status).
- Examples (AppleScript, JXA, OCR, window list, sequence, KakaoTalk case study), agent skill,
  architecture and security docs.

### Changed (compared with the private prototype)
- All paths are configurable (`ASIDEBRIDGE_HOME`, default `~/.asidebridge`); no hard-coded home paths.
- Bundle ids / LaunchAgent label are derived from `BUNDLE_PREFIX` and no longer use an `com.aside.*` id.
- The CLI idle guard defaults to 3 seconds (was disabled); `--idle 0` restores the old behavior.
- `--bg` now works without `--legacy`.
- UI strings and messages in English; OCR languages configurable.
- Removed personal remote-host commands, external tool shims and an unused floating badge.
