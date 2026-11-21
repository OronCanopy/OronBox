#!/usr/bin/env bash
# Regenerate every platform app icon from a single SVG source.
# Usage: tool/generate_icons.sh [path/to/icon.svg]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SVG="${1:-$ROOT/assets/images/app_icon.svg}"
if [[ ! -f "$SVG" ]]; then
  echo "[ERROR] SVG source not found: $SVG" >&2
  exit 1
fi
for cmd in rsvg-convert magick python3; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[ERROR] $cmd is required" >&2
    exit 1
  fi
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Android adaptive-icon foreground: the logo on transparency, with the white
# background rounded rect stripped out.
python3 - "$SVG" "$TMP/foreground.svg" <<'EOF'
import re
import sys

with open(sys.argv[1], encoding='utf-8') as handle:
    src = handle.read()
stripped, count = re.subn(r'<path\b[^>]*fill="#FFFFFF"[^>]*/>', '', src, count=1)
if count != 1:
    sys.exit('expected exactly one white background path in the SVG')
with open(sys.argv[2], 'w', encoding='utf-8') as handle:
    handle.write(stripped)
EOF

render() { # <svg> <size> <output>
  rsvg-convert -w "$2" -h "$2" "$1" -o "$3"
  echo "[INFO] ${3#"$ROOT"/} ($2x$2)"
}

render_flat() { # <svg> <size> <output> [background=white] — flattened, no alpha
  rsvg-convert -w "$2" -h "$2" "$1" -o "$TMP/flat.png"
  magick "$TMP/flat.png" -background "${4:-white}" -alpha remove -alpha off "$3"
  echo "[INFO] ${3#"$ROOT"/} ($2x$2, ${4:-white} background)"
}

# Menu bar template derived from the OronBox logo.
python3 - "$ROOT/assets/images/app_icon.svg" "$TMP/tray_macos.svg" <<'EOF'
import sys
import xml.etree.ElementTree as ET

namespace = 'http://www.w3.org/2000/svg'
paths = ET.parse(sys.argv[1]).iter(f'{{{namespace}}}path')
by_color = {path.get('fill'): path.get('d') for path in paths}
ring = by_color['#444C53']
star = by_color['#9EBBDA']
star_outline = by_color['#F4F5FD']

svg = ET.Element('svg', xmlns=namespace, width='36', height='36', viewBox='38 38 180 180')
mask = ET.SubElement(
    svg, 'mask', id='ring', maskUnits='userSpaceOnUse',
    x='0', y='0', width='256', height='256',
)
ET.SubElement(mask, 'rect', width='256', height='256', fill='white')
ET.SubElement(mask, 'path', d=star_outline, fill='black')
ET.SubElement(svg, 'path', d=ring, fill='black', mask='url(#ring)')
ET.SubElement(svg, 'path', d=star, fill='black')
ET.ElementTree(svg).write(sys.argv[2], encoding='utf-8')
EOF
render "$TMP/tray_macos.svg" 36 "$ROOT/assets/images/tray_icon_macos.png"

# In-repo source PNG.
render "$SVG" 512 "$ROOT/assets/images/app_icon.png"

# Android launcher icons.
for spec in mdpi:48 hdpi:72 xhdpi:96 xxhdpi:144 xxxhdpi:192; do
  render "$SVG" "${spec##*:}" \
    "$ROOT/android/app/src/main/res/mipmap-${spec%%:*}/ic_launcher.png"
done

