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
echo " EUnifyer — Build"
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

# The bundled afdko (font toolkit) #includes <libxml/tree.h> without adding an
# include path. On macOS libxml2 lives under the SDK (and/or Homebrew) in a
# libxml2/ subdir, so expose it via CPATH for every clang invocation.
if [ "$(uname)" = "Darwin" ]; then
    _libxml_paths=""
    _sdk="$(xcrun --show-sdk-path 2>/dev/null || true)"
    [ -d "${_sdk}/usr/include/libxml2" ] && _libxml_paths="${_sdk}/usr/include/libxml2"
    if command -v brew &>/dev/null; then
        _brew_xml="$(brew --prefix libxml2 2>/dev/null || true)/include/libxml2"
        [ -d "$_brew_xml" ] && _libxml_paths="${_libxml_paths:+$_libxml_paths:}$_brew_xml"
    fi
    [ -n "$_libxml_paths" ] && export CPATH="${_libxml_paths}${CPATH:+:$CPATH}"
    echo ">> CPATH=${CPATH:-<unset>}"
fi


# 2. Configure
if [ ! -f config_host.mk ]; then
    echo ">> Running autogen.sh..."
    # Windows-only flags: the gpg externals (libgpg-error/libassuan/gpgmepp)
    # don't build cleanly under Cygwin+MSVC, and OpenPGP doc encryption isn't
    # essential — disable on Windows while keeping it on mac/Linux.
    WIN_FLAGS=""
    case "$(uname -s)" in
        CYGWIN*|MINGW*|MSYS*)
            # gpg externals fail under Cygwin+MSVC; firebird's build-time tools
            # fail on missing UCRT DLLs. Both features are non-essential — disable
            # on Windows (mac/Linux keep them).
            WIN_FLAGS="--disable-gpgmepp --disable-firebird-sdbc" ;;
    esac
    MESON="$(python3 -c 'import shutil; print(shutil.which("meson"))')" \
    ./autogen.sh \
        --with-vendor="EUnifyer" \
        --with-product-name="EUnifyer" \
        --with-theme="colibre" \
        --without-java \
        --disable-cli \
        $WIN_FLAGS \
        --enable-release-build \
        --enable-bogus-pkg-config
fi

# Windows: configure can emit ATL_INCLUDE/ATL_LIB as Cygwin (/cygdrive/c/…)
# paths, which the native MSVC cl.exe can't read (it needs C:/… form like the
# other SDK includes), breaking the ActiveX module. Rewrite them in place.
case "$(uname -s)" in
    CYGWIN*|MINGW*|MSYS*)
        sed -i -E 's#^(export ATL_INCLUDE=)/cygdrive/c/#\1C:/#; s#^(export ATL_LIB=)/cygdrive/c/#\1C:/#' config_host.mk ;;
esac

# 3. Build
echo ">> Building with $MAKE (this takes 2-3h on first run)..."
$MAKE $JOBS

# 4. Apply branding (SKIP_BRAND=1 to build the bare instdir and brand separately
# — useful when iterating branding without a multi-hour recompile)
if [ "${SKIP_BRAND:-0}" = "1" ]; then
    echo ">> Skipping branding (SKIP_BRAND=1)"
else
    echo ">> Applying EUnifyer branding..."
    "${SCRIPT_DIR}/brand-overlay.sh"
fi

echo ""
echo "========================================"
echo " Build complete!"
echo " Run: ${LO_DIR}/instdir/program/soffice"
echo "========================================"
