#!/usr/bin/env bash
# package-macos.sh — Package EUnifyer Office + Desktop into a macOS .dmg
#
# Usage:
#   ./libreoffice/scripts/package-macos.sh /path/to/libreoffice-core
#
# Prerequisites:
#   - LibreOffice built + overlay applied
#   - Tauri desktop app built (src-tauri/target/release/bundle/)
#
# Output:
#   dist/EUnifyer-Desktop-Suite-{version}-macOS.dmg

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DESKTOP_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LO_SRC="${1:?Usage: package-macos.sh /path/to/libreoffice-core}"

VERSION="${VERSION:-1.0.0}"
DIST_DIR="${DESKTOP_ROOT}/dist/macos"
DMG_NAME="EUnifyer-Desktop-Suite-${VERSION}-macOS"

echo "==> Packaging EUnifyer Desktop Suite for macOS"

# Clean
rm -rf "${DIST_DIR}"
mkdir -p "${DIST_DIR}/dmg-contents"

# ---- 1. Copy EUnifyer Office (LibreOffice .app) ----

LO_APP=$(find "${LO_SRC}/instdir" -maxdepth 1 -name "*.app" -type d | head -1)
if [[ -z "${LO_APP}" ]]; then
    echo "ERROR: No .app bundle found in ${LO_SRC}/instdir" >&2
    exit 1
fi

echo "    Copying ${LO_APP}"
cp -R "${LO_APP}" "${DIST_DIR}/dmg-contents/EUnifyer Office.app"

# ---- 2. Copy EUnifyer Desktop (Tauri .app) ----

TAURI_BUNDLE="${DESKTOP_ROOT}/src-tauri/target/release/bundle/macos"
TAURI_APP=$(find "${TAURI_BUNDLE}" -maxdepth 1 -name "*.app" -type d 2>/dev/null | head -1)

if [[ -n "${TAURI_APP}" ]]; then
    echo "    Copying ${TAURI_APP}"
    cp -R "${TAURI_APP}" "${DIST_DIR}/dmg-contents/EUnifyer Desktop.app"
else
    echo "    WARNING: Tauri .app not found at ${TAURI_BUNDLE}"
    echo "    Build Tauri first: cd src-tauri && cargo tauri build"
fi

# ---- 3. Add Applications symlink ----

ln -s /Applications "${DIST_DIR}/dmg-contents/Applications"

# ---- 4. Create DMG ----

echo "==> Creating DMG"
DMG_PATH="${DESKTOP_ROOT}/dist/${DMG_NAME}.dmg"

hdiutil create \
    -volname "EUnifyer Desktop Suite" \
    -srcfolder "${DIST_DIR}/dmg-contents" \
    -ov \
    -format UDZO \
    "${DMG_PATH}"

echo ""
echo "=== DMG created: ${DMG_PATH} ==="
echo ""
echo "Next steps:"
echo "  1. Sign:     codesign --deep --sign 'Developer ID' ${DMG_PATH}"
echo "  2. Notarize: xcrun notarytool submit ${DMG_PATH} --apple-id ... --team-id ..."
echo "  3. Staple:   xcrun stapler staple ${DMG_PATH}"