# Android adaptive icon: foreground logo at 2/3 size (safe zone) centered on
# transparency; monochrome is a baseline-normalized luminance tint mask of the
# whole icon — the ring anchors at alpha 1.0, the white background at 0, and
# the remaining parts scale proportionally to their color depth. Color black.
for spec in mdpi:108 hdpi:162 xhdpi:216 xxhdpi:324 xxxhdpi:432; do
  dir="${spec%%:*}"
  size="${spec##*:}"
  render "$TMP/foreground.svg" $((size * 2 / 3)) "$TMP/foreground.png"
  foreground="$ROOT/android/app/src/main/res/drawable-$dir/ic_launcher_foreground.png"
  magick -size "${size}x${size}" xc:none "$TMP/foreground.png" \
    -gravity center -composite "$foreground"
  echo "[INFO] ${foreground#"$ROOT"/} (${size}x$size)"
  render "$SVG" $((size * 2 / 3)) "$TMP/logo.png"
  magick -size "${size}x${size}" xc:white "$TMP/logo.png" \
    -gravity center -composite "$TMP/flat.png"
  # Baseline-normalized tint mask: alpha = (1 - luminance) / (1 - min_luma),
  # so the darkest pixel (the ring) anchors at 1.0, the white background
  # stays 0 and every other part scales proportionally.
  minLuma=$(magick "$TMP/flat.png" -colorspace Gray -format "%[fx:minima]" info:)
  magick "$TMP/flat.png" -colorspace Gray -alpha set -channel A \
    -fx "(1-intensity)/(1-$minLuma)" +channel \
    -channel RGB -evaluate set 0 +channel \
    "PNG32:$ROOT/android/app/src/main/res/drawable-$dir/ic_launcher_monochrome.png"
  echo "[INFO] android/app/src/main/res/drawable-$dir/ic_launcher_monochrome.png"
done

# iOS (opaque, App Store safe).
IOS_DIR="$ROOT/ios/Runner/Assets.xcassets/AppIcon.appiconset"
IOS_SPECS="
  20x20@1x:20 20x20@2x:40 20x20@3x:60
  29x29@1x:29 29x29@2x:58 29x29@3x:87
  40x40@1x:40 40x40@2x:80 40x40@3x:120
  60x60@2x:120 60x60@3x:180
  76x76@1x:76 76x76@2x:152
  83.5x83.5@2x:167 1024x1024@1x:1024
"
for spec in $IOS_SPECS; do
  render_flat "$SVG" "${spec##*:}" "$IOS_DIR/Icon-App-${spec%%:*}.png"
done

# iOS dark-appearance icons (iOS 18+; ignored by older versions).
DARK_SVG="${2:-}"
if [[ -n "$DARK_SVG" ]]; then
  if [[ ! -f "$DARK_SVG" ]]; then
    echo "[ERROR] dark SVG source not found: $DARK_SVG" >&2
    exit 1
  fi
  for spec in $IOS_SPECS; do
    render_flat "$DARK_SVG" "${spec##*:}" \
      "$IOS_DIR/Icon-App-${spec%%:*}-dark.png" '#22272A'
  done
  python3 - "$IOS_DIR/Contents.json" <<'EOF'
import json
import sys

path = sys.argv[1]
with open(path, encoding='utf-8') as handle:
    data = json.load(handle)
base = [entry for entry in data['images'] if 'appearances' not in entry]
dark = []
for entry in base:
    variant = dict(entry)
    variant['filename'] = entry['filename'].replace('.png', '-dark.png')
    variant['appearances'] = [{'appearance': 'luminosity', 'value': 'dark'}]
    dark.append(variant)
data['images'] = base + dark
with open(path, 'w', encoding='utf-8') as handle:
    json.dump(data, handle, indent=2)
    handle.write('\n')
EOF
  echo "[INFO] ios/.../AppIcon.appiconset/Contents.json (dark appearances)"
fi

# macOS.
MAC_DIR="$ROOT/macos/Runner/Assets.xcassets/AppIcon.appiconset"
for size in 16 32 64 128 256 512 1024; do
  render "$SVG" "$size" "$MAC_DIR/app_icon_$size.png"
done

# Windows multi-resolution ICO.
render_flat "$SVG" 256 "$TMP/icon256.png"
magick "$TMP/icon256.png" -define icon:auto-resize=16,24,32,48,64,128,256 \
  "$ROOT/windows/runner/resources/app_icon.ico"
echo "[INFO] windows/runner/resources/app_icon.ico (16-256)"

# Web (maskable icons must be full-bleed).
render "$SVG" 32 "$ROOT/web/favicon.png"
render "$SVG" 192 "$ROOT/web/icons/Icon-192.png"
render "$SVG" 512 "$ROOT/web/icons/Icon-512.png"
render_flat "$SVG" 192 "$ROOT/web/icons/Icon-maskable-192.png"
render_flat "$SVG" 512 "$ROOT/web/icons/Icon-maskable-512.png"

# Linux hicolor theme.
for size in 16 32 48 64 128 256 512; do
  render "$SVG" "$size" \
    "$ROOT/linux/icons/hicolor/${size}x${size}/apps/org.zxor.oronbox.png"
done

echo "[INFO] All icons generated from $SVG"
