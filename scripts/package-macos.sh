#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
LO_DIR="${ROOT_DIR}/libreoffice"
INSTDIR="${LO_DIR}/instdir"
OUTPUT_DIR="${ROOT_DIR}/dist"
APP_NAME="EUnifyer Office.app"
DMG_NAME="EUnifyer-Office.dmg"
BUNDLE_ID="com.eunifyer.office"
VERSION="${1:-1.0.0}"

echo ">> Packaging EUnifyer Office for macOS..."

mkdir -p "$OUTPUT_DIR"

# Create .app bundle structure
APP_DIR="${OUTPUT_DIR}/${APP_NAME}"
rm -rf "$APP_DIR"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

# Copy instdir contents
cp -R "${INSTDIR}/"* "${APP_DIR}/Contents/"

# Create Info.plist
cat > "${APP_DIR}/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>EUnifyer Office</string>
    <key>CFBundleDisplayName</key>
    <string>EUnifyer Office</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleExecutable</key>
    <string>soffice</string>
    <key>CFBundleIconFile</key>
    <string>main</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "   Created: ${APP_DIR}"

# Create DMG
# Uncomment when ready:
# hdiutil create -volname "EUnifyer Office" -srcfolder "$OUTPUT_DIR" \
#   -ov -format UDZO "${OUTPUT_DIR}/${DMG_NAME}"
# echo "   Created: ${OUTPUT_DIR}/${DMG_NAME}"

# Codesigning (uncomment with real identity):
# codesign --deep --force --verify --verbose \
#   --sign "Developer ID Application: EUnifyer (TEAM_ID)" \
#   "$APP_DIR"
# xcrun notarytool submit "${OUTPUT_DIR}/${DMG_NAME}" \
#   --apple-id "developer@eunifyer.com" \
#   --team-id "TEAM_ID" --wait

echo ">> Packaging complete."
echo "   App: ${APP_DIR}"
