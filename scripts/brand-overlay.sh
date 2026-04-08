#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
LO_DIR="${ROOT_DIR}/libreoffice"
INSTDIR="${LO_DIR}/instdir"
BRANDING="${ROOT_DIR}/branding"
ICONS="${BRANDING}/icons"
CONFIG="${ROOT_DIR}/config"
TMPDIR="${ROOT_DIR}/.brand-tmp"

# App icon names that map to our SVG sources
# Format: "svg_name:target_name"
APPS=(main startcenter writer calc impress)

# All PNG sizes needed by sysui/hicolor + colibre + .icns
SIZES=(16 24 32 48 64 128 256 512 1024)

# ---------- helpers ----------

die()  { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" &>/dev/null || die "$1 is required. Install: $2"; }

svg_to_png() {
    local svg="$1" out="$2" size="$3"
    if command -v rsvg-convert &>/dev/null; then
        rsvg-convert -w "$size" -h "$size" "$svg" -o "$out"
    else
        # macOS fallback: qlmanage + sips
        local tmp_png="${TMPDIR}/ql_${size}.png"
        qlmanage -t -s "$size" -o "$TMPDIR" "$svg" &>/dev/null
        local ql_out="${TMPDIR}/$(basename "$svg").png"
        if [ -f "$ql_out" ]; then
            sips -z "$size" "$size" "$ql_out" --out "$out" &>/dev/null
            rm -f "$ql_out"
        else
            die "Cannot convert SVG to PNG. Install librsvg: brew install librsvg"
        fi
    fi
}

make_icns() {
    local svg="$1" out="$2"
    local iconset="${TMPDIR}/icon.iconset"
    rm -rf "$iconset"
    mkdir -p "$iconset"

    # Generate PNGs at each size and copy to iconutil naming convention
    svg_to_png "$svg" "${iconset}/icon_16x16.png" 16
    svg_to_png "$svg" "${iconset}/icon_16x16@2x.png" 32
    svg_to_png "$svg" "${iconset}/icon_32x32.png" 32
    svg_to_png "$svg" "${iconset}/icon_32x32@2x.png" 64
    svg_to_png "$svg" "${iconset}/icon_128x128.png" 128
    svg_to_png "$svg" "${iconset}/icon_128x128@2x.png" 256
    svg_to_png "$svg" "${iconset}/icon_256x256.png" 256
    svg_to_png "$svg" "${iconset}/icon_256x256@2x.png" 512
    svg_to_png "$svg" "${iconset}/icon_512x512.png" 512
    svg_to_png "$svg" "${iconset}/icon_512x512@2x.png" 1024

    iconutil -c icns "$iconset" -o "$out"
    rm -rf "$iconset"
}

make_ico() {
    local svg="$1" out="$2"
    # ICO needs 16, 24, 32, 48, 256
    local ico_sizes=(16 24 32 48 256)
    local pngs=()

    for size in "${ico_sizes[@]}"; do
        local p="${TMPDIR}/ico_${size}.png"
        svg_to_png "$svg" "$p" "$size"
        pngs+=("$p")
    done

    if command -v icotool &>/dev/null; then
        icotool -c -o "$out" "${pngs[@]}"
    elif command -v convert &>/dev/null; then
        convert "${pngs[@]}" "$out"
    else
        echo "   WARN: No icotool or ImageMagick — skipping .ico: $out"
        return 0
    fi
}

# ---------- preflight ----------

echo "========================================"
echo " EUnifyer Office — Brand Overlay"
echo "========================================"
echo ""

[ -d "$INSTDIR" ] || die "Build not found at ${INSTDIR}. Run build.sh first."
[ -d "$ICONS" ]   || die "Icon sources not found at ${ICONS}."

for app in "${APPS[@]}"; do
    [ -f "${ICONS}/${app}.svg" ] || die "Missing SVG: ${ICONS}/${app}.svg"
done

rm -rf "$TMPDIR"
mkdir -p "$TMPDIR"
trap 'rm -rf "$TMPDIR"' EXIT

echo ">> Generating icons from SVG sources..."

# ---------- 1. macOS .icns (app bundle icon) ----------

APP_BUNDLE=$(find "$INSTDIR" -maxdepth 1 -name "*.app" -type d | head -1)
if [ -n "$APP_BUNDLE" ]; then
    echo ""
    echo "-- macOS app bundle: $(basename "$APP_BUNDLE")"

    RESOURCES="${APP_BUNDLE}/Contents/Resources"
    if [ -d "$RESOURCES" ]; then
        # main.icns = dock/finder icon
        make_icns "${ICONS}/main.svg" "${RESOURCES}/main.icns"
        echo "   Replaced: main.icns (app icon)"

        # Per-component document type icons
        for app in writer calc impress; do
            case $app in
                writer)  types="generic-text oasis-text generic-text-template oasis-text-template generic-master-document oasis-master-document generic-master-document-template oasis-master-document-template" ;;
                calc)    types="generic-spreadsheet oasis-spreadsheet generic-spreadsheet-template oasis-spreadsheet-template" ;;
                impress) types="generic-presentation oasis-presentation generic-presentation-template oasis-presentation-template" ;;
            esac
            for doctype in $types; do
                target="${RESOURCES}/${doctype}.icns"
                if [ -f "$target" ]; then
                    make_icns "${ICONS}/${app}.svg" "$target"
                    echo "   Replaced: ${doctype}.icns"
                fi
            done
        done
    fi
