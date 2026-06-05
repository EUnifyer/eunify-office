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

# Cross-platform sed -i (macOS needs '' arg, GNU sed does not)
sedi() {
    if sed --version 2>/dev/null | grep -q GNU; then
        sed -i "$@"
    else
        sed -i '' "$@"
    fi
}

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

resize_png() {
    local src="$1" out="$2" size="$3"
    sips -z "$size" "$size" "$src" --out "$out" &>/dev/null
}

# Convert icon source to PNG at given size (SVG or PNG source)
icon_to_png() {
    local src="$1" out="$2" size="$3"
    if [[ "$src" == *.svg ]]; then
        svg_to_png "$src" "$out" "$size"
    else
        resize_png "$src" "$out" "$size"
    fi
}

# Get icon source file (prefer logo-source.png for main/startcenter, SVG for others)
get_icon_src() {
    local app="$1"
    local png_src="${ICONS}/logo-source.png"
    if [[ "$app" == "main" || "$app" == "startcenter" ]] && [ -f "$png_src" ]; then
        echo "$png_src"
    else
        echo "${ICONS}/${app}.svg"
    fi
}

make_icns() {
    local src="$1" out="$2"
    local iconset="${TMPDIR}/icon.iconset"
    rm -rf "$iconset"
    mkdir -p "$iconset"

    icon_to_png "$src" "${iconset}/icon_16x16.png" 16
    icon_to_png "$src" "${iconset}/icon_16x16@2x.png" 32
    icon_to_png "$src" "${iconset}/icon_32x32.png" 32
    icon_to_png "$src" "${iconset}/icon_32x32@2x.png" 64
    icon_to_png "$src" "${iconset}/icon_128x128.png" 128
    icon_to_png "$src" "${iconset}/icon_128x128@2x.png" 256
    icon_to_png "$src" "${iconset}/icon_256x256.png" 256
    icon_to_png "$src" "${iconset}/icon_256x256@2x.png" 512
    icon_to_png "$src" "${iconset}/icon_512x512.png" 512
    icon_to_png "$src" "${iconset}/icon_512x512@2x.png" 1024

    iconutil -c icns "$iconset" -o "$out"
    rm -rf "$iconset"
}

