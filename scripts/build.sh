#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
LO_DIR="${ROOT_DIR}/libreoffice"
JOBS="${1:---jobs $(sysctl -n hw.ncpu 2>/dev/null || nproc)}"
SKIP_CLONE="${SKIP_CLONE:-false}"

echo "========================================"
echo " EUnifyer Office — Build"
echo "========================================"

# 1. Clone LibreOffice if not present
if [ "$SKIP_CLONE" != "true" ] && [ ! -d "$LO_DIR" ]; then
    echo ">> Cloning LibreOffice core..."
    git clone --depth 1 https://git.libreoffice.org/core "$LO_DIR"
fi

cd "$LO_DIR"

# 2. Configure
if [ ! -f config_host.mk ]; then
    echo ">> Running autogen.sh..."
    ./autogen.sh \
        --with-vendor="EUnifyer" \
        --with-product-name="EUnifyer Office" \
        --with-icon-themes="colibre" \
        --without-java \
        --enable-release-build
fi

# 3. Build
echo ">> Building (this takes 2-3h on first run)..."
make $JOBS

# 4. Apply branding
echo ">> Applying EUnifyer branding..."
"${SCRIPT_DIR}/brand-overlay.sh"

echo ""
echo "========================================"
echo " Build complete!"
echo " Run: ${LO_DIR}/instdir/program/soffice"
echo "========================================"
