#!/bin/bash
# Builds Herdbar and installs it as ~/Applications/Herdbar.app.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="${HERDBAR_APP:-$HOME/Applications/Herdbar.app}"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Herdbar"

# Replace a running copy.
osascript -e 'tell application id "com.minorkey.herdbar" to quit' >/dev/null 2>&1 || true

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN" "$APP/Contents/MacOS/Herdbar"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Herdbar</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>com.minorkey.herdbar</string>
    <key>CFBundleName</key><string>Herdbar</string>
    <key>CFBundleDisplayName</key><string>Herdbar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.2</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>Personal tool.</string>
</dict>
</plist>
PLIST
# Sign with HERDBAR_SIGN_IDENTITY if set, else the first code-signing certificate in the
# Keychain, else ad hoc ("-"). A real certificate gives the app a stable identity, so macOS
# permissions such as Keychain access survive rebuilds.
IDENTITY="${HERDBAR_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' 'NF>=3 {print $2; exit}')}"
IDENTITY="${IDENTITY:--}"
if [[ "$IDENTITY" == "Developer ID Application"* ]]; then
    # What Apple's notary service requires of apps given to other people.
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
else
    codesign --force --sign "$IDENTITY" "$APP"
fi
if [ "$IDENTITY" = "-" ]; then echo "Signed ad hoc (no certificate found)"; else echo "Signed with: $IDENTITY"; fi

echo "Installed $APP"
