#!/usr/bin/env bash
# Regenerates every Ninjy icon from the source logo (assets/brand/ninjy-atom.png,
# a 1024x1024 atom on black). The atom sits on a dark #090909 rounded-square
# backplate wherever the platform allows one. Outputs are committed; re-running
# rewrites them byte-for-byte (PNG date/time chunks are excluded).
#
#   scripts/brand/gen-icons.sh             regenerate in place
#   scripts/brand/gen-icons.sh --sheet F   also write a contact sheet of every icon to F
#
# Needs ImageMagick 7 and libicns (png2icns); without them on PATH the script
# re-runs itself under `nix shell` (no npm dependencies). The sheet labels use
# DejaVu Sans.
set -euo pipefail

if ! command -v magick >/dev/null || ! command -v png2icns >/dev/null; then
  exec nix shell nixpkgs#imagemagick nixpkgs#libicns nixpkgs#dejavu_fonts -c bash "$0" "$@"
fi

sheet=""
if [[ "${1:-}" == "--sheet" ]]; then sheet="${2:?--sheet needs a path}"; fi

root="$(cd "$(dirname "$0")/../.." && pwd)"
src="$root/assets/brand/ninjy-atom.png"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

PLATE='#090909'
# Status dot colours, one per bridgesvc.Tray_Level.
declare -A DOT=([ok]='#22c55e' [warning]='#f59e0b' [error]='#ef4444')
TRAY_SIZES=(16 22 24 32 44)

# Deterministic PNG output: no timestamps, no ancillary text.
png() { echo "-strip -define png:exclude-chunks=date,time,tEXt,zTXt,iTXt -define png:color-type=6 PNG32:$1"; }

# The atom cropped to its bounding box and padded square on black.
magick "$src" -fuzz 4% -trim +repage -background black -gravity center \
  -extent '%[fx:max(w,h)]x%[fx:max(w,h)]' "$tmp/atom.png"

# master OUT PLATE_INSET RADIUS ATOM [full]
#   1024px master: a PLATE_INSET-inset rounded square (RADIUS, fraction of the
#   plate) with the atom at ATOM (fraction of the plate). "full" fills the
#   canvas with an opaque square plate instead (maskable / apple-touch).
# The logo's black is lifted to the plate colour with Lighten, so no seam shows.
master() {
  local out="$1" inset="$2" radius="$3" atom="$4" mode="${5:-}"
  local c=1024 p a r o
  p=$(( c - 2 * inset ))
  a=$(awk -v p="$p" -v f="$atom" 'BEGIN{printf "%d", p*f+0.5}')
  r=$(awk -v p="$p" -v f="$radius" 'BEGIN{printf "%d", p*f+0.5}')
  if [[ "$mode" == full ]]; then
    magick -size ${c}x${c} "xc:$PLATE" -type TrueColorAlpha "$tmp/plate.png"
  else
    magick -size ${c}x${c} xc:none -fill "$PLATE" \
      -draw "roundrectangle $inset,$inset $((c - inset - 1)),$((c - inset - 1)) $r,$r" -type TrueColorAlpha "$tmp/plate.png"
  fi
  # The grey plate alone would make ImageMagick write a grey image: keep sRGB.
  magick "$tmp/plate.png" -colorspace sRGB \( "$tmp/atom.png" -resize ${a}x${a} \) -gravity center -compose Lighten -composite \
    \( "$tmp/plate.png" -alpha extract \) -compose CopyOpacity -composite $(png "$out")
}

# dot IN OUT COLOUR: a status dot in the bottom-right corner, ringed in the
# plate colour so it reads against the atom at 16px.
dot() {
  local in="$1" out="$2" colour="$3" c=1024
  local d=$(( c * 46 / 100 )) ring=$(( c * 6 / 100 ))
  local cx=$(( c - d / 2 )) cy=$(( c - d / 2 ))
  magick "$in" -fill "$PLATE" -draw "circle $cx,$cy $cx,$((cy - d / 2))" \
    -fill "$colour" -draw "circle $cx,$cy $cx,$((cy - d / 2 + ring))" $(png "$out")
}

# size IN OUT N
size() { magick "$1" -filter Lanczos -resize "$3x$3" $(png "$2"); }

# ico IN OUT N...
ico() {
  local in="$1" out="$2"; shift 2
  local parts=()
  for n in "$@"; do size "$in" "$tmp/ico-$n.png" "$n"; parts+=("$tmp/ico-$n.png"); done
  magick "${parts[@]}" -strip "ICO:$out"
}

# Masters.
master "$tmp/app.png"      0   0.225 0.72          # desktop / web "any": full-size rounded square
master "$tmp/mac.png"      100 0.225 0.72          # macOS grid: 824 plate inside 1024
master "$tmp/maskable.png" 0   0     0.64 full     # atom well inside the 80% safe circle
master "$tmp/touch.png"    0   0     0.72 full     # iOS masks its own corners
master "$tmp/small.png"    0   0.225 0.86          # favicon / tray: atom as large as it reads

mkdir -p "$root/src/ui/electron" "$root/build" "$root/public" "$root/landing-page" "$root/src/bridge/assets/tray"

# Desktop app.
size "$tmp/app.png" "$root/src/ui/electron/icon.png" 1024
ico  "$tmp/app.png" "$root/src/ui/electron/icon.ico" 16 24 32 48 64 128 256
for n in 16 32 64 128 256 512 1024; do size "$tmp/mac.png" "$tmp/icns_$n.png" "$n"; done
# png2icns picks the icns slot from each PNG's size.
png2icns "$root/build/icon.icns" "$tmp"/icns_{16,32,128,256,512,1024}.png >/dev/null

# Web app and landing page.
size "$tmp/app.png"      "$root/public/icon.png"             512
size "$tmp/maskable.png" "$root/public/icon-maskable.png"    512
size "$tmp/touch.png"    "$root/public/apple-touch-icon.png" 180
size "$tmp/small.png"    "$root/public/favicon-32.png"       32
size "$tmp/small.png"    "$root/landing-page/favicon.png"    64

# Bridge tray: one PNG per size and one .ico per level (src/bridge/assets/tray).
for level in ok warning error; do
  dot "$tmp/small.png" "$tmp/tray-$level.png" "${DOT[$level]}"
  for n in "${TRAY_SIZES[@]}"; do
    size "$tmp/tray-$level.png" "$root/src/bridge/assets/tray/tray-$level-$n.png" "$n"
  done
  ico "$tmp/tray-$level.png" "$root/src/bridge/assets/tray/tray-$level.ico" 16 20 24 32 48
done

if [[ -n "$sheet" ]]; then
  # Every committed icon at its real size, labelled, on a mid-grey tile.
  files=(src/ui/electron/icon.png public/icon.png public/icon-maskable.png public/apple-touch-icon.png
         public/favicon-32.png landing-page/favicon.png)
  for level in ok warning error; do
    for n in "${TRAY_SIZES[@]}"; do files+=("src/bridge/assets/tray/tray-$level-$n.png"); done
  done
  args=()
  for f in "${files[@]}"; do
    args+=(-label "${f##*/} $(magick identify -format '%wx%h' "$root/$f")" "$root/$f")
  done
  icns_x="$tmp/icns-x"; mkdir -p "$icns_x"
  icns2png -x -s 512 -o "$icns_x" "$root/build/icon.icns" >/dev/null
  args+=(-label "icon.icns 512" "$icns_x"/*.png)
  magick montage -font DejaVu-Sans -pointsize 12 -fill '#e5e5e5' -background '#2a2a2a' \
    "${args[@]}" -geometry '256x256>+8+8' -tile 6x "$sheet"
fi
