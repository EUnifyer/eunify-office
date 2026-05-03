#!/usr/bin/env bash
# package-windows.sh — Package EUnifyer Office + Desktop for Windows
#
# Usage:
#   ./libreoffice/scripts/package-windows.sh /path/to/libreoffice-core
#
# This script prepares the directory structure for WiX/MSIX packaging.
# Actual MSI creation requires Windows + WiX Toolset.
#
# Output:
#   dist/windows/ — ready for WiX/MSIX packaging

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DESKTOP_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LO_SRC="${1:?Usage: package-windows.sh /path/to/libreoffice-core}"

VERSION="${VERSION:-1.0.0}"
DIST_DIR="${DESKTOP_ROOT}/dist/windows"

echo "==> Preparing EUnifyer Desktop Suite for Windows packaging"

# Clean
rm -rf "${DIST_DIR}"
mkdir -p "${DIST_DIR}/EUnifyer Office"
mkdir -p "${DIST_DIR}/EUnifyer Desktop"

# ---- 1. Copy LibreOffice install ----

LO_INSTDIR="${LO_SRC}/instdir"
if [[ ! -d "${LO_INSTDIR}/program" ]]; then
    echo "ERROR: No instdir/program found at ${LO_SRC}" >&2
    exit 1
fi

echo "    Copying LibreOffice install"
cp -R "${LO_INSTDIR}/program" "${DIST_DIR}/EUnifyer Office/"
cp -R "${LO_INSTDIR}/share" "${DIST_DIR}/EUnifyer Office/"

# ---- 2. Copy Tauri desktop app ----

TAURI_EXE="${DESKTOP_ROOT}/src-tauri/target/release/eunify-desktop.exe"
if [[ -f "${TAURI_EXE}" ]]; then
    echo "    Copying Tauri executable"
    cp "${TAURI_EXE}" "${DIST_DIR}/EUnifyer Desktop/"
else
    echo "    WARNING: Tauri .exe not found"
fi

# ---- 3. Write WiX source stub ----

cat > "${DIST_DIR}/EUnifyer.wxs" << 'WXSEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!--
  WiX installer source for EUnifyer Desktop Suite.
  Build with: candle EUnifyer.wxs && light EUnifyer.wixobj -o EUnifyer.msi
-->
<Wix xmlns="http://schemas.microsoft.com/wix/2006/wi">
  <Product Id="*"
           Name="EUnifyer Desktop Suite"
           Language="1033"
           Version="$(var.Version)"
           Manufacturer="EUnifyer B.V."
           UpgradeCode="E0F1A2B3-C4D5-6E7F-8901-234567890ABC">

    <Package InstallerVersion="500" Compressed="yes" InstallScope="perMachine"
             Description="EUnifyer Desktop Suite — sync client + office apps"
             Manufacturer="EUnifyer B.V."/>

    <MajorUpgrade DowngradeErrorMessage="A newer version is already installed."/>
    <MediaTemplate EmbedCab="yes"/>

    <!-- Features -->
    <Feature Id="DesktopSync" Title="EUnifyer Desktop" Level="1">
      <ComponentGroupRef Id="DesktopFiles"/>
    </Feature>

    <Feature Id="Office" Title="EUnifyer Office" Level="1">
      <ComponentGroupRef Id="OfficeFiles"/>
    </Feature>

    <!-- TODO: Harvest components with heat.exe -->

  </Product>
</Wix>
WXSEOF

echo ""
echo "=== Windows packaging prepared: ${DIST_DIR} ==="
echo ""
echo "Next steps (on Windows):"
echo "  1. Install WiX Toolset"
echo "  2. Harvest files: heat.exe dir '${DIST_DIR}' -ag -cg OfficeFiles -dr INSTALLDIR"
echo "  3. Build MSI: candle EUnifyer.wxs && light EUnifyer.wixobj"
echo "  4. Sign with EV cert: signtool sign /sha1 ... EUnifyer.msi"
