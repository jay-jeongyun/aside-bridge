#!/bin/bash
# Build AsideBridge.app and AsideBridgeWorker.app from source with swiftc, then ad-hoc sign them.
#
#   scripts/build.sh                 # -> ./build/
#   BUILD_DIR=/tmp/ab scripts/build.sh
#   BUNDLE_PREFIX=io.github.you scripts/build.sh
#
# Requires: Xcode Command Line Tools (swiftc, codesign). macOS 13+.
# Note: every rebuild of AsideBridge.app produces a new ad-hoc signature, so macOS
# asks again for Accessibility / Automation. Rebuilding only the worker is harmless.
set -euo pipefail

VERSION="0.1.0"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
BUNDLE_PREFIX="${BUNDLE_PREFIX:-io.github.jay-jeongyun}"
TARGET="${TARGET:-}"          # e.g. arm64-apple-macos13 (default: host arch)
WHAT="${1:-all}"              # all | bridge | worker

command -v swiftc >/dev/null || { echo "swiftc not found. Install with: xcode-select --install" >&2; exit 1; }
mkdir -p "$BUILD_DIR"

plist() { # id name display exe
cat <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key><string>$1</string>
	<key>CFBundleName</key><string>$2</string>
	<key>CFBundleDisplayName</key><string>$3</string>
	<key>CFBundleExecutable</key><string>$4</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>$VERSION</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>LSUIElement</key><true/>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSAppleEventsUsageDescription</key><string>AsideBridge runs AppleScript on behalf of your local AI agent to control Mac apps.</string>
</dict>
</plist>
PL
}

build_app() { # src name exe bundle_id display
  local src="$1" name="$2" exe="$3" id="$4" display="$5"
  local app="$BUILD_DIR/$name.app"
  echo "==> $name ($id)"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS"
  plist "$id" "$name" "$display" "$exe" > "$app/Contents/Info.plist"
  local args=(-O -swift-version 5 "$ROOT/$src" -o "$app/Contents/MacOS/$exe")
  [ -n "$TARGET" ] && args+=(-target "$TARGET")
  swiftc "${args[@]}"
  xattr -cr "$app" 2>/dev/null || true   # sandboxed builds may add quarantine
  codesign --force --sign - --identifier "$id" "$app"
  codesign --verify --strict "$app"
  echo "    $app"
}

case "$WHAT" in
  all|bridge|worker) ;;
  *) echo "usage: $0 [all|bridge|worker]" >&2; exit 2 ;;
esac
if [ "$WHAT" != worker ]; then
  build_app src/AsideBridge/main.swift AsideBridge AsideBridge "$BUNDLE_PREFIX.asidebridge" AsideBridge
fi
if [ "$WHAT" != bridge ]; then
  build_app src/AsideBridgeWorker/main.swift AsideBridgeWorker bridged "$BUNDLE_PREFIX.asidebridge.worker" "AsideBridge Worker"
fi
echo "done."
