#!/bin/zsh
# Build the native SiberLights menu bar app and bundle it into a signed .app.
# Usage: ./build.sh [install]
#   install -> also copy to /Applications and relaunch
set -e
cd "$(dirname "$0")"

swift build -c release
BIN=".build/release/SiberLights"
APP="build/SiberLights.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/SiberLights"
echo -n "APPL????" > "$APP/Contents/PkgInfo"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>SiberLights</string>
	<key>CFBundleDisplayName</key>
	<string>SiberLights</string>
	<key>CFBundleIdentifier</key>
	<string>com.siber.siberlights.native</string>
	<key>CFBundleExecutable</key>
	<string>SiberLights</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>2.0</string>
	<key>CFBundleVersion</key>
	<string>2.0</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSMicrophoneUsageDescription</key>
	<string>siberLights uses the audio input to sync the LED strip with music.</string>
	<key>NSAppleEventsUsageDescription</key>
	<string>siberLights checks whether Music is playing to switch on a music effect automatically.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" 2>&1 | grep -v "replacing" || true
echo "built $APP"

if [[ "$1" == "install" ]]; then
    pkill -x SiberLights 2>/dev/null || true
    sleep 1
    rm -rf "/Applications/SiberLights.app"
    ditto "$APP" "/Applications/SiberLights.app"
    codesign --force --deep --sign - "/Applications/SiberLights.app" 2>&1 | grep -v "replacing" || true
    open "/Applications/SiberLights.app"
    echo "installed to /Applications and launched"
fi