make_ico() {
    local src="$1" out="$2"
    # ICO needs 16, 24, 32, 48, 256
    local ico_sizes=(16 24 32 48 256)
    local pngs=()

    for size in "${ico_sizes[@]}"; do
        local p="${TMPDIR}/ico_${size}.png"
        icon_to_png "$src" "$p" "$size"
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
echo " EUnifyer — Brand Overlay"
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

APP_BUNDLE=$(find "$INSTDIR" -maxdepth 1 -name "EUnifyer*.app" -not -name "EUnifyer Docs*" -not -name "EUnifyer Sheets*" -not -name "EUnifyer Slides*" -type d | head -1)
if [ -n "$APP_BUNDLE" ]; then
    echo ""
    echo "-- macOS app bundle: $(basename "$APP_BUNDLE")"

    RESOURCES="${APP_BUNDLE}/Contents/Resources"
    if [ -d "$RESOURCES" ]; then
        # main.icns = dock/finder icon
        make_icns "$(get_icon_src main)" "${RESOURCES}/main.icns"
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
                    make_icns "$(get_icon_src $app)" "$target"
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
            make_ico "$(get_icon_src $app)" "${SYSUI}/${ico_name}"
            echo "   Replaced: ${ico_name}"
        fi
    done

    # hicolor PNGs at every size
    for app in "${APPS[@]}"; do
        src="$(get_icon_src $app)"
        for size in 16 24 32 48 64 128 256 512; do
            target="${SYSUI}/hicolor/${size}x${size}/apps/${app}.png"
            if [ -f "$target" ]; then
                icon_to_png "$src" "$target" "$size"
            fi
        done
        # 512x512@2 = 1024px
        target="${SYSUI}/hicolor/512x512@2/apps/${app}.png"
        if [ -f "$target" ]; then
            icon_to_png "$src" "$target" 1024
        fi
        # scalable SVG (only if SVG source exists)
        target="${SYSUI}/hicolor/scalable/apps/${app}.svg"
        if [ -f "$target" ] && [ -f "${ICONS}/${app}.svg" ]; then
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
        src="$(get_icon_src $app)"
        target="${COLIBRE}/res/${app}128.png"
        if [ -f "$target" ]; then
            icon_to_png "$src" "$target" 128
            echo "   Replaced: res/${app}128.png"
        fi
    done

    # mainapp_*.png (small app icon variants)
    main_src="$(get_icon_src main)"
    for size_name in "16:mainapp_16.png" "16:mainapp_16_8.png" "32:mainapp_32.png" "32:mainapp_32_8.png" "48:mainapp_48_8.png"; do
        size="${size_name%%:*}"
        fname="${size_name#*:}"
        target="${COLIBRE}/res/${fname}"
        if [ -f "$target" ]; then
            icon_to_png "$main_src" "$target" "$size"
        fi
    done
    echo "   Replaced: res/mainapp_*.png"

    # writer32.png
    target="${COLIBRE}/res/writer32.png"
    if [ -f "$target" ]; then
        icon_to_png "${ICONS}/writer.svg" "$target" 32
    fi

    # sfx2/res document previews
    for app in writer calc impress; do
        target="${COLIBRE}/sfx2/res/128x128_${app}_doc-p.png"
        if [ -f "$target" ]; then
            icon_to_png "$(get_icon_src $app)" "$target" 128
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

        # about.svg (square icon, not wordmark — used in welcome screen + about dialog)
        target="${SHELL_DIR}/about.svg"
        if [ -f "$target" ]; then
            cp "${ICONS}/main.svg" "$target"
            echo "   Replaced: brand/shell/about.svg"
        fi
    fi

    # Splash screen (intro.png)
    main_src="$(get_icon_src main)"
    for intro_file in "${COLIBRE}/brand/intro.png" "${COLIBRE}/brand/intro-highres.png"; do
        if [ -f "$intro_file" ]; then
            fname=$(basename "$intro_file")
            if [ "$fname" = "intro-highres.png" ]; then
                icon_to_png "$main_src" "$intro_file" 512
            else
                icon_to_png "$main_src" "$intro_file" 256
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
    FONTS_DIR="${RES_DIR}/fonts"
else
    PROG_BRAND="${INSTDIR}/program/brand"
    RC_DIR="${INSTDIR}/program"
    UI_DIR="${INSTDIR}/share/config/soffice.cfg"
    REGISTRY_DIR="${INSTDIR}/share/registry"
    FONTS_DIR="${INSTDIR}/share/fonts/truetype"
fi

# ---------- 5a. Bundle EUnifyer brand fonts (DM Sans) ----------
# Ships the brand typeface alongside the metric-compatible set (Carlito,
# Liberation, …) already bundled by LibreOffice, so DM Sans is selectable and
# can be the document default (see config/eunify-defaults.xcd).
BRAND_FONTS="${BRANDING}/fonts"
if ls "${BRAND_FONTS}"/*.ttf >/dev/null 2>&1; then
    mkdir -p "$FONTS_DIR"
    cp "${BRAND_FONTS}"/*.ttf "$FONTS_DIR/"
    echo "   Bundled brand fonts (DM Sans) → ${FONTS_DIR#${ROOT_DIR}/}"
fi

# ---------- 5b. Update images_colibre.zip (runtime icon pack) ----------

# This must run after section 5 so we know the correct config path
if [ -n "${APP_BUNDLE:-}" ]; then
    COLIBRE_ZIP="${APP_BUNDLE}/Contents/Resources/config/images_colibre.zip"
else
    COLIBRE_ZIP="${INSTDIR}/share/config/images_colibre.zip"
fi
if [ -f "$COLIBRE_ZIP" ]; then
    echo ""
    echo "-- Updating images_colibre.zip"
    zip_tmp="${TMPDIR}/colibre_update"
    rm -rf "$zip_tmp"
    mkdir -p "${zip_tmp}/res" "${zip_tmp}/sfx2/res"

    for app in main writer calc impress; do
        src="$(get_icon_src $app)"
        icon_to_png "$src" "${zip_tmp}/res/${app}128.png" 128
    done

    # mainapp variants
    main_src="$(get_icon_src main)"
    for size_name in "16:mainapp_16.png" "16:mainapp_16_8.png" "32:mainapp_32.png" "32:mainapp_32_8.png" "48:mainapp_48_8.png"; do
        size="${size_name%%:*}"
        fname="${size_name#*:}"
        icon_to_png "$main_src" "${zip_tmp}/res/${fname}" "$size"
    done

    icon_to_png "${ICONS}/writer.svg" "${zip_tmp}/res/writer32.png" 32

    # Start Center button icons
    icon_to_png "${ICONS}/writer.svg"  "${zip_tmp}/res/odt_32_8.png" 32
    icon_to_png "${ICONS}/calc.svg"    "${zip_tmp}/res/ods_32_8.png" 32
    icon_to_png "${ICONS}/impress.svg" "${zip_tmp}/res/odp_32_8.png" 32

    # sfx2 doc previews
    for app in writer calc impress; do
        icon_to_png "$(get_icon_src $app)" "${zip_tmp}/sfx2/res/128x128_${app}_doc-p.png" 128
    done

    (cd "$zip_tmp" && zip -q -u "$COLIBRE_ZIP" res/*.png sfx2/res/*.png)
    echo "   Updated: images_colibre.zip with branded icons"
    rm -rf "$zip_tmp"
fi

# ---------- 6. Runtime branding (splash, about, logo, shell) ----------

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

# Shell assets (start center logo — loaded at runtime via loadBrandSvg)
SHELL_RUNTIME="${RC_DIR}/shell"
if [ -d "$SHELL_RUNTIME" ]; then
    cp "${ICONS}/logo.svg"          "${SHELL_RUNTIME}/logo.svg"
    cp "${ICONS}/logo_inverted.svg" "${SHELL_RUNTIME}/logo_inverted.svg"
    cp "${ICONS}/logo.svg"          "${SHELL_RUNTIME}/logo-sc.svg"
    cp "${ICONS}/logo_inverted.svg" "${SHELL_RUNTIME}/logo-sc_inverted.svg"
    cp "${ICONS}/main.svg"           "${SHELL_RUNTIME}/about.svg"
    # Remove donate assets
    rm -f "${SHELL_RUNTIME}/donate1.png" "${SHELL_RUNTIME}/donationbackground.png"
    echo "   Replaced: shell/ logos + removed donate assets"
fi

# Copy patched startcenter.ui from source to instdir (labels + visibility already fixed in source)
STARTCENTER_SRC="${LO_DIR}/sfx2/uiconfig/ui/startcenter.ui"
STARTCENTER_UI="${UI_DIR}/sfx/ui/startcenter.ui"
if [ -f "$STARTCENTER_SRC" ] && [ -f "$STARTCENTER_UI" ]; then
    cp "$STARTCENTER_SRC" "$STARTCENTER_UI"
    echo "   Copied: startcenter.ui (patched labels + donate/extensions hidden)"
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
        sedi \
            -e 's/LibreOffice/EUnifyer/g' \
            -e 's/The Document Foundation/EUnifyer/g' \
            "$target"
        echo "   Patched: ${rcfile}"
    fi
done

# .ui files (Help > About, menus, dialogs)
if [ -d "$UI_DIR" ]; then
    count=0
    while IFS= read -r -d '' uifile; do
        if grep -q "LibreOffice" "$uifile" 2>/dev/null; then
            sedi 's/LibreOffice/EUnifyer/g' "$uifile"
            count=$((count + 1))
        fi
    done < <(find "$UI_DIR" -name "*.ui" -print0)
    echo "   Patched: ${count} .ui files (LibreOffice → EUnifyer)"
fi

# .xcd registry files — ONLY replace user-visible display strings,
# never internal property names (UseLibreOffice*, non-LibreOffice, etc.)
if [ -d "$REGISTRY_DIR" ]; then
    count=0
    while IFS= read -r -d '' xcu; do
        if grep -q "LibreOffice" "$xcu" 2>/dev/null; then
            sedi \
                -e 's/The Document Foundation/EUnifyer/g' \
                -e 's/>LibreOffice</>EUnifyer</g' \
                -e 's/"LibreOffice"/"EUnifyer"/g' \
                "$xcu"
            count=$((count + 1))
        fi
    done < <(find "$REGISTRY_DIR" -name "*.xcd" -print0)
    echo "   Patched: ${count} .xcd registry files (display strings only)"
fi

# ---------- 9. macOS Info.plist (if built .app exists in instdir) ----------

if [ -n "${APP_BUNDLE:-}" ]; then
    PLIST="${APP_BUNDLE}/Contents/Info.plist"
    if [ -f "$PLIST" ]; then
        sedi \
            -e 's/LibreOffice/EUnifyer/g' \
            -e 's/The Document Foundation/EUnifyer/g' \
            -e 's/org\.libreoffice/com.eunifyer.office/g' \
            "$PLIST"
        echo "   Patched: Info.plist"
    fi
fi

# ---------- 10. macOS wrapper apps (Docs, Sheets, Slides) ----------

if [ -n "${APP_BUNDLE:-}" ]; then
    echo ""
    echo "-- macOS wrapper apps"

    # Each wrapper is a full STANDALONE clone of the main app bundle with:
    # - Its own copy of the program/frameworks/resources (runs independently)
    # - Own Info.plist (unique CFBundleIdentifier → own dock icon + Cmd+Tab)
    # - Own .icns icon
    # - Launcher that boots straight into its module via factory URL

    create_wrapper_app() {
        local app_name="$1"     # e.g. "EUnifyer Docs"
        local soffice_flag="$2" # e.g. "--writer"
        local icon_src="$3"     # e.g. "writer"
        local bundle_suffix="$4" # e.g. "docs"
        local factory_url="$5"  # e.g. "private:factory/swriter"

        local wrapper_dir="${INSTDIR}/${app_name}.app"
        rm -rf "$wrapper_dir"

        # Standalone bundle: copy the whole main app payload (program,
        # frameworks, libraries, resources) so Docs/Sheets/Slides run entirely
        # on their own — no dependency on "EUnifyer Office.app" being installed.
        # ditto faithfully clones the bundle; we then swap icon/launcher/plist.
        ditto "${APP_BUNDLE}" "${wrapper_dir}"

        # Generate our own .icns (overrides symlink if any)
        if [ -f "${ICONS}/${icon_src}.svg" ]; then
            rm -f "${wrapper_dir}/Contents/Resources/main.icns"
            make_icns "${ICONS}/${icon_src}.svg" "${wrapper_dir}/Contents/Resources/main.icns"
        fi

        # Launcher script — wraps soffice with factory URL for new docs
        # Uses exec to replace process, so macOS attributes the window to this bundle
        cat > "${wrapper_dir}/Contents/MacOS/launcher" << 'LAUNCHER'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# This bundle is self-contained — launch its OWN soffice. No dependency on a
# separately installed "EUnifyer Office.app".
SOFFICE="$SCRIPT_DIR/soffice"
if [ ! -x "$SOFFICE" ]; then
    osascript -e 'display alert "EUnifyer Office" message "This app looks damaged. Please reinstall it."'
    exit 1
fi

# Filter out macOS system args
FILES=()
for arg in "$@"; do
    case "$arg" in
        -psn_*|-NS*) ;;
        *) FILES+=("$arg") ;;
    esac
done

# Set environment so LibreOffice uses this bundle's identity
export CFBundleIdentifier="com.eunifyer.office.BUNDLE_SUFFIX_PLACEHOLDER"

if [ ${#FILES[@]} -gt 0 ]; then
    exec "$SOFFICE" FLAG_PLACEHOLDER "${FILES[@]}"
else
    exec "$SOFFICE" FACTORY_PLACEHOLDER
fi
LAUNCHER
        sedi \
            -e "s|FLAG_PLACEHOLDER|${soffice_flag}|g" \
            -e "s|FACTORY_PLACEHOLDER|${factory_url}|g" \
            -e "s|BUNDLE_SUFFIX_PLACEHOLDER|${bundle_suffix}|g" \
            "${wrapper_dir}/Contents/MacOS/launcher"
        chmod +x "${wrapper_dir}/Contents/MacOS/launcher"

        # Info.plist — unique bundle ID is what gives us a separate dock icon
        cat > "${wrapper_dir}/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.eunifyer.office.${bundle_suffix}</string>
    <key>CFBundleName</key>
    <string>${app_name}</string>
    <key>CFBundleDisplayName</key>
    <string>${app_name}</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleExecutable</key>
    <string>launcher</string>
    <key>CFBundleIconFile</key>
    <string>main</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

        echo "   Created: ${app_name}.app (standalone bundle, own dock identity)"
    }

    create_wrapper_app "EUnifyer Docs"   "--writer"  "writer"  "docs"   "private:factory/swriter"
    create_wrapper_app "EUnifyer Sheets" "--calc"    "calc"    "sheets" "private:factory/scalc"
    create_wrapper_app "EUnifyer Slides" "--impress" "impress" "slides" "private:factory/simpress"
fi

# ---------- 10b. Windows launchers (.bat + .ico) ----------

if [ -z "${APP_BUNDLE:-}" ] && [ -d "${INSTDIR}/program" ]; then
    echo ""
    echo "-- Windows/Linux launchers"

    SOFFICE_BIN="soffice"
    [ -f "${INSTDIR}/program/soffice.exe" ] && SOFFICE_BIN="soffice.exe"

    create_launcher() {
        local app_name="$1"     # e.g. "EUnifyer Docs"
        local soffice_flag="$2" # e.g. "--writer"
        local icon_src="$3"     # e.g. "writer"
        local factory_url="$4"  # e.g. "private:factory/swriter"
        local generic_name="$5" # e.g. "Word Processor"

        # Windows .bat launcher
        if [ -f "${INSTDIR}/program/soffice.exe" ]; then
            cat > "${INSTDIR}/${app_name}.bat" << BAT
@echo off
start "" "%~dp0program\\soffice.exe" ${factory_url}
BAT
            echo "   Created: ${app_name}.bat"
        fi

        # Windows .ico (already in sysui, copy next to launcher)
        local ico_name=""
        case "$icon_src" in
            writer)  ico_name="writer_app.ico" ;;
            calc)    ico_name="calc_app.ico" ;;
            impress) ico_name="impress_app.ico" ;;
        esac
        if [ -n "$ico_name" ] && [ -f "${SYSUI}/${ico_name}" ]; then
            cp "${SYSUI}/${ico_name}" "${INSTDIR}/${app_name}.ico"
        fi

        # Linux .desktop file
        cat > "${INSTDIR}/${app_name}.desktop" << DESKTOP
[Desktop Entry]
Version=1.0
Type=Application
Name=${app_name}
GenericName=${generic_name}
Comment=EUnifyer Office - ${app_name}
Exec=${INSTDIR}/program/${SOFFICE_BIN} ${factory_url} %U
Icon=${INSTDIR}/${app_name}.ico
Terminal=false
Categories=Office;
MimeType=
StartupNotify=true
DESKTOP
        chmod +x "${INSTDIR}/${app_name}.desktop"
        echo "   Created: ${app_name}.desktop"
    }

    create_launcher "EUnifyer Docs"   "--writer"  "writer"  "private:factory/swriter"  "Word Processor"
    create_launcher "EUnifyer Sheets" "--calc"    "calc"    "private:factory/scalc"    "Spreadsheet"
    create_launcher "EUnifyer Slides" "--impress" "impress" "private:factory/simpress" "Presentation"
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