fi

# ---------- 2. sysui/desktop/icons (OS-level icons, baked into build) ----------

SYSUI="${LO_DIR}/sysui/desktop/icons"
if [ -d "$SYSUI" ]; then
    echo ""
    echo "-- sysui/desktop/icons (OS-level)"

    # Windows .ico files
    for app in "${APPS[@]}"; do
        case $app in
            main)        ico_name="soffice.ico" ;;
            startcenter) ico_name="" ;; # no separate .ico for startcenter
            *)           ico_name="${app}_app.ico" ;;
        esac
        if [ -n "$ico_name" ] && [ -f "${SYSUI}/${ico_name}" ]; then
            make_ico "${ICONS}/${app}.svg" "${SYSUI}/${ico_name}"
            echo "   Replaced: ${ico_name}"
        fi
    done

    # hicolor PNGs at every size
    for app in "${APPS[@]}"; do
        for size in 16 24 32 48 64 128 256 512; do
            target="${SYSUI}/hicolor/${size}x${size}/apps/${app}.png"
            if [ -f "$target" ]; then
                svg_to_png "${ICONS}/${app}.svg" "$target" "$size"
            fi
        done
        # 512x512@2 = 1024px
        target="${SYSUI}/hicolor/512x512@2/apps/${app}.png"
        if [ -f "$target" ]; then
            svg_to_png "${ICONS}/${app}.svg" "$target" 1024
        fi
        # scalable SVG
        target="${SYSUI}/hicolor/scalable/apps/${app}.svg"
        if [ -f "$target" ]; then
            cp "${ICONS}/${app}.svg" "$target"
            echo "   Replaced: scalable/apps/${app}.svg"
        fi
    done
    echo "   Replaced: hicolor PNGs (all sizes)"
fi

# ---------- 3. colibre icon theme (in-app icons) ----------

