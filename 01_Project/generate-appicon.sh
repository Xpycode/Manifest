#!/usr/bin/env bash
#
# generate-appicon.sh — slice a 1024×1024 master PNG into every macOS app-icon
# size and rewrite the asset catalog's Contents.json to reference them.
#
# Usage:
#   ./generate-appicon.sh path/to/icon-1024.png
#
# The master must be a square PNG, ideally 1024×1024 (larger is fine — sips
# downscales). Output lands in Manifest/Assets.xcassets/AppIcon.appiconset/.
#
# Source of truth (as of 2026-05-29) is the Icon Composer export at
#   04_Exports/Icon Exports/Icon-iOS-Default-1024x1024@1x.png
# (the "Input Ripple" art — refined full-bleed version). Slice it directly:
#   ./01_Project/generate-appicon.sh "04_Exports/Icon Exports/Icon-iOS-Default-1024x1024@1x.png"
# We use the Default appearance variant only — macOS 15's classic asset-catalog
# iconset can't consume the Dark/Clear/Tinted variants (those are iOS 18 /
# macOS 26 Liquid Glass features). The earlier hand-built Manifest-icon.svg is
# superseded. After running, regenerating the project (`cd 01_Project &&
# xcodegen`) is NOT needed — asset catalog contents are picked up on next build.
#
set -euo pipefail

MASTER="${1:-}"
if [[ -z "$MASTER" || ! -f "$MASTER" ]]; then
  echo "error: pass a path to a square master PNG (e.g. icon-1024.png)" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ICONSET="$SCRIPT_DIR/Manifest/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$ICONSET"

# "size(px) filename" — the 10 entries macOS expects (16/32/128/256/512 @1x,@2x).
# Space-separated rows kept bash-3.2-compatible (macOS default; no assoc arrays).
SPECS="
16 icon_16x16.png
32 icon_16x16@2x.png
32 icon_32x32.png
64 icon_32x32@2x.png
128 icon_128x128.png
256 icon_128x128@2x.png
256 icon_256x256.png
512 icon_256x256@2x.png
512 icon_512x512.png
1024 icon_512x512@2x.png
"

echo "Generating icons from $MASTER into $ICONSET …"
while read -r px name; do
  [[ -z "$px" ]] && continue
  sips -z "$px" "$px" "$MASTER" --out "$ICONSET/$name" >/dev/null
  echo "  ${px}×${px}  → $name"
done <<< "$SPECS"

# Rewrite Contents.json with filenames wired in.
cat > "$ICONSET/Contents.json" <<'JSON'
{
  "images" : [
    { "idiom" : "mac", "scale" : "1x", "size" : "16x16",   "filename" : "icon_16x16.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "16x16",   "filename" : "icon_16x16@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "32x32",   "filename" : "icon_32x32.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "32x32",   "filename" : "icon_32x32@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "128x128", "filename" : "icon_128x128.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "128x128", "filename" : "icon_128x128@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "256x256", "filename" : "icon_256x256.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "256x256", "filename" : "icon_256x256@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "512x512", "filename" : "icon_512x512.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "512x512", "filename" : "icon_512x512@2x.png" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

echo "Done. 10 icon files + Contents.json written. Build to see the new icon."
