#!/usr/bin/env bash
# Wraps muse-dev in a minimal .app bundle so macOS treats it as its own app for Bluetooth
# permission. A bare command-line tool launched from another app (an IDE, an agent host) is
# attributed to that app, and macOS kills it at the first CoreBluetooth call if that app has no
# Bluetooth usage string.
#
#   ./make-app.sh            build .build/MuseDev.app
#   open .build/MuseDev.app --stdout log --stderr log --args pair
set -euo pipefail
cd "$(dirname "$0")"
swift build -c debug >/dev/null
APP=.build/MuseDev.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/debug/muse-dev "$APP/Contents/MacOS/muse-dev"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>dev.audiocompanion.muse-dev</string>
	<key>CFBundleName</key>
	<string>Muse Dev</string>
	<key>CFBundleExecutable</key>
	<string>muse-dev</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSBluetoothAlwaysUsageDescription</key>
	<string>Muse Dev advertises this Mac as a Muse gadget so the Muse app on your iPhone can pair with it.</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "$APP"
