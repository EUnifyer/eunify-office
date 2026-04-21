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
SIGNING_IDENTITY="${APPLE_SIGNING_IDENTITY:-}"
STAGING_DIR="${OUTPUT_DIR}/.dmg-staging"

sign_app() {
    local app_path="$1"
    if [ -z "$SIGNING_IDENTITY" ]; then
        return 0
    fi

    local sign_args=(--force --sign "$SIGNING_IDENTITY")
    if [ "$SIGNING_IDENTITY" != "-" ]; then
        sign_args+=(--options runtime --timestamp)
    else
        echo "   Using ad-hoc signing for $(basename "$app_path")"
    fi

    codesign --deep "${sign_args[@]}" "$app_path"
    codesign --verify --deep --strict --verbose=2 "$app_path"
}

echo ">> Packaging EUnifyer for macOS..."

mkdir -p "$OUTPUT_DIR"

# Create .app bundle structure
APP_DIR="${OUTPUT_DIR}/${APP_NAME}"
rm -rf "$APP_DIR"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

# Copy from the built .app bundle inside instdir
BUILT_APP=$(find "$INSTDIR" -maxdepth 1 -name "*.app" -type d | head -1)
if [ -z "$BUILT_APP" ]; then
    echo "ERROR: No .app bundle found in ${INSTDIR}" >&2
    exit 1
fi
cp -R "${BUILT_APP}/Contents/"* "${APP_DIR}/Contents/"

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

# ---------- Copy wrapper apps from instdir (created by brand-overlay.sh) ----------

echo ">> Copying wrapper apps..."

for wrapper in "EUnifyer Docs" "EUnifyer Sheets" "EUnifyer Slides"; do
    src="${INSTDIR}/${wrapper}.app"
    if [ -d "$src" ]; then
        rm -rf "${OUTPUT_DIR}/${wrapper}.app"
        cp -RL "$src" "${OUTPUT_DIR}/${wrapper}.app"
        echo "   Copied: ${wrapper}.app"
    else
        echo "   WARN: ${wrapper}.app not found in instdir — run brand-overlay.sh first"
    fi
done

if [ -n "$SIGNING_IDENTITY" ]; then
    echo ">> Signing app bundles..."
    while IFS= read -r -d '' app; do
        echo "   Signing: $(basename "$app")"
        sign_app "$app"
    done < <(find "$OUTPUT_DIR" -maxdepth 1 -name "*.app" -print0 | sort -z)
else
    echo ">> Signing skipped. Set APPLE_SIGNING_IDENTITY to sign app bundles."
fi

echo ">> Building DMG..."
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
while IFS= read -r -d '' app; do
    cp -RL "$app" "$STAGING_DIR/"
done < <(find "$OUTPUT_DIR" -maxdepth 1 -name "*.app" -print0 | sort -z)

rm -f "${OUTPUT_DIR}/${DMG_NAME}"
hdiutil create -volname "EUnifyer Office" -srcfolder "$STAGING_DIR" \
  -ov -format UDZO "${OUTPUT_DIR}/${DMG_NAME}" >/dev/null
rm -rf "$STAGING_DIR"

if [ -n "$SIGNING_IDENTITY" ] && [ "$SIGNING_IDENTITY" != "-" ]; then
    echo ">> Signing DMG..."
    codesign --force --sign "$SIGNING_IDENTITY" --timestamp "${OUTPUT_DIR}/${DMG_NAME}"

    if [ -n "${APPLE_API_KEY:-}" ] && [ -n "${APPLE_API_KEY_PATH:-}" ] && [ -n "${APPLE_API_ISSUER:-}" ]; then
        echo ">> Notarizing DMG via App Store Connect API key..."
        xcrun notarytool submit "${OUTPUT_DIR}/${DMG_NAME}" \
          --key "$APPLE_API_KEY_PATH" \
          --key-id "$APPLE_API_KEY" \
          --issuer "$APPLE_API_ISSUER" \
          --wait
    elif [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_PASSWORD:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ]; then
        echo ">> Notarizing DMG via Apple ID..."
        xcrun notarytool submit "${OUTPUT_DIR}/${DMG_NAME}" \
          --apple-id "$APPLE_ID" \
          --password "$APPLE_PASSWORD" \
          --team-id "$APPLE_TEAM_ID" \
          --wait
    else
        echo ">> Notarization skipped. Set APPLE_API_* or APPLE_ID/APPLE_PASSWORD/APPLE_TEAM_ID."
    fi

    while IFS= read -r -d '' app; do
        xcrun stapler staple "$app"
    done < <(find "$OUTPUT_DIR" -maxdepth 1 -name "*.app" -print0 | sort -z)
    xcrun stapler staple "${OUTPUT_DIR}/${DMG_NAME}"
fi

echo ">> Packaging complete."
echo "   App:    ${APP_DIR}"
echo "   Docs:   ${OUTPUT_DIR}/EUnifyer Docs.app"
echo "   Sheets: ${OUTPUT_DIR}/EUnifyer Sheets.app"
echo "   Slides: ${OUTPUT_DIR}/EUnifyer Slides.app"
echo "   DMG:    ${OUTPUT_DIR}/${DMG_NAME}"
