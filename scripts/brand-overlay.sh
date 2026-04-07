#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
LO_DIR="${ROOT_DIR}/libreoffice"
INSTDIR="${LO_DIR}/instdir"
BRANDING="${ROOT_DIR}/branding"
CONFIG="${ROOT_DIR}/config"

echo ">> Applying EUnifyer branding overlay..."

# Copy branding images
if [ -d "$BRANDING" ]; then
    for f in intro.png flat_logo.svg about.png; do
        if [ -f "${BRANDING}/${f}" ]; then
            cp "${BRANDING}/${f}" "${INSTDIR}/program/brand/${f}" 2>/dev/null && \
                echo "   Replaced: program/brand/${f}" || true
        fi
    done
fi

# Copy defaults override
if [ -f "${CONFIG}/eunify-defaults.xcd" ]; then
    cp "${CONFIG}/eunify-defaults.xcd" "${INSTDIR}/share/registry/"
    echo "   Installed: share/registry/eunify-defaults.xcd"
fi

# Replace LibreOffice text in about resources (best-effort)
if [ -f "${INSTDIR}/program/bootstraprc" ]; then
    sed -i.bak 's/LibreOffice/EUnifyer Office/g' "${INSTDIR}/program/bootstraprc"
    rm -f "${INSTDIR}/program/bootstraprc.bak"
    echo "   Patched: program/bootstraprc"
fi

echo ">> Branding overlay complete."
echo ""
echo "Modified files:"
echo "  - instdir/program/brand/ (splash, logo, about)"
echo "  - instdir/share/registry/eunify-defaults.xcd"
echo "  - instdir/program/bootstraprc"
