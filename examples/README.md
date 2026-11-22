# Examples

All examples assume the bridge is installed (`scripts/install.sh install`) and use

```bash
B="python3 ${ASIDEBRIDGE_HOME:-$HOME/.asidebridge}/bridgectl.py"
```

| File | What it shows |
| --- | --- |
| `applescript/visible-apps.applescript` | List visible apps through System Events (needs Automation) |
| `applescript/frontmost-window.applescript` | Name and title of the frontmost window (needs Accessibility) |
| `jxa/window-list.js` | All on-screen windows with bounds, via CoreGraphics from JXA |
| `jxa/ocr-image.js` | OCR an image file with the Vision framework from JXA |
| `jxa/type-unicode.js` | Type any Unicode text with CGEvents (bypasses the input method) |
| `jxa/click.js` | Click at screen coordinates from JXA |
| `jxa/file-to-clipboard.js` | Put a file (not its path) on the clipboard, for pasting into chat apps |
| `seq/textedit-hello.txt` | A guarded multi-step sequence for `bridgectl seq` |
| `apps/kakaotalk/` | Notes and a reader script for a messenger app without an AppleScript dictionary |

Run them:

```bash
$B as -f examples/applescript/visible-apps.applescript
$B jxa -f examples/jxa/window-list.js --json
$B sh "osascript -l JavaScript $PWD/examples/jxa/ocr-image.js /path/to/screenshot.png"
$B wins Safari                      # built-in window list (JSON)
$B ocr --win Safari                 # built-in OCR of a window, even when covered
$B seq -f examples/seq/textedit-hello.txt
```

JXA files that read `argv` must be run with `osascript -l JavaScript FILE ARGS` (through `sh`),
because `bridgectl jxa` passes the script on stdin without arguments.
