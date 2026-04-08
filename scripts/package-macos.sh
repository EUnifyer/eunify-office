#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
LO_DIR="${ROOT_DIR}/libreoffice"
INSTDIR="${LO_DIR}/instdir"
OUTPUT_DIR="${ROOT_DIR}/dist"
APP_NAME="EUnifyer.app"
DMG_NAME="EUnifyer-Office.dmg"
BUNDLE_ID="com.eunifyer.office"
VERSION="${1:-1.0.0}"

echo ">> Packaging EUnifyer for macOS..."

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
    <string>EUnifyer</string>
    <key>CFBundleDisplayName</key>
    <string>EUnifyer</string>
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
# hdiutil create -volname "EUnifyer" -srcfolder "$OUTPUT_DIR" \
#   -ov -format UDZO "${OUTPUT_DIR}/${DMG_NAME}"
# echo "   Created: ${OUTPUT_DIR}/${DMG_NAME}"

# Codesigning (uncomment with real identity):
# codesign --deep --force --verify --verbose \
#   --sign "Developer ID Application: EUnifyer (TEAM_ID)" \
#   "$APP_DIR"
# xcrun notarytool submit "${OUTPUT_DIR}/${DMG_NAME}" \
#   --apple-id "developer@eunifyer.com" \
#   --team-id "TEAM_ID" --wait

# ---------- Create separate app wrappers for Docs/Sheets/Slides ----------

echo ">> Creating separate app launchers..."

ICONS="${ROOT_DIR}/branding/icons"

create_app_wrapper() {
    local app_name="$1"    # e.g. "EUnifyer Docs"
    local soffice_flag="$2" # e.g. "--writer"
    local icon_src="$3"    # e.g. "writer"
    local bundle_suffix="$4" # e.g. "docs"

    local wrapper_dir="${OUTPUT_DIR}/${app_name}.app"
    rm -rf "$wrapper_dir"
    mkdir -p "${wrapper_dir}/Contents/MacOS"
    mkdir -p "${wrapper_dir}/Contents/Resources"

    # Launcher script
    cat > "${wrapper_dir}/Contents/MacOS/launcher" << 'LAUNCHER'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EUNIFYER_APP="$(dirname "$SCRIPT_DIR")/../EUnifyer.app"
if [ -d "$EUNIFYER_APP" ]; then
    exec "$EUNIFYER_APP/Contents/MacOS/soffice" FLAG_PLACEHOLDER "$@"
else
    # Fallback: search common locations
    for loc in /Applications/EUnifyer.app ~/Applications/EUnifyer.app; do
        if [ -d "$loc" ]; then
            exec "$loc/Contents/MacOS/soffice" FLAG_PLACEHOLDER "$@"
        fi
    done
    osascript -e 'display alert "EUnifyer Office not found" message "Please install EUnifyer Office first."'
    exit 1
fi
LAUNCHER
    sed -i '' "s|FLAG_PLACEHOLDER|${soffice_flag}|g" "${wrapper_dir}/Contents/MacOS/launcher"
    chmod +x "${wrapper_dir}/Contents/MacOS/launcher"

    # Generate .icns from SVG if possible
    local icon_name="app"
    if [ -f "${ICONS}/${icon_src}.svg" ]; then
        if command -v rsvg-convert &>/dev/null; then
            local iconset="${wrapper_dir}/Contents/Resources/app.iconset"
            mkdir -p "$iconset"
            for s in 16 32 64 128 256 512; do
                rsvg-convert -w "$s" -h "$s" "${ICONS}/${icon_src}.svg" -o "${iconset}/icon_${s}x${s}.png" 2>/dev/null || true
            done
            rsvg-convert -w 32 -h 32 "${ICONS}/${icon_src}.svg" -o "${iconset}/icon_16x16@2x.png" 2>/dev/null || true
            rsvg-convert -w 64 -h 64 "${ICONS}/${icon_src}.svg" -o "${iconset}/icon_32x32@2x.png" 2>/dev/null || true
            rsvg-convert -w 256 -h 256 "${ICONS}/${icon_src}.svg" -o "${iconset}/icon_128x128@2x.png" 2>/dev/null || true
            rsvg-convert -w 512 -h 512 "${ICONS}/${icon_src}.svg" -o "${iconset}/icon_256x256@2x.png" 2>/dev/null || true
            rsvg-convert -w 1024 -h 1024 "${ICONS}/${icon_src}.svg" -o "${iconset}/icon_512x512@2x.png" 2>/dev/null || true
            iconutil -c icns "$iconset" -o "${wrapper_dir}/Contents/Resources/${icon_name}.icns" 2>/dev/null && rm -rf "$iconset" || rm -rf "$iconset"
        fi
    fi

    # Info.plist
    cat > "${wrapper_dir}/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}.${bundle_suffix}</string>
    <key>CFBundleName</key>
    <string>${app_name}</string>
    <key>CFBundleDisplayName</key>
    <string>${app_name}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleExecutable</key>
    <string>launcher</string>
    <key>CFBundleIconFile</key>
    <string>${icon_name}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

    echo "   Created: ${wrapper_dir}"
}

create_app_wrapper "EUnifyer Docs"   "--writer"  "writer"  "docs"
create_app_wrapper "EUnifyer Sheets" "--calc"    "calc"    "sheets"
create_app_wrapper "EUnifyer Slides" "--impress" "impress" "slides"

echo ">> Packaging complete."
echo "   App: ${APP_DIR}"
echo "   Docs:   ${OUTPUT_DIR}/EUnifyer Docs.app"
echo "   Sheets: ${OUTPUT_DIR}/EUnifyer Sheets.app"
echo "   Slides: ${OUTPUT_DIR}/EUnifyer Slides.app"
