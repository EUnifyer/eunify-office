#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
LO_DIR="${ROOT_DIR}/libreoffice"
JOBS="${1:---jobs $(sysctl -n hw.ncpu 2>/dev/null || nproc)}"
SKIP_CLONE="${SKIP_CLONE:-false}"

# macOS ships with BSD make 3.x; LibreOffice needs GNU make >= 4.2
if command -v gmake &>/dev/null; then
    MAKE=gmake
else
    MAKE=make
fi

echo "========================================"
echo " EUnifyer Office — Build"
echo "========================================"

# 1. Clone LibreOffice if not present
if [ "$SKIP_CLONE" != "true" ] && [ ! -d "$LO_DIR" ]; then
    echo ">> Cloning LibreOffice core..."
    git clone --depth 1 https://github.com/EUnifyer/libreoffice-core.git "$LO_DIR"
fi

cd "$LO_DIR"

# Build environment fixups for macOS + Homebrew
mkdir -p /tmp/lo-build-bin

# GNU make >= 4.2 required (macOS ships 3.x)
if [ "$MAKE" = "gmake" ]; then
    ln -sf "$(which gmake)" /tmp/lo-build-bin/make
    export PATH="/tmp/lo-build-bin:$PATH"
fi


# 2. Configure
if [ ! -f config_host.mk ]; then
    echo ">> Running autogen.sh..."
    MESON="$(python3 -c 'import shutil; print(shutil.which("meson"))')" \
    ./autogen.sh \
        --with-vendor="EUnifyer" \
        --with-product-name="EUnifyer Office" \
        --with-theme="colibre" \
        --without-java \
        --enable-release-build \
        --enable-bogus-pkg-config
fi

# 3. Build
echo ">> Building with $MAKE (this takes 2-3h on first run)..."
$MAKE $JOBS

# 4. Apply branding
echo ">> Applying EUnifyer branding..."
"${SCRIPT_DIR}/brand-overlay.sh"

echo ""
echo "========================================"
echo " Build complete!"
echo " Run: ${LO_DIR}/instdir/program/soffice"
echo "========================================"
