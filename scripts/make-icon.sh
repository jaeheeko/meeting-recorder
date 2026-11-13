#!/bin/bash
# assets/AppIcon.svg → Resources/AppIcon.icns (qlmanage로 1024 렌더 → sips 리사이즈 → iconutil)
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); SET="$T/AppIcon.iconset"; mkdir -p "$SET"
qlmanage -t -s 1024 -o "$T" assets/AppIcon.svg >/dev/null 2>&1
BASE="$T/AppIcon.svg.png"
[ -f "$BASE" ] || { echo "qlmanage 렌더 실패"; exit 1; }
for s in 16 32 128 256 512; do
  sips -z $s $s "$BASE" --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$BASE" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
echo "made: Resources/AppIcon.icns"
