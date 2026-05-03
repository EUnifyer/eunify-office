# EUnifyer Office — Brand Assets

Placeholder assets for the LibreOffice fork. Replace with final designs.

## Files

| File | Purpose | Dimensions | Format |
|------|---------|-----------|--------|
| `flat_logo.svg` | Start Center logo | 300×50 | SVG |
| `intro/intro.png` | Splash screen | 661×169 | PNG |
| `about/about.svg` | About dialog | 440×300 | SVG |
| `icons/` | App icons (macOS .icns, Windows .ico) | various | ICO/ICNS |

## Generating splash PNG from SVG

```bash
# Requires ImageMagick or rsvg-convert
rsvg-convert -w 661 -h 169 intro.svg > intro/intro.png
```

## Icon sizes needed

- macOS: 16, 32, 64, 128, 256, 512, 1024 (bundled in .icns)
- Windows: 16, 32, 48, 256 (bundled in .ico)
