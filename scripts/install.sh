#!/bin/bash
# Install / uninstall AsideBridge as a per-user LaunchAgent.
#
#   scripts/install.sh install     # build (if needed), copy to $ASIDEBRIDGE_HOME, load LaunchAgent
#   scripts/install.sh uninstall   # unload LaunchAgent, remove plist and apps (keeps data)
#   scripts/install.sh uninstall --purge   # also delete $ASIDEBRIDGE_HOME (token, logs, recipes)
#   scripts/install.sh status
#
# Run this from Terminal.app, NOT from inside an agent sandbox: `launchctl bootstrap`
# is blocked there. Data dir: $ASIDEBRIDGE_HOME (default ~/.asidebridge).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ABH="${ASIDEBRIDGE_HOME:-$HOME/.asidebridge}"
BUNDLE_PREFIX="${BUNDLE_PREFIX:-io.github.jay-jeongyun}"
LABEL="$BUNDLE_PREFIX.asidebridge"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
DOMAIN="gui/$(id -u)"

install() {
  if [ ! -d "$BUILD_DIR/AsideBridge.app" ] || [ ! -d "$BUILD_DIR/AsideBridgeWorker.app" ]; then
    BUILD_DIR="$BUILD_DIR" BUNDLE_PREFIX="$BUNDLE_PREFIX" "$ROOT/scripts/build.sh"
  fi
  mkdir -p "$ABH/app" "$ABH/logs" "$HOME/Library/LaunchAgents"
  chmod 700 "$ABH"
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  rm -rf "$ABH/app/AsideBridge.app" "$ABH/app/AsideBridgeWorker.app"
  cp -R "$BUILD_DIR/AsideBridge.app" "$BUILD_DIR/AsideBridgeWorker.app" "$ABH/app/"
  xattr -cr "$ABH/app" 2>/dev/null || true
  install -m 755 "$ROOT/cli/bridgectl.py" "$ABH/bridgectl.py"
  cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$LABEL</string>
	<key>ProgramArguments</key>
	<array><string>$ABH/app/AsideBridge.app/Contents/MacOS/AsideBridge</string></array>
	<key>EnvironmentVariables</key>
	<dict><key>ASIDEBRIDGE_HOME</key><string>$ABH</string></dict>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
	<key>ThrottleInterval</key><integer>60</integer>
	<key>LimitLoadToSessionType</key><string>Aqua</string>
	<key>ProcessType</key><string>Interactive</string>
	<key>StandardOutPath</key><string>$ABH/logs/launchd.log</string>
	<key>StandardErrorPath</key><string>$ABH/logs/launchd.log</string>
</dict>
</plist>
PL
  plutil -lint "$PLIST" >/dev/null
  launchctl bootstrap "$DOMAIN" "$PLIST"
  cat <<MSG
Installed.
  app:      $ABH/app/AsideBridge.app
  cli:      $ABH/bridgectl.py
  agent:    $PLIST
Next:
  1. Allow AsideBridge in System Settings > Privacy & Security > Accessibility
     (and Screen Recording if you want shot/ocr), and accept the Automation prompt.
  2. Check:  python3 "$ABH/bridgectl.py" status     ("axTrusted": true)
MSG
}

uninstall() {
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  pkill -f "$ABH/app/AsideBridgeWorker.app/Contents/MacOS/bridged" 2>/dev/null || true
  rm -rf "$ABH/app" "$ABH/bridgectl.py"
  if [ "${1:-}" = "--purge" ]; then rm -rf "$ABH"; echo "Removed $ABH"; fi
  echo "Uninstalled $LABEL. Remove AsideBridge from Privacy & Security lists manually if you like."
}

case "${1:-}" in
  install) install ;;
  uninstall) shift; uninstall "${1:-}" ;;
  status) launchctl print "$DOMAIN/$LABEL" 2>/dev/null | grep -E 'state|pid' || echo "not loaded" ;;
  *) echo "usage: $0 install | uninstall [--purge] | status" >&2; exit 2 ;;
esac
