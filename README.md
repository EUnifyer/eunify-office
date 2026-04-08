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
- `.github/workflows/` — CI pipelines for macOS + Windows builds

## Branding Only (no rebuild)

```bash
# After a full build, apply branding changes in seconds:
./scripts/brand-overlay.sh
```

## License

This overlay is proprietary (branding, logos, extensions).
The underlying LibreOffice source is MPL-2.0 — keep the fork public.
