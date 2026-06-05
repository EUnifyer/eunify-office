#!/bin/bash
# package-windows.sh — thin wrapper that runs the PowerShell packager.
# Windows packaging lives in scripts/package-windows.ps1 (portable .zip always,
# .msi when the WiX Toolset is available). Run on a Windows host / CI runner
# after the LibreOffice build has produced libreoffice/instdir.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION="${1:-1.0.0}"

if command -v pwsh >/dev/null 2>&1; then
    pwsh -File "${SCRIPT_DIR}/package-windows.ps1" -Version "$VERSION"
elif command -v powershell >/dev/null 2>&1; then
    powershell -ExecutionPolicy Bypass -File "${SCRIPT_DIR}/package-windows.ps1" -Version "$VERSION"
else
    echo "ERROR: PowerShell (pwsh/powershell) not found — required for Windows packaging." >&2
    echo "Run scripts/package-windows.ps1 directly on a Windows host." >&2
    exit 1
fi
