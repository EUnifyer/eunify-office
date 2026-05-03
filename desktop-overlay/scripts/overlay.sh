#!/usr/bin/env bash
# overlay.sh — Apply EUnifyer branding on top of a built LibreOffice instdir.
#
# Usage:
#   ./libreoffice/scripts/overlay.sh /path/to/libreoffice-core
#
# This script copies brand assets and registry overrides into the built
# LibreOffice installation directory WITHOUT modifying the LO source tree.
# The fork stays pristine; all customisation lives here.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LO_DIR="${SCRIPT_DIR}/../.."    # eunify-desktop root
OVERLAY="${LO_DIR}/libreoffice"
LO_SRC="${1:?Usage: overlay.sh /path/to/libreoffice-core}"

# Detect platform instdir
if [[ -d "${LO_SRC}/instdir" ]]; then
    INSTDIR="${LO_SRC}/instdir"
elif [[ -d "${LO_SRC}/install" ]]; then
    INSTDIR="${LO_SRC}/install"
else
    echo "ERROR: Cannot find instdir in ${LO_SRC}" >&2
    exit 1
fi

# On macOS the app bundle has a different layout
if [[ "$(uname)" == "Darwin" ]]; then
    APP_BUNDLE=$(find "${INSTDIR}" -maxdepth 1 -name "*.app" -type d | head -1)
    if [[ -n "${APP_BUNDLE}" ]]; then
        PROGRAM="${APP_BUNDLE}/Contents/Resources/program"
        SHARE="${APP_BUNDLE}/Contents/Resources/share"
    else
        PROGRAM="${INSTDIR}/program"
        SHARE="${INSTDIR}/share"
    fi
else
    PROGRAM="${INSTDIR}/program"
    SHARE="${INSTDIR}/share"
fi

echo "==> Overlaying EUnifyer branding"
echo "    instdir: ${INSTDIR}"
echo "    program: ${PROGRAM}"
echo "    share:   ${SHARE}"

# 1. Brand images (splash, logo, about)
BRAND_DIR="${PROGRAM}/brand"
mkdir -p "${BRAND_DIR}"

if [[ -f "${OVERLAY}/brand/intro/intro.png" ]]; then
    cp -v "${OVERLAY}/brand/intro/intro.png" "${BRAND_DIR}/intro.png"
fi
if [[ -f "${OVERLAY}/brand/about/about.svg" ]]; then
    cp -v "${OVERLAY}/brand/about/about.svg" "${BRAND_DIR}/about.svg"
fi
if [[ -f "${OVERLAY}/brand/flat_logo.svg" ]]; then
    cp -v "${OVERLAY}/brand/flat_logo.svg" "${BRAND_DIR}/flat_logo.svg"
fi

# 2. Registry overrides (.xcd files)
REGISTRY_DIR="${SHARE}/registry"
mkdir -p "${REGISTRY_DIR}"

for xcd in "${OVERLAY}/registry/"*.xcd; do
    [[ -f "${xcd}" ]] || continue
    cp -v "${xcd}" "${REGISTRY_DIR}/$(basename "${xcd}")"
done

# 3. Templates
TEMPLATE_DIR="${SHARE}/template/common"
mkdir -p "${TEMPLATE_DIR}"

for tmpl in "${OVERLAY}/templates/"*; do
    [[ -f "${tmpl}" ]] || continue
    cp -v "${tmpl}" "${TEMPLATE_DIR}/$(basename "${tmpl}")"
done

# 4. Install bundled extensions (.oxt)
EXT_DIR="${SHARE}/extensions"
mkdir -p "${EXT_DIR}"

# Build the auth extension
if [[ -d "${OVERLAY}/extension/auth" ]]; then
    echo "==> Packaging auth extension"
    AUTH_OXT="${EXT_DIR}/eunifyer-auth.oxt"
    (cd "${OVERLAY}/extension/auth" && zip -r "${AUTH_OXT}" . -x "*.pyc" "__pycache__/*")
    echo "    -> ${AUTH_OXT}"
fi

# Build the drive extension
if [[ -d "${OVERLAY}/extension/drive" ]]; then
    echo "==> Packaging drive extension"
    DRIVE_OXT="${EXT_DIR}/eunifyer-drive.oxt"
    (cd "${OVERLAY}/extension/drive" && zip -r "${DRIVE_OXT}" . -x "*.pyc" "__pycache__/*")
    echo "    -> ${DRIVE_OXT}"
fi

# 5. macOS: update Info.plist product name
if [[ "$(uname)" == "Darwin" && -n "${APP_BUNDLE:-}" ]]; then
    PLIST="${APP_BUNDLE}/Contents/Info.plist"
    if [[ -f "${PLIST}" ]]; then
        echo "==> Updating macOS Info.plist"
        /usr/libexec/PlistBuddy -c "Set :CFBundleName 'EUnifyer Office'" "${PLIST}" 2>/dev/null || true
        /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName 'EUnifyer Office'" "${PLIST}" 2>/dev/null || true
        /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier 'com.eunifyer.office'" "${PLIST}" 2>/dev/null || true
    fi
fi

echo ""
echo "==> EUnifyer branding overlay complete"