COLIBRE="${LO_DIR}/icon-themes/colibre"
if [ -d "$COLIBRE" ]; then
    echo ""
    echo "-- colibre icon theme (in-app)"

    # Main app icons at various sizes
    for app in main writer calc impress; do
        # res/<app>128.png
        target="${COLIBRE}/res/${app}128.png"
        if [ -f "$target" ]; then
            svg_to_png "${ICONS}/${app}.svg" "$target" 128
            echo "   Replaced: res/${app}128.png"
        fi
    done

    # mainapp_*.png (small app icon variants)
    for size_name in "16:mainapp_16.png" "16:mainapp_16_8.png" "32:mainapp_32.png" "32:mainapp_32_8.png" "48:mainapp_48_8.png"; do
        size="${size_name%%:*}"
        fname="${size_name#*:}"
        target="${COLIBRE}/res/${fname}"
        if [ -f "$target" ]; then
            svg_to_png "${ICONS}/main.svg" "$target" "$size"
        fi
    done
    echo "   Replaced: res/mainapp_*.png"

    # writer32.png
    target="${COLIBRE}/res/writer32.png"
    if [ -f "$target" ]; then
        svg_to_png "${ICONS}/writer.svg" "$target" 32
    fi

    # sfx2/res document previews
    for app in writer calc impress; do
        target="${COLIBRE}/sfx2/res/128x128_${app}_doc-p.png"
        if [ -f "$target" ]; then
            svg_to_png "${ICONS}/${app}.svg" "$target" 128
            echo "   Replaced: sfx2/res/128x128_${app}_doc-p.png"
        fi
    done

    # Brand shell assets (start center logos)
    SHELL_DIR="${COLIBRE}/brand/shell"
    if [ -d "$SHELL_DIR" ]; then
        cp "${ICONS}/logo.svg"          "${SHELL_DIR}/logo.svg"
        cp "${ICONS}/logo_inverted.svg" "${SHELL_DIR}/logo_inverted.svg"
        cp "${ICONS}/logo.svg"          "${SHELL_DIR}/logo-sc.svg"
        cp "${ICONS}/logo_inverted.svg" "${SHELL_DIR}/logo-sc_inverted.svg"
        echo "   Replaced: brand/shell/logo*.svg"

        # about.svg
        target="${SHELL_DIR}/about.svg"
        if [ -f "$target" ]; then
            cp "${ICONS}/logo.svg" "$target"
            echo "   Replaced: brand/shell/about.svg"
        fi
    fi

    # Splash screen (intro.png)
    for intro_file in "${COLIBRE}/brand/intro.png" "${COLIBRE}/brand/intro-highres.png"; do
        if [ -f "$intro_file" ]; then
            fname=$(basename "$intro_file")
            if [ "$fname" = "intro-highres.png" ]; then
                svg_to_png "${ICONS}/main.svg" "$intro_file" 512
            else
                svg_to_png "${ICONS}/main.svg" "$intro_file" 256
            fi
            echo "   Replaced: brand/${fname}"
        fi
    done
fi

# ---------- 4. Other icon themes (best-effort) ----------

for theme_dir in "${LO_DIR}"/icon-themes/breeze_svg "${LO_DIR}"/icon-themes/sifr_dark_svg; do
    [ -d "$theme_dir" ] || continue
    theme_name=$(basename "$theme_dir")
    echo ""
    echo "-- ${theme_name} (secondary theme)"

    for app in main writer calc impress; do
        # res/<app>128.svg
        target="${theme_dir}/res/${app}128.svg"
        if [ -f "$target" ]; then
            cp "${ICONS}/${app}.svg" "$target"
        fi
        # sfx2/res
        target="${theme_dir}/sfx2/res/128x128_${app}_doc-p.svg"
        if [ -f "$target" ]; then
            cp "${ICONS}/${app}.svg" "$target"
        fi
    done

    # mainapp variants
    for fname in mainapp_16_8.svg mainapp_32_8.svg mainapp_48_8.svg; do
        target="${theme_dir}/res/${fname}"
        [ -f "$target" ] && cp "${ICONS}/main.svg" "$target"
    done
    echo "   Replaced: SVG icons"
done

# ---------- 5. Resolve runtime paths (macOS bundle vs flat instdir) ----------

# macOS builds put everything under .app/Contents/Resources instead of instdir/program + instdir/share
if [ -n "${APP_BUNDLE:-}" ] && [ -d "${APP_BUNDLE}/Contents/Resources" ]; then
    RES_DIR="${APP_BUNDLE}/Contents/Resources"
    PROG_BRAND="${RES_DIR}/brand"
    RC_DIR="$RES_DIR"
    UI_DIR="${RES_DIR}/config/soffice.cfg"
    REGISTRY_DIR="${RES_DIR}/registry"
