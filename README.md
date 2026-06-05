# EUnifyer

Build overlay for LibreOffice Community (MPL-2.0) — rebranded as EUnifyer with NotebookBar (ribbon UI) enabled by default.

## Components

| LibreOffice | EUnifyer Name | Included |
|---|---|---|
| Writer | EUnifyer Docs | Yes |
| Calc | EUnifyer Sheets | Yes |
| Impress | EUnifyer Slides | Yes |
| Draw | — | No (v1) |
| Base | — | No (`--without-java`) |
| Math | — | No |

## Quick Start (macOS)

```bash
# Prerequisites
xcode-select --install
brew install autoconf automake gperf openjdk@17

# Build (2-3h first time)
./scripts/build.sh

# Run
libreoffice/instdir/program/soffice
```

## What This Repo Contains

- `config/` — Default settings (NotebookBar, OOXML save format, auto-save)
- `branding/` — Splash screen, logos, about images
- `scripts/` — Build, branding overlay, packaging scripts
- `extensions/auth-gate/` — Login gate extension (requires EUnifyer account)
- `.github/workflows/` — CI pipelines for macOS, Linux, and Windows builds

## Branding Only (no rebuild)

```bash
# After a full build, apply branding changes in seconds:
./scripts/brand-overlay.sh
```

## Packaging (per platform)

After a build produces `libreoffice/instdir`, package native installers:

```bash
./scripts/package-macos.sh   1.0.0   # → dist/EUnifyer Office.app + EUnifyer-Office.dmg
./scripts/package-linux.sh   1.0.0   # → dist/*.tar.gz + .deb + .AppImage
./scripts/package-windows.sh 1.0.0   # → dist/*.zip + .msi (runs package-windows.ps1)
```

Each packager installs to a fixed, detectable layout so **EUnifyer Desktop**
can find Office automatically (`office.rs`):

| Platform | Install path | Launcher | Version source |
|---|---|---|---|
| macOS | `/Applications/EUnifyer Office.app` | bundle | `Contents/Info.plist` |
| Linux | `/opt/eunifyer-office` | `program/soffice` | `version` file |
| Windows | `%ProgramFiles%\EUnifyer Office` | `program\soffice.exe` | `version` file |

On tagged releases (`v*`), CI publishes the installers to the public
`EUnifyer/eunify-office-dist` mirror, which the
[download page](https://eunifyer.com/download#office) serves to users.

## EUnifyer Desktop integration

Office and **[EUnifyer Desktop](../eunify-desktop)** (the Drive sync client)
are deeply aligned:

- The bundled **auth-gate** extension shares the OS-keychain login with Desktop
  and, if Desktop isn't installed, points users to
  <https://eunifyer.com/download#desktop>.
- Office saves into the synced `~/EUnifyer` folder by default.
- Desktop detects an installed Office and adds an "Open in EUnifyer Office"
  action to every document; when Office is missing it links to
  <https://eunifyer.com/download#office>.

## License

This overlay is proprietary (branding, logos, extensions).
The underlying LibreOffice source is MPL-2.0 — keep the fork public.
