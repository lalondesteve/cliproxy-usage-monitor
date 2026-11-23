#!/usr/bin/env bash
# Wraps the release binary into build/UsageMonitor.app and signs it.
# Run through `make app`, which builds the binary first.
#
# CODESIGN_IDENTITY selects the signing identity; the default "-" is ad-hoc.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
IDENTITY="${CODESIGN_IDENTITY:--}"
BUNDLE_ID="ca.lals.usage-monitor"
APP="$ROOT/build/UsageMonitor.app"

BIN_DIR="$(cd "$ROOT" && swift build -c release --show-bin-path)"
BIN="$BIN_DIR/UsageMonitor"
if [[ ! -x "$BIN" ]]; then
  echo "error: $BIN not found; run 'swift build -c release' first" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/UsageMonitor"
cp "$ROOT"/assets/logos/*.svg "$APP/Contents/Resources/"
cp "$ROOT/assets/icons/compact.svg" "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>UsageMonitor</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>UsageMonitor</string>
  <key>CFBundleDisplayName</key><string>Usage Monitor</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <!-- The proxies are plain http:// over NetBird (WireGuard). Without this, App
       Transport Security refuses every http:// request and Test says the server
       can't be reached. -->
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsArbitraryLoads</key><true/></dict>
  <key>NSLocalNetworkUsageDescription</key><string>Usage Monitor reads your cliproxy and ocgo-proxy servers on your private network.</string>
</dict>
</plist>
PLIST
plutil -lint -s "$APP/Contents/Info.plist"

codesign --force --sign "$IDENTITY" --timestamp=none \
  --identifier "$BUNDLE_ID" "$APP"
codesign --verify --strict "$APP"
echo "built $APP (signed with identity '$IDENTITY')"
