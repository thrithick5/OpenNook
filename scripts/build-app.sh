#!/bin/bash
# OpenNook release build + packaging
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="OpenNook"
BUNDLE_ID="com.opennook.app"
VERSION="1.0.0"
BUILD_DIR=".build/release"
DIST="dist"

echo "==> Stopping running OpenNook instances"
killall OpenNook 2>/dev/null || true
sleep 0.3

rm -rf "$DIST"
mkdir -p "$BUILD_DIR"
mkdir -p "$DIST/$APP_NAME.app/Contents/MacOS"
mkdir -p "$DIST/$APP_NAME.app/Contents/Resources"

echo "==> Writing Info.plist (before compile so it is also embedded into __TEXT,__info_plist)"
cat > "$DIST/$APP_NAME.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>OpenNook</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>com.opennook.url</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>opennook</string>
            </array>
        </dict>
    </array>
    <key>NSCalendarsFullAccessUsageDescription</key><string>OpenNook shows your calendar events in the notch panel.</string>
    <key>NSCalendarsUsageDescription</key><string>OpenNook shows your calendar events in the notch panel.</string>
    <key>NSRemindersFullAccessUsageDescription</key><string>OpenNook displays your reminders in the schedule widget.</string>
    <key>NSCameraUsageDescription</key><string>OpenNook uses the camera for the Mirror widget in the notch panel.</string>
    <key>NSAppleEventsUsageDescription</key><string>OpenNook controls playback in Apple Music, Spotify, and web browsers so the notch shows now-playing info and lets you play/pause/skip.</string>
</dict>
</plist>
PLIST

cat > "$BUILD_DIR/OpenNook.entitlements" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.camera</key><true/>
    <key>com.apple.security.automation.apple-events</key><true/>
    <key>com.apple.security.calendars</key><true/>
    <key>com.apple.security.cs.disable-library-validation</key><true/>
</dict>
</plist>
ENT

echo "==> Building OpenNook (release with embedded __TEXT,__info_plist)"
/Library/Developer/CommandLineTools/usr/bin/swiftc \
    -target arm64-apple-macosx14.0 \
    -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk \
    -O \
    -module-name "$APP_NAME" \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$DIST/$APP_NAME.app/Contents/Info.plist" \
    -o "$BUILD_DIR/$APP_NAME" \
    Sources/OpenNook/*.swift

echo "==> Copying binary and AppIcon"
cp "$BUILD_DIR/$APP_NAME" "$DIST/$APP_NAME.app/Contents/MacOS/$APP_NAME"
if [ -f "assets/AppIcon.icns" ]; then
    cp "assets/AppIcon.icns" "$DIST/$APP_NAME.app/Contents/Resources/AppIcon.icns"
fi

echo "==> Clearing quarantine and codesigning dist app with Camera & AppleEvents entitlements"
xattr -cr "$DIST/$APP_NAME.app"
codesign --force --deep --entitlements "$BUILD_DIR/OpenNook.entitlements" --sign - "$DIST/$APP_NAME.app" 2>/dev/null

echo "==> Installing permanently to /Applications/$APP_NAME.app"
if [ -w "/Applications" ]; then
    rm -rf "/Applications/$APP_NAME.app" 2>/dev/null || true
    cp -R "$DIST/$APP_NAME.app" "/Applications/$APP_NAME.app" 2>/dev/null || true
    xattr -cr "/Applications/$APP_NAME.app" 2>/dev/null || true
    codesign --force --deep --entitlements "$BUILD_DIR/OpenNook.entitlements" --sign - "/Applications/$APP_NAME.app" 2>/dev/null || true
    touch "/Applications/$APP_NAME.app"
fi

echo "==> Registering with macOS LaunchServices"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DIST/$APP_NAME.app" 2>/dev/null || true

echo "==> Creating ZIP distribution"
cd "$DIST"
zip -qry "$APP_NAME.zip" "$APP_NAME.app"

echo "==> Preparing styled DMG staging area"
DMG="$APP_NAME-$VERSION.dmg"
VOL_NAME="$APP_NAME"
DMG_STAGING="dmg-staging"
rm -rf "$DMG_STAGING" "$DMG"
mkdir -p "$DMG_STAGING"

cp -R "$APP_NAME.app" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

# Add 1-click helper script to bypass macOS Gatekeeper and always overwrite stale /Applications/OpenNook.app
cat > "$DMG_STAGING/Open OpenNook.command" << 'CMDEOF'
#!/usr/bin/env bash
echo "✨ Installing & Launching OpenNook..."
DIR="$(cd "$(dirname "$0")" && pwd)"
killall -9 OpenNook 2>/dev/null || true
sleep 0.3
if [ -d "$DIR/OpenNook.app" ]; then
  rm -rf "/Applications/OpenNook.app" 2>/dev/null || true
  /usr/bin/ditto "$DIR/OpenNook.app" "/Applications/OpenNook.app" 2>/dev/null || cp -R "$DIR/OpenNook.app" "/Applications/OpenNook.app" 2>/dev/null || true
fi
if [ -d "/Applications/OpenNook.app" ]; then
  xattr -dr com.apple.quarantine "/Applications/OpenNook.app" 2>/dev/null || true
  xattr -cr "/Applications/OpenNook.app" 2>/dev/null || true
  open -n "/Applications/OpenNook.app"
  echo "🚀 OpenNook is now active at your MacBook Notch and Menu Bar!"
elif [ -d "$DIR/OpenNook.app" ]; then
  xattr -cr "$DIR/OpenNook.app" 2>/dev/null || true
  open -n "$DIR/OpenNook.app"
  echo "🚀 OpenNook is now active at your MacBook Notch and Menu Bar!"
fi
CMDEOF
chmod +x "$DMG_STAGING/Open OpenNook.command"

# Detach any existing mounted volumes with this name
hdiutil detach "/Volumes/$VOL_NAME" -force 2>/dev/null || true

echo "==> Creating authentic Apple UDZO HFS+ disk image (.dmg)"
hdiutil create \
  -volname "$VOL_NAME" \
  -srcfolder "$DMG_STAGING" \
  -ov \
  -format UDZO \
  -fs HFS+ \
  "$DMG" 2>/dev/null || python3 ../scripts/create_udzo_dmg.py "$DMG_STAGING" "$DMG" "$VOL_NAME"

rm -rf "$DMG_STAGING"

cd ..
echo "==> Syncing installers to website/downloads"
mkdir -p website/downloads
cp "$DIST/$DMG" website/downloads/
cp "$DIST/$DMG" website/downloads/OpenNook.dmg
cp "$DIST/$APP_NAME.zip" website/downloads/

echo "==> Verification"
file "$DIST/$APP_NAME.app/Contents/MacOS/$APP_NAME"
file "$DIST/$DMG"
codesign -dv --entitlements - "$DIST/$APP_NAME.app" 2>&1 | head -12 || true
