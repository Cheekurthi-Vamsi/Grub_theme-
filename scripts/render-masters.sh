#!/bin/bash
#
# scripts/render-masters.sh - rebuild the PNG masters of the icons from their
# SVG sources (developer tool; install.sh does not need it: the masters are
# shipped).
#
#   theme/tux.png        Tux, 2048 px high, from icons/tux.svg
#   icons/png/<os>.png   other systems, 1024 px (longer side), from icons/os/<os>.svg;
#                        logos drawn with very thin lines are made bolder (BOLD),
#                        so they stay readable at icon size (about 74 px)
#
# The Windows logo and the arrow need no master: generate-assets.sh draws the
# polygons of icons/windows.svg and icons/arrow.svg at the final pixel size.
#
# Renderer: librsvg (rsvg-convert, or Python's GdkPixbuf, which uses librsvg).
# ImageMagick's built-in SVG renderer does not draw these files correctly.

set -Eeuo pipefail
P="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
IM=magick; command -v magick >/dev/null 2>&1 || IM=convert
PNG=(-strip -define png:color-type=6 -define png:bit-depth=8)
W="$(mktemp -d)"
trap 'rm -rf -- "$W"' EXIT

# render SVG SIZE OUT: the whole SVG canvas, fitted into SIZE x SIZE.
render() {
    if command -v rsvg-convert >/dev/null 2>&1; then
        rsvg-convert --keep-aspect-ratio -w "$2" -h "$2" -o "$3" "$1"
    else
        python3 - "$1" "$2" "$3" <<'EOF'
import sys, gi
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import GdkPixbuf
svg, size, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
GdkPixbuf.Pixbuf.new_from_file_at_scale(svg, size, size, True).savev(out, "png", [], [])
EOF
    fi
}

# master SVG LONG_SIDE OUT: render so that the trimmed drawing has LONG_SIDE
# px on its longer side (measured once; the result itself is never resampled).
master() {
    local svg="$1" want="$2" out="$3" dim
    render "$svg" 1024 "$W/probe.png" || { echo "librsvg is needed: sudo apt install librsvg2-bin" >&2; exit 1; }
    dim="$("$IM" "$W/probe.png" -trim -format '%[fx:max(w,h)]' info:)"
    render "$svg" "$(( (want * 1024 + dim - 1) / dim ))" "$W/full.png"
    "$IM" "$W/full.png" -trim +repage -colorspace sRGB "${PNG[@]}" "PNG32:$out"
}

master "$P/icons/tux.svg" 2048 "$P/theme/tux.png"
file "$P/theme/tux.png"

# Extra stroke width in px at 1024 px (chosen by looking at them at 74 px).
bold() {
    case "$1" in
        kali) echo 16 ;;
        centos|elementary|kdeneon) echo 6 ;;
        debian) echo 5 ;;
        *) echo 0 ;;
    esac
}

mkdir -p "$P/icons/png"
n=0
for svg in "$P"/icons/os/*.svg; do
    k="$(basename "$svg" .svg)"
    master "$svg" 1024 "$P/icons/png/$k.png"
    b="$(bold "$k")"
    if [ "$b" -gt 0 ]; then
        "$IM" "$P/icons/png/$k.png" -bordercolor none -border "$b" -channel A -morphology Dilate "Disk:$b" +channel \
            -trim +repage "${PNG[@]}" "PNG32:$P/icons/png/$k.png"
    fi
    n=$((n + 1))
done
echo "$n system icons rendered to icons/png/"
