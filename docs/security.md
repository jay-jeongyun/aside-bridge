# Security model

AsideBridge is a deliberate hole in a sandbox. Understand what it protects and what it does not.

## Threat model

- **Trusted:** the local user, and the agent the user chose to connect.
- **Protected against:** other local processes or users that cannot read your home directory;
  the network (nothing listens on TCP/UDP); runaway automation while you use the Mac.
- **Not protected against:** anything running as your user that can read
  `~/.asidebridge/token`; a prompt-injected agent that you have connected. The bridge executes
  whatever an authenticated caller sends. Keep human approval for irreversible actions in the
  agent's own rules (see `skill/SKILL.md`).

## Controls

| Control | Detail |
| --- | --- |
| Token | 48 hex chars from `SecRandomCopyBytes`, file mode 0600. Required on every queue job and socket request; mismatches are rejected and logged. |
| Local transport | Folder queue and unix socket under a 0700 directory; socket mode 0600. No network listener. |
| STOP switch | `touch ~/.asidebridge/STOP`, `bridgectl stop`, or the menu bar item. The bridge stops taking queue jobs and every input action fails with `STOPPED`. Remove the file (`bridgectl resume`) to continue. |
| Input guard | Before each input action: STOP file, lock screen (`LOCKED`), user idle time (default 3 s, waits up to 20 s with a notification, then `USER_ACTIVE`), optional expected front app (`FRONT_CHANGED`). `--force` skips it. |
| Visibility | Menu bar pill: red = controlling the screen, blue = background job, orange = paused. |
| Audit log | Every job and request is logged with time, kind, duration, result and a 160-char script preview in `logs/bridge.log` / `logs/bridged.log`. Logs may contain what your scripts contain; they are rotated at 5 MB. |
| Limits | Timeouts 1-900 s; output capped at 1 MB (queue) / 2 MB (socket). |
| Kill | `bridgectl quit` restarts the bridge, `bridgectl daemon stop` stops the worker, `scripts/install.sh uninstall` removes everything. |

## Recommendations

1. Install only on a Mac you control, for your own user.
2. Do not put `~/.asidebridge` on a shared or synced volume.
3. Review `logs/` occasionally.
4. Rotate the token by deleting `token` and restarting the bridge (`bridgectl quit`); restart the worker afterwards (`bridgectl daemon restart`).
5. Give the agent explicit rules: show the recipient and text before sending anything,
   never pay or delete without confirmation, never use `--force` unless asked.
6. Remove AsideBridge from Privacy & Security lists when you uninstall.

## Reporting

Please report security issues privately through GitHub Security Advisories on the repository
rather than in public issues.
