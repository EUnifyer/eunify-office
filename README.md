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

Branding uses the October 2026 Open Circle kit. Generate its assets from the
sibling `eunify` checkout with
`node infra/scripts/brand/build-assets.mjs --siblings` before applying the
overlay. New documents and bundled default templates use Sora. Existing
documents keep their fonts. Installers need a new packaged release to receive
the updated icons and splash screen.

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

Office and **[EUnifyer Desktop](https://eunifyer.com/download#desktop)** (the
Drive sync client) are deeply aligned:

- The bundled **auth-gate** extension shares the OS-keychain login with Desktop
  and, if Desktop isn't installed, points users to
  <https://eunifyer.com/download#desktop>.
- Office saves into the synced `~/EUnifyer` folder by default.
- Desktop detects an installed Office and adds an "Open in EUnifyer Office"
  action to every document; when Office is missing it links to
  <https://eunifyer.com/download#office>.

## License

This repository — the build scripts, configuration, extensions and branding
assets — is licensed under **Apache-2.0**. See [LICENSE](./LICENSE).

It does **not** contain LibreOffice source code. It builds on top of it.

### Upstream

| Component | Source | License |
|---|---|---|
| LibreOffice Community (our fork) | [EUnifyer/libreoffice-core](https://github.com/EUnifyer/libreoffice-core) | MPL-2.0 |
| LibreOffice Community (upstream) | [libreoffice/core](https://git.libreoffice.org/core) | MPL-2.0 |
| DM Sans (`branding/fonts/`) | [Google Fonts](https://fonts.google.com/specimen/DM+Sans) | OFL-1.1 — see [OFL.txt](./branding/fonts/OFL.txt) |
| Sora (`branding/fonts/`) | Supplied Open Circle brand kit | OFL-1.1 — see [Sora-OFL.txt](./branding/fonts/Sora-OFL.txt) |

Our modifications to LibreOffice — branding assets, default font stack,
Start Center changes and menu configuration — live in the
[libreoffice-core fork](https://github.com/EUnifyer/libreoffice-core), which is
public under MPL-2.0 as that license requires. The fork keeps the upstream
`COPYING`, `COPYING.MPL` and `COPYING.LGPL` notices and the unmodified About
dialog intact.

### Trademarks

EUnifyer is not affiliated with, endorsed by, or sponsored by The Document
Foundation. "LibreOffice" and the LibreOffice logo are trademarks of The
Document Foundation, used here only to identify the upstream project in
accordance with [TDF's trademark policy](https://wiki.documentfoundation.org/TradeMark_Policy).
The EUnifyer name and logos are not covered by the Apache-2.0 grant above.
