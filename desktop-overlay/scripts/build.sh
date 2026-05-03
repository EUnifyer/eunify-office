#!/usr/bin/env bash
# build.sh — Clone LibreOffice source, configure with EUnifyer branding, and build.
#
# Usage:
#   ./libreoffice/scripts/build.sh [--clone-only] [--overlay-only]
#
# Environment:
#   LO_SRC_DIR    — Path to LibreOffice source (default: ../libreoffice-core)
#   LO_BRANCH     — LibreOffice branch to build (default: libreoffice-25-2)
#   PARALLELISM   — Build parallelism (default: auto-detect)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DESKTOP_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
OVERLAY_DIR="${DESKTOP_ROOT}/libreoffice"

LO_SRC_DIR="${LO_SRC_DIR:-${DESKTOP_ROOT}/../libreoffice-core}"
LO_BRANCH="${LO_BRANCH:-libreoffice-25-2}"
LO_REPO="https://gerrit.libreoffice.org/core"

CLONE_ONLY=false
OVERLAY_ONLY=false

for arg in "$@"; do
    case "${arg}" in
        --clone-only) CLONE_ONLY=true ;;
        --overlay-only) OVERLAY_ONLY=true ;;
    esac
done

# ---- Step 1: Clone LibreOffice source ----

if [[ "${OVERLAY_ONLY}" == "false" ]]; then
    if [[ ! -d "${LO_SRC_DIR}" ]]; then
        echo "==> Cloning LibreOffice (branch: ${LO_BRANCH})"
        echo "    This will take a while (~3 GB)..."
        git clone --depth 1 --branch "${LO_BRANCH}" "${LO_REPO}" "${LO_SRC_DIR}"
    else
        echo "==> LibreOffice source exists at ${LO_SRC_DIR}"
    fi

    if [[ "${CLONE_ONLY}" == "true" ]]; then
        echo "==> Clone complete. Run again without --clone-only to build."
        exit 0
    fi
fi

# ---- Step 2: Configure ----

if [[ "${OVERLAY_ONLY}" == "false" ]]; then
    echo "==> Configuring LibreOffice with EUnifyer branding"
    cd "${LO_SRC_DIR}"

    # Copy autogen.input
    cp "${OVERLAY_DIR}/autogen.input" autogen.input

    # Detect parallelism
    if [[ -z "${PARALLELISM:-}" ]]; then
        if [[ "$(uname)" == "Darwin" ]]; then
            PARALLELISM=$(sysctl -n hw.ncpu)
        else
            PARALLELISM=$(nproc)
        fi
    fi

    echo "    Parallelism: ${PARALLELISM}"

    ./autogen.sh

    # ---- Step 3: Build ----

    echo "==> Building LibreOffice (this will take a while)..."
    make -j"${PARALLELISM}"

    echo "==> Build complete"
fi

# ---- Step 4: Apply EUnifyer overlay ----

echo "==> Applying EUnifyer branding overlay"
"${SCRIPT_DIR}/overlay.sh" "${LO_SRC_DIR}"

echo ""
echo "=== EUnifyer Office build complete ==="
echo "    Source:  ${LO_SRC_DIR}"
echo "    Output:  ${LO_SRC_DIR}/instdir/"
