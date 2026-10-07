#!/bin/bash
# Builds the release, packages it as Fan Control.app and installs it into /Applications
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c release

APP="$ROOT/build/Fan Control.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/FanControl "$APP/Contents/MacOS/FanControl"
cp .build/release/fancontrold .build/release/fanctl "$APP/Contents/Resources/"
cp scripts/install-helper.sh scripts/uninstall-helper.sh "$APP/Contents/Resources/"
# The icon is pre-rendered by scripts/make-icon.sh.
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>local.fancontrol.app</string>
	<key>CFBundleName</key>
	<string>Fan Control</string>
	<key>CFBundleExecutable</key>
	<string>FanControl</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
EOF

# Ad-hoc sign so macOS agrees to run it on Apple Silicon.
codesign --force --sign - "$APP/Contents/Resources/fancontrold" "$APP/Contents/Resources/fanctl"
codesign --force --sign - "$APP"


# Install into /Applications: quit the running copy (fans go back to auto), then replace it.
INSTALLED="/Applications/Fan Control.app"
osascript -e 'tell application id "local.fancontrol.app" to quit' >/dev/null 2>&1 || true
for _ in $(seq 1 50); do
    pgrep -x FanControl >/dev/null || break
    sleep 0.1
done
# The app refused to quit (e.g. a dialog is open): force-stop it, then return the fans to auto
# ourselves, because a force-stopped app never gets to do that.
if pgrep -x FanControl >/dev/null; then
    pkill -x FanControl || true
    sleep 0.5
    "$APP/Contents/Resources/fanctl" set all auto >/dev/null 2>&1 || true
fi
rm -rf "$INSTALLED"
# Move it to /Applications outright; a second copy with the same name makes macOS open the wrong one.
ditto "$APP" "$INSTALLED"
rm -rf "$APP"
echo "Installed: $INSTALLED"
