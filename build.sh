#!/bin/bash
# Build SID Jukebox for macOS - .app bundle + .dmg
set -e

cd "$(dirname "$0")"

APP_NAME="SID Jukebox"
BUNDLE_NAME="SIDJukebox"
APP_DIR="${BUNDLE_NAME}.app"
VERSION="1.0"
DMG_NAME="${BUNDLE_NAME}_v${VERSION}.dmg"

echo "==> Building ${APP_NAME} (macOS)..."

# Clean previous build
rm -rf "${APP_DIR}" "${DMG_NAME}" dmg_tmp

# Create .app bundle structure
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources/sids"

# Compile universal binary (x86_64 + arm64)
echo "==> Compiling (arm64)..."
clang -fobjc-arc -w -arch arm64 \
    -framework Cocoa \
    -framework AudioToolbox \
    -framework CoreAudio \
    main.m sid_engine.c \
    -o "${APP_DIR}/Contents/MacOS/${BUNDLE_NAME}_arm64"

echo "==> Compiling (x86_64)..."
clang -fobjc-arc -w -arch x86_64 \
    -framework Cocoa \
    -framework AudioToolbox \
    -framework CoreAudio \
    main.m sid_engine.c \
    -o "${APP_DIR}/Contents/MacOS/${BUNDLE_NAME}_x86_64"

echo "==> Creating universal binary..."
lipo -create \
    "${APP_DIR}/Contents/MacOS/${BUNDLE_NAME}_arm64" \
    "${APP_DIR}/Contents/MacOS/${BUNDLE_NAME}_x86_64" \
    -output "${APP_DIR}/Contents/MacOS/${BUNDLE_NAME}"
rm "${APP_DIR}/Contents/MacOS/${BUNDLE_NAME}_arm64" "${APP_DIR}/Contents/MacOS/${BUNDLE_NAME}_x86_64"

# Copy SID files
echo "==> Copying SID files..."
cp sids/*.sid "${APP_DIR}/Contents/Resources/sids/"
cp AppIcon.icns "${APP_DIR}/Contents/Resources/"

# Create Info.plist
cat > "${APP_DIR}/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.serkantanriverdi.sidjukebox</string>
    <key>CFBundleName</key>
    <string>SID Jukebox</string>
    <key>CFBundleDisplayName</key>
    <string>SID Jukebox</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleExecutable</key>
    <string>SIDJukebox</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleSignature</key>
    <string>????</string>
    <key>LSMinimumSystemVersion</key>
    <string>10.13</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>SID File</string>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>sid</string>
            </array>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Create PkgInfo
echo -n "APPL????" > "${APP_DIR}/Contents/PkgInfo"

echo "==> App bundle created: ${APP_DIR}"

# Create DMG
echo "==> Creating DMG..."
mkdir -p dmg_tmp
cp -r "${APP_DIR}" dmg_tmp/

hdiutil create -volname "${APP_NAME}" \
    -srcfolder dmg_tmp \
    -ov -format UDZO \
    "${DMG_NAME}"

rm -rf dmg_tmp

echo ""
echo "==> Done!"
echo "    App: ${APP_DIR}"
echo "    DMG: ${DMG_NAME}"
echo ""
echo "    Run: open \"${APP_DIR}\""
echo "    Or distribute: ${DMG_NAME}"