else
    PROG_BRAND="${INSTDIR}/program/brand"
    RC_DIR="${INSTDIR}/program"
    UI_DIR="${INSTDIR}/share/config/soffice.cfg"
    REGISTRY_DIR="${INSTDIR}/share/registry"
fi

# ---------- 6. Runtime branding (splash, about, logo) ----------

echo ""
echo "-- Runtime branding"

if [ -d "$PROG_BRAND" ]; then
    for asset in intro.png about.png flat_logo.svg; do
        if [ -f "${BRANDING}/${asset}" ]; then
            cp "${BRANDING}/${asset}" "${PROG_BRAND}/${asset}"
            echo "   Replaced: ${asset}"
        fi
    done
fi

# ---------- 7. Registry defaults ----------

echo ""
echo "-- Config/registry overrides"

if [ -f "${CONFIG}/eunify-defaults.xcd" ] && [ -d "$REGISTRY_DIR" ]; then
    cp "${CONFIG}/eunify-defaults.xcd" "${REGISTRY_DIR}/"
    echo "   Installed: eunify-defaults.xcd"
fi

# ---------- 8. String replacements ----------

echo ""
echo "-- String replacements"

# rc files (bootstraprc, versionrc, sofficerc)
for rcfile in bootstraprc versionrc sofficerc; do
    target="${RC_DIR}/${rcfile}"
    if [ -f "$target" ]; then
        sed -i.bak \
            -e 's/LibreOffice/EUnifyer Office/g' \
            -e 's/The Document Foundation/EUnifyer/g' \
            "$target"
        rm -f "${target}.bak"
        echo "   Patched: ${rcfile}"
    fi
done

# .ui files (Help > About, menus, dialogs)
if [ -d "$UI_DIR" ]; then
    count=0
    while IFS= read -r -d '' uifile; do
        if grep -q "LibreOffice" "$uifile" 2>/dev/null; then
            sed -i.bak 's/LibreOffice/EUnifyer Office/g' "$uifile"
            rm -f "${uifile}.bak"
            count=$((count + 1))
        fi
    done < <(find "$UI_DIR" -name "*.ui" -print0)
    echo "   Patched: ${count} .ui files (LibreOffice → EUnifyer Office)"
fi

# .xcd registry files
if [ -d "$REGISTRY_DIR" ]; then
    count=0
    while IFS= read -r -d '' xcu; do
        if grep -q "LibreOffice" "$xcu" 2>/dev/null; then
            sed -i.bak \
                -e 's/LibreOffice/EUnifyer Office/g' \
                -e 's/The Document Foundation/EUnifyer/g' \
                "$xcu"
            rm -f "${xcu}.bak"
            count=$((count + 1))
        fi
    done < <(find "$REGISTRY_DIR" -name "*.xcd" -print0)
    echo "   Patched: ${count} .xcd registry files"
fi

# ---------- 9. macOS Info.plist (if built .app exists in instdir) ----------

if [ -n "${APP_BUNDLE:-}" ]; then
    PLIST="${APP_BUNDLE}/Contents/Info.plist"
    if [ -f "$PLIST" ]; then
        sed -i.bak \
            -e 's/LibreOffice/EUnifyer Office/g' \
            -e 's/The Document Foundation/EUnifyer/g' \
            -e 's/org\.libreoffice/com.eunifyer.office/g' \
            "$PLIST"
        rm -f "${PLIST}.bak"
        echo "   Patched: Info.plist"
    fi
fi

# ---------- done ----------

echo ""
echo "========================================"
echo " Brand overlay complete!"
echo "========================================"
echo ""
echo "Icon sources:  ${ICONS}/"
echo "  main.svg        → App icon (dock, finder, taskbar)"
echo "  startcenter.svg → Start center icon"
echo "  writer.svg      → EUnifyer Docs"
echo "  calc.svg        → EUnifyer Sheets"
echo "  impress.svg     → EUnifyer Slides"
echo "  logo.svg        → Start center wordmark"
echo ""
echo "To replace icons: edit SVGs in branding/icons/, re-run this script."
