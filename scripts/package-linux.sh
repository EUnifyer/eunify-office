#!/bin/bash
# package-linux.sh — Package the built EUnifyer Office (LibreOffice fork) into
# distributable Linux artifacts: a portable .tar.gz, a .deb, and (best-effort)
# an .AppImage.
#
# The install layout is fixed at /opt/eunifyer-office so that eunify-desktop's
# office.rs can detect it:
#   /opt/eunifyer-office/program/soffice   <- launcher office.rs invokes
#   /opt/eunifyer-office/version           <- read by office.rs read_version()
#
# Usage:
#   ./scripts/package-linux.sh [VERSION]
#
# Run on a Linux build host / CI runner after scripts/build.sh has produced
# libreoffice/instdir.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
LO_DIR="${ROOT_DIR}/libreoffice"
INSTDIR="${LO_DIR}/instdir"
OUTPUT_DIR="${ROOT_DIR}/dist"
VERSION="${1:-1.0.0}"

INSTALL_PREFIX="/opt/eunifyer-office"
PKG_NAME="eunifyer-office"
STAGE_DIR="${OUTPUT_DIR}/.linux-stage"
PAYLOAD_DIR="${STAGE_DIR}${INSTALL_PREFIX}"   # files under /opt/eunifyer-office

echo ">> Packaging EUnifyer Office for Linux (v${VERSION})..."

if [ ! -d "$INSTDIR/program" ]; then
    echo "ERROR: ${INSTDIR}/program not found — run scripts/build.sh first" >&2
    exit 1
fi

rm -rf "$STAGE_DIR"
mkdir -p "$PAYLOAD_DIR"
mkdir -p "$OUTPUT_DIR"

# ---------- 1. Copy the built tree into the install layout ----------

echo ">> Staging install tree at ${INSTALL_PREFIX}"
cp -a "${INSTDIR}/." "${PAYLOAD_DIR}/"

# version file — read by eunify-desktop office.rs
echo "$VERSION" > "${PAYLOAD_DIR}/version"

# ---------- 2. Desktop entry + launcher symlink ----------

mkdir -p "${STAGE_DIR}/usr/bin"
ln -sf "${INSTALL_PREFIX}/program/soffice" "${STAGE_DIR}/usr/bin/eunifyer-office"

mkdir -p "${STAGE_DIR}/usr/share/applications"
cat > "${STAGE_DIR}/usr/share/applications/eunifyer-office.desktop" << DESKTOP
[Desktop Entry]
Version=1.0
Type=Application
Name=EUnifyer Office
Comment=Native document editing for EUnifyer — Docs, Sheets, Slides
Exec=${INSTALL_PREFIX}/program/soffice %U
Icon=eunifyer-office
Terminal=false
Categories=Office;WordProcessor;Spreadsheet;Presentation;
MimeType=application/vnd.oasis.opendocument.text;application/vnd.openxmlformats-officedocument.wordprocessingml.document;application/vnd.oasis.opendocument.spreadsheet;application/vnd.openxmlformats-officedocument.spreadsheetml.sheet;application/vnd.oasis.opendocument.presentation;application/vnd.openxmlformats-officedocument.presentationml.presentation;
StartupNotify=true
DESKTOP

# Branding icon (falls back gracefully if absent)
ICON_SRC="${ROOT_DIR}/branding/icons"
if [ -d "$ICON_SRC" ]; then
    mkdir -p "${STAGE_DIR}/usr/share/icons/hicolor/256x256/apps"
    PNG=$(find "$ICON_SRC" -name "*256*.png" -o -name "icon.png" 2>/dev/null | head -1 || true)
    [ -n "$PNG" ] && cp "$PNG" "${STAGE_DIR}/usr/share/icons/hicolor/256x256/apps/eunifyer-office.png" || true
fi

# ---------- 3. Portable .tar.gz ----------

echo ">> Building portable tarball..."
TARBALL="${OUTPUT_DIR}/EUnifyer-Office-${VERSION}-linux-x86_64.tar.gz"
tar -C "$STAGE_DIR" -czf "$TARBALL" .
echo "   $TARBALL"

# ---------- 4. .deb (requires dpkg-deb) ----------

if command -v dpkg-deb >/dev/null 2>&1; then
    echo ">> Building .deb..."
    DEB_DIR="${STAGE_DIR}/DEBIAN"
    mkdir -p "$DEB_DIR"
    INSTALLED_KB=$(du -sk "$PAYLOAD_DIR" | cut -f1)
    cat > "${DEB_DIR}/control" << CONTROL
Package: ${PKG_NAME}
Version: ${VERSION}
Section: office
Priority: optional
Architecture: amd64
Maintainer: EUnifyer <support@eunifyer.com>
Installed-Size: ${INSTALLED_KB}
Depends: libc6 (>= 2.35)
Description: EUnifyer Office — native document editing
 Docs, Sheets and Slides with EUnifyer branding, built on LibreOffice.
 Integrates with EUnifyer Desktop for synced document storage.
CONTROL
    DEB_FILE="${OUTPUT_DIR}/EUnifyer-Office-${VERSION}-linux-amd64.deb"
    dpkg-deb --root-owner-group --build "$STAGE_DIR" "$DEB_FILE"
    echo "   $DEB_FILE"
    rm -rf "$DEB_DIR"
else
    echo ">> dpkg-deb not found — skipping .deb"
fi

# ---------- 5. .AppImage (best-effort, requires appimagetool) ----------

if command -v appimagetool >/dev/null 2>&1; then
    echo ">> Building .AppImage..."
    APPDIR="${OUTPUT_DIR}/.AppDir"
    rm -rf "$APPDIR"
    mkdir -p "$APPDIR/usr"
    cp -a "${PAYLOAD_DIR}/." "$APPDIR/usr/"
    cp "${STAGE_DIR}/usr/share/applications/eunifyer-office.desktop" "$APPDIR/eunifyer-office.desktop"
    cat > "$APPDIR/AppRun" << 'APPRUN'
#!/bin/bash
HERE="$(dirname "$(readlink -f "$0")")"
exec "$HERE/usr/program/soffice" "$@"
APPRUN
    chmod +x "$APPDIR/AppRun"
    [ -f "${STAGE_DIR}/usr/share/icons/hicolor/256x256/apps/eunifyer-office.png" ] && \
        cp "${STAGE_DIR}/usr/share/icons/hicolor/256x256/apps/eunifyer-office.png" "$APPDIR/eunifyer-office.png" || true
    appimagetool "$APPDIR" "${OUTPUT_DIR}/EUnifyer-Office-${VERSION}-linux-x86_64.AppImage" || \
        echo "   AppImage build failed (non-fatal)"
    rm -rf "$APPDIR"
else
    echo ">> appimagetool not found — skipping .AppImage"
fi

rm -rf "$STAGE_DIR"

echo ">> Linux packaging complete. Artifacts in ${OUTPUT_DIR}/"
ls -1 "${OUTPUT_DIR}" | grep -i "linux" || true
