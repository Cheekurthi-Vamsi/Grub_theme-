#!/bin/bash
#
# generate-assets.sh - build the grub-icon-menu theme for one screen size.
#
#   scripts/generate-assets.sh --resolution 1920x1080 --out DIR [--order "windows linux kali"]
#       [--no-title] [--background FILE] [--icon-color auto|black|white]
#       [--shadow auto|on|off]
#
# Writes a complete, self-contained theme directory (nothing is installed):
#   icon-menu.txt          theme of the icon chooser
#   theme.txt              theme of the full standard menu (ESC fallback)
#   chooser.cfg            nested-menu loader (static)
#   icons/gim-<layout>-<i>.png
#                          one image per layout and selected position: all
#                          icons of the layout with the arrow under icon <i>
#   background.png         --background picture, cropped to fill the screen
#   title.png, line.png, corner_*.png, select_*.png, gim-mono-*.pf2, .grub-icon-menu
#
# Why composite images: GRUB's boot_menu can only draw a vertical list. The
# chooser theme shows exactly ONE list row (the selected entry) whose icon is
# a picture of every icon with the arrow under the selected one, so Up/Down
# appear to move the arrow left/right across a horizontal row of icons.
#
# Sharpness: GRUB draws every image at its own size (no scaling), so each
# icon is made for the exact pixel size it is shown at. The Windows logo and
# the arrow are drawn from the polygons in icons/*.svg: vertices snapped to
# the pixel grid, drawn 8x larger without anti-aliasing and reduced by
# averaging 8x8 blocks (exact edge coverage, no blur, no halo). The Tux is
# reduced from its 2048 px master (theme/tux.png, from icons/tux.svg), every
# other system (kali, linuxmint, arch, ...) from icons/png/<kind>.png.
# --order lists at most 6 kinds: windows, linux (this Ubuntu, Tux) and any
# kind with a master in icons/png/.
#
# Colours: icons, arrow, title and frame are black on light backgrounds and
# white on dark ones (--icon-color auto measures the background behind the
# icons). White mode gives the black-and-white Tux a thin light outline. With
# a background picture everything gets a soft shadow (--shadow auto).
#
# Sizes are designed for 1920x1080 and scaled to the target resolution;
# positions are percentages, so the layout stays centred at any resolution.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$PROJECT_DIR/lib/common.sh"

RESOLUTION="1920x1080"
OUT=""
ORDER="windows linux"
TITLE=yes                 # --no-title: no ">_GRUB / BOOTMENU" text on screen
BACKGROUND=""             # picture file; empty = plain white screen
ICON_COLOR=auto
SHADOW=auto
SRC="$PROJECT_DIR/theme"
ICONS="$PROJECT_DIR/icons"

usage() {
    sed -n '3,7p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --resolution) RESOLUTION="${2:-}"; shift 2 ;;
        --out)        OUT="${2:-}"; shift 2 ;;
        --order)      ORDER="${2:-}"; shift 2 ;;
        --no-title|-rt) TITLE=no; shift ;;
        --background|-bg) BACKGROUND="${2:-}"; shift 2 ;;
        --icon-color) ICON_COLOR="${2:-}"; shift 2 ;;
        --shadow)     SHADOW="${2:-}"; shift 2 ;;
        -h|--help)    usage 0 ;;
        *)            log_error "unknown option: $1"; usage 1 ;;
    esac
done

[ -n "$OUT" ] || die "--out DIR is required"
case "$RESOLUTION" in
    [1-9][0-9][0-9]x[1-9][0-9][0-9]|[1-9][0-9][0-9][0-9]x[1-9][0-9][0-9]|[1-9][0-9][0-9][0-9]x[1-9][0-9][0-9][0-9]) ;;
    *) die "invalid resolution '$RESOLUTION' (expected WIDTHxHEIGHT)" ;;
esac
for k in $ORDER; do
    case "$k" in
        windows|linux) ;;
        *) case "$k" in *[!a-z0-9]*) die "invalid kind '$k' in --order" ;; esac
           [ -f "$ICONS/png/$k.png" ] || die "no icon for '$k' in --order (missing icons/png/$k.png)" ;;
    esac
done
MAX_ICONS=6
case "$ICON_COLOR" in auto|black|white) ;; *) die "invalid --icon-color '$ICON_COLOR' (auto, black or white)" ;; esac
case "$SHADOW" in auto|on|off) ;; *) die "invalid --shadow '$SHADOW' (auto, on or off)" ;; esac
if [ "$BACKGROUND" = none ]; then BACKGROUND=""; fi

# ImageMagick 7 (magick) or 6 (convert).
if command -v magick >/dev/null 2>&1; then IM=(magick)
elif command -v convert >/dev/null 2>&1; then IM=(convert)
else die "ImageMagick is required (sudo apt install imagemagick)"; fi
require_cmd grub-mkfont file fc-list awk sha256sum

for f in "$SRC/tux.png" "$SRC/chooser.cfg" "$ICONS/windows.svg" "$ICONS/arrow.svg"; do
    [ -f "$f" ] || die "missing source asset: $f"
done

SCREEN_W="${RESOLUTION%x*}"
SCREEN_H="${RESOLUTION#*x}"

# Scale factor relative to the 1920x1080 design.
SCALE="$(awk -v w="$SCREEN_W" -v h="$SCREEN_H" 'BEGIN { a = w / 1920; b = h / 1080; printf "%.4f", (a < b ? a : b) }')"
px() { awk -v v="$1" -v s="$SCALE" 'BEGIN { r = int(v * s + 0.5); if (r < 1) r = 1; print r }'; }

# Size of the icon row (icons, their spacing and the arrow) relative to the
# original design, where the Windows logo is 118 px at 1920x1080. Lower it for
# smaller icons, then apply with: sudo ./update.sh --rebuild
ICON_SCALE=0.6
ipx() { px "$(awk -v v="$1" -v k="$ICON_SCALE" 'BEGIN { print v * k }')"; }
# Same, as a decimal number (outline width, shadow).
fpx() { awk -v v="$1" -v s="$SCALE" -v k="$ICON_SCALE" 'BEGIN { printf "%.2f", v * s * k }'; }
# Same parity as $2: centres an item exactly inside a cell of width $2.
parity() { if [ $(( ($1 - $2) % 2 )) -ne 0 ]; then echo $(( $1 + 1 )); else echo "$1"; fi; }

# ---- design (pixels at 1920x1080) -------------------------------------------
CELL_W=$(ipx 170)         # one icon cell
CELL_H=$(ipx 140)
PITCH=$(ipx 245)          # centre-to-centre distance of two icons
WIN_SIZE=$(parity "$(ipx 118)" "$CELL_W")   # Windows logo, square
WIN_CORNER="$(awk -v w="$WIN_SIZE" 'BEGIN { printf "%.2f", w * 34 / 1024 }')"   # rounded corners
TUX_H=$(ipx 138)          # Tux height (slightly taller: similar visual weight)
OS_BOX=$(ipx 124)         # other systems: fitted into this square
ARROW_W=$(parity "$(ipx 44)" "$CELL_W")     # arrow under the selected icon
ARROW_GAP=$(ipx 55)       # icon cell bottom -> arrow tip
PAD=$(ipx 16)             # room around the icon row for the shadow
OUTLINE="$(fpx 2.5)"      # light outline of the Tux on dark backgrounds
SHADOW_SIGMA="$(fpx 4)"
SHADOW_OFFSET=$(ipx 3)
SHADOW_OPACITY=0.45
BORDER_INSET=$(px 14)
BORDER_W=$(px 2); [ "$BORDER_W" -ge 2 ] || BORDER_W=2   # >= 2: see line.png below
BORDER_RADIUS=$(px 28)    # rounded frame corners (outer radius)
[ "$BORDER_RADIUS" -gt "$BORDER_W" ] || BORDER_RADIUS=$(( BORDER_W + 1 ))
TITLE_PT=$(px 52)
FONT_ITEM=$(px 24)
FONT_SMALL=$(px 18)
SEL_PAD=2                 # selection bar slices, adds 2 px per side
ITEM_H=$(px 42)
ITEM_SPACING=$(( $(px 6) + 2 * SEL_PAD ))   # keeps the bar off the next row
ICON_TEXT_GAP=$(px 12)

ARROW_H="$(awk -v w="$ARROW_W" -v f="$ICONS/arrow.svg" 'BEGIN {
    while ((getline l < f) > 0) if (match(l, /viewBox="0 0 [0-9.]+ [0-9.]+"/)) {
        split(substr(l, RSTART + 13, RLENGTH - 14), a, " "); printf "%d", a[2] * w / a[1] + 0.5; exit } }')"
[ -n "$ARROW_H" ] || die "icons/arrow.svg has no viewBox"

NKINDS=0; for k in $ORDER; do NKINDS=$((NKINDS + 1)); done
[ "$NKINDS" -ge 1 ] || die "--order must list at least one kind"
[ "$NKINDS" -le "$MAX_ICONS" ] || die "--order lists $NKINDS kinds; at most $MAX_ICONS icons fit in one row"
COMP_W=$(( (NKINDS - 1) * PITCH + CELL_W + 2 * PAD ))
COMP_H=$(( PAD + CELL_H + ARROW_GAP + ARROW_H + PAD ))
COMP_TOP_OFF=$(( PAD + CELL_H / 2 ))     # composite top = screen centre - this

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gim-assets.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

mkdir -p -- "$OUT/icons"
rm -f -- "$OUT/background.png"

# identify(1) is "magick identify" on ImageMagick 7.
im_identify() { if [ "${IM[0]}" = magick ]; then magick identify "$@"; else identify "$@"; fi; }
PNG_OUT=(-strip -define png:color-type=6 -define png:bit-depth=8)

log_info "Generating theme for ${SCREEN_W}x${SCREEN_H} (scale $SCALE) into $OUT"

# ---- background picture -----------------------------------------------------
# Scaled to cover the whole screen (aspect ratio kept, centred, overflow cut
# off) once here, so GRUB never has to scale it. PNG: lossless.
BG_SHA=none
if [ -n "$BACKGROUND" ]; then
    [ -f "$BACKGROUND" ] && [ -r "$BACKGROUND" ] || die "background picture not found or not readable: $BACKGROUND"
    [ "$(stat -c %s -- "$BACKGROUND")" -le $((80 * 1024 * 1024)) ] || die "background picture is larger than 80 MB: $BACKGROUND"
    src_size="$("${IM[@]}" "$BACKGROUND[0]" -auto-orient -format '%w %h' info: 2>/dev/null)" \
        || die "not a picture ImageMagick can read: $BACKGROUND"
    read -r src_w src_h <<<"$src_size"
    if awk -v w="$src_w" -v h="$src_h" -v W="$SCREEN_W" -v H="$SCREEN_H" \
           'BEGIN { s = W / w; if (H / h > s) s = H / h; exit !(s > 1.1) }'; then
        log_warn "the background picture (${src_w}x${src_h}) is smaller than the screen (${SCREEN_W}x${SCREEN_H}):"
        log_warn "it is enlarged and will look soft. A picture of at least ${SCREEN_W}x${SCREEN_H} looks sharp."
    fi
    "${IM[@]}" "$BACKGROUND[0]" -auto-orient -colorspace sRGB -background white -alpha remove -alpha off \
        -filter Lanczos -resize "${SCREEN_W}x${SCREEN_H}^" -gravity center -extent "${SCREEN_W}x${SCREEN_H}" +repage \
        -depth 8 -strip -define png:color-type=2 "PNG24:$OUT/background.png" \
        || die "converting the background picture failed: $BACKGROUND"
    BG_SHA="$(sha256sum <"$BACKGROUND" | cut -c1-64)"
fi

# ---- colours --------------------------------------------------------------------
# auto: the colour with more contrast against the background behind the icon
# row (relative luminance 0.179 gives the same contrast to black and white).
BG_LUMA=1
if [ -n "$BACKGROUND" ]; then
    BG_LUMA="$("${IM[@]}" "$OUT/background.png" \
        -crop "${COMP_W}x${COMP_H}+$(( SCREEN_W / 2 - COMP_W / 2 ))+$(( SCREEN_H / 2 - COMP_TOP_OFF ))" +repage \
        -colorspace RGB -format '%[fx:0.2126*mean.r+0.7152*mean.g+0.0722*mean.b]' info:)"
fi
FG="$ICON_COLOR"
if [ "$FG" = auto ]; then
    FG="$(awk -v l="$BG_LUMA" 'BEGIN { print (l > 0.179 ? "black" : "white") }')"
fi
if [ "$FG" = black ]; then
    FG_HEX="#000000"; INV_HEX="#ffffff"; DIM_HEX="#555555"; CONSOLE_FG=black
else
    FG_HEX="#ffffff"; INV_HEX="#000000"; DIM_HEX="#d0d0d0"; CONSOLE_FG=white
fi
DESKTOP_HEX="#ffffff"
if [ -n "$BACKGROUND" ]; then
    DESKTOP_HEX="#$("${IM[@]}" "$OUT/background.png" -resize '1x1!' -alpha off -depth 8 -format '%[hex:u.p{0,0}]' info: | cut -c1-6)"
fi
SHADOW_ON="$SHADOW"
if [ "$SHADOW_ON" = auto ]; then
    if [ -n "$BACKGROUND" ]; then SHADOW_ON=on; else SHADOW_ON=off; fi
fi
log_info "icons: $FG (setting $ICON_COLOR, background luminance $BG_LUMA), shadow: $SHADOW_ON"

# ---- icons --------------------------------------------------------------------------

# draw_polygons SVG WIDTH COLOR CORNER_RADIUS OUT
# Draws the <polygon> elements of SVG (icons/windows.svg, icons/arrow.svg)
# WIDTH px wide. Vertices are snapped to the pixel grid, so horizontal and
# vertical edges fall exactly between two pixel rows. Drawn 8x larger without
# anti-aliasing, then 8x8 blocks are averaged: every edge pixel gets exactly
# the covered fraction (no blur, no halo on any background). A non-zero
# CORNER_RADIUS rounds the corners: each (convex) polygon is shrunk by the
# radius and drawn with a stroke of twice the radius and round joins.
# (MVG: "#" starts a comment, so the colour is quoted.)
draw_polygons() {
    local svg="$1" width="$2" color="$3" radius="$4" out="$5" ss=8 height mvg
    height="$(awk -v w="$width" -v f="$svg" 'BEGIN {
        while ((getline l < f) > 0) if (match(l, /viewBox="0 0 [0-9.]+ [0-9.]+"/)) {
            split(substr(l, RSTART + 13, RLENGTH - 14), a, " "); printf "%d", a[2] * w / a[1] + 0.5; exit } }')"
    mvg="$(awk -v w="$width" -v r="$radius" -v ss="$ss" -v color="$color" '
        match($0, /viewBox="0 0 [0-9.]+ [0-9.]+"/) {
            split(substr($0, RSTART + 13, RLENGTH - 14), a, " "); s = w / a[1]
        }
        match($0, /<polygon[^>]* points="[^"]*"/) {
            p = substr($0, RSTART, RLENGTH); sub(/.*points="/, "", p); sub(/"$/, "", p)
            n = split(p, t, /[ ,]+/); m = 0
            for (i = 1; i + 1 <= n; i += 2) {
                x = int(t[i] * s + 0.5); y = int(t[i + 1] * s + 0.5)
                if (m > 0 && x == X[m] && y == Y[m]) continue
                m++; X[m] = x; Y[m] = y
            }
            if (m > 2 && X[m] == X[1] && Y[m] == Y[1]) m--
            if (m < 3) next
            if (r > 0) {
                area = 0
                for (i = 1; i <= m; i++) { j = i % m + 1; area += X[i] * Y[j] - X[j] * Y[i] }
                sg = (area > 0) ? 1 : -1
                for (i = 1; i <= m; i++) {            # edge i: vertex i -> i+1, moved inwards
                    j = i % m + 1; dx = X[j] - X[i]; dy = Y[j] - Y[i]; l = sqrt(dx * dx + dy * dy)
                    DX[i] = dx; DY[i] = dy
                    QX[i] = X[i] - sg * dy / l * r; QY[i] = Y[i] + sg * dx / l * r
                }
                for (i = 1; i <= m; i++) {            # new vertex i = edge i-1 x edge i
                    k = (i == 1) ? m : i - 1
                    c = DX[k] * DY[i] - DY[k] * DX[i]
                    u = ((QX[i] - QX[k]) * DY[i] - (QY[i] - QY[k]) * DX[i]) / c
                    PX[i] = QX[k] + u * DX[k]; PY[i] = QY[k] + u * DY[k]
                }
                printf "stroke \"%s\" stroke-width %.2f stroke-linejoin round polygon", color, 2 * r * ss
                for (i = 1; i <= m; i++) printf " %.2f,%.2f", PX[i] * ss - 0.5, PY[i] * ss - 0.5
            } else {
                printf "stroke none polygon"
                for (i = 1; i <= m; i++) printf " %.2f,%.2f", X[i] * ss - 0.5, Y[i] * ss - 0.5
            }
            printf "\n"
        }' "$svg")"
    [ -n "$mvg" ] || die "$svg: no polygons found"
    "${IM[@]}" -size "$((width * ss))x$((height * ss))" xc:none +antialias -fill "$color" -draw "$mvg" \
        -scale "${width}x${height}!" "${PNG_OUT[@]}" "PNG32:$out"
}

# with_shadow FILE: put a soft drop shadow under the shapes of FILE (same
# canvas size; the canvas needs a margin of about 3 x SHADOW_SIGMA).
with_shadow() {
    [ "$SHADOW_ON" = on ] || return 0
    local w h
    w="$(im_identify -format '%w' "$1")"; h="$(im_identify -format '%h' "$1")"
    "${IM[@]}" "$1" \
        \( +clone -alpha extract -background black -splice "0x$SHADOW_OFFSET" -crop "${w}x${h}+0+0" +repage \
           -blur "0x$SHADOW_SIGMA" -evaluate multiply "$SHADOW_OPACITY" \
           \( -size "${w}x${h}" xc:black \) +swap -alpha off -compose CopyOpacity -composite \) \
        +swap -compose Over -composite "${PNG_OUT[@]}" "PNG32:$1.tmp"
    mv -f -- "$1.tmp" "$1"
}

draw_polygons "$ICONS/windows.svg" "$WIN_SIZE" "$FG_HEX" "$WIN_CORNER" "$WORK/windows.png"
draw_polygons "$ICONS/arrow.svg" "$ARROW_W" "$FG_HEX" 0 "$WORK/arrow.png"
if [ "$FG" = black ]; then
    "${IM[@]}" "$SRC/tux.png" -filter Lanczos -resize "x${TUX_H}" "${PNG_OUT[@]}" "PNG32:$WORK/linux.png"
else
    # The Tux keeps its black and white; a thin light outline separates its
    # black back from a dark background. Made at 4x, then averaged down.
    "${IM[@]}" "$SRC/tux.png" -filter Lanczos -resize "x$((TUX_H * 4))" \
        -bordercolor none -border "$(awk -v o="$OUTLINE" 'BEGIN { printf "%d", o * 4 + 4 }')" \
        \( +clone -alpha extract -morphology Dilate "Disk:$(awk -v o="$OUTLINE" 'BEGIN { printf "%.1f", o * 4 }')" \
           \( +clone -fill '#ececec' -colorize 100 \) +swap -alpha off -compose CopyOpacity -composite \) \
        +swap -compose Over -composite -trim +repage -scale 25% "${PNG_OUT[@]}" "PNG32:$WORK/linux.png"
fi
# Other systems: one-colour logos (icons/png/<kind>.png, black masters),
# in the icon colour.
for k in $ORDER; do
    case "$k" in windows|linux) continue ;; esac
    "${IM[@]}" "$ICONS/png/$k.png" -filter Lanczos -resize "${OS_BOX}x${OS_BOX}" \
        -fill "$FG_HEX" -colorize 100 "${PNG_OUT[@]}" "PNG32:$WORK/$k.png"
done

# ---- composites for every layout (non-empty ordered subset of ORDER) ---------
icon_geometry() {   # icon_geometry <kind> <cell_left> -> +X+Y centring the icon in its cell
    local w h
    w="$(im_identify -format '%w' "$WORK/$1.png")"
    h="$(im_identify -format '%h' "$WORK/$1.png")"
    printf '+%d+%d' "$(( PAD + $2 + (CELL_W - w) / 2 ))" "$(( PAD + (CELL_H - h) / 2 ))"
}

read -r -a KINDS <<<"$ORDER"
LAYOUTS=()
for (( mask = 1; mask < (1 << NKINDS); mask++ )); do
    subset=()
    for (( b = 0; b < NKINDS; b++ )); do
        if (( mask & (1 << b) )); then subset+=("${KINDS[$b]}"); fi
    done
    layout="$(IFS=-; printf '%s' "${subset[*]}")"
    LAYOUTS+=("$layout")
    n=${#subset[@]}
    group_w=$(( (n - 1) * PITCH + CELL_W ))
    x0=$(( (COMP_W - 2 * PAD - group_w) / 2 ))
    for (( sel = 0; sel < n; sel++ )); do
        args=(-size "${COMP_W}x${COMP_H}" xc:none)
        for (( j = 0; j < n; j++ )); do
            args+=("$WORK/${subset[$j]}.png" -geometry "$(icon_geometry "${subset[$j]}" $(( x0 + j * PITCH )))" -composite)
        done
        ax=$(( PAD + x0 + sel * PITCH + (CELL_W - ARROW_W) / 2 ))
        ay=$(( PAD + CELL_H + ARROW_GAP ))
        args+=("$WORK/arrow.png" -geometry "+${ax}+${ay}" -composite)
        "${IM[@]}" "${args[@]}" "${PNG_OUT[@]}" "PNG32:$OUT/icons/gim-$layout-$sel.png"
        with_shadow "$OUT/icons/gim-$layout-$sel.png"
    done
done

# ---- title: ">_GRUB / BOOTMENU" in a typewriter face ---------------------------
find_font() {
    local pat f
    for pat in "$@"; do
        f="$(fc-list -f '%{file}\n' "$pat" 2>/dev/null | head -n1)"
        if [ -n "$f" ] && [ -f "$f" ]; then printf '%s\n' "$f"; return 0; fi
    done
    return 1
}
TITLE_FONT="$(find_font 'Nimbus Mono PS:style=Regular' 'FreeMono:style=Regular' \
    'Liberation Mono:style=Regular' 'DejaVu Sans Mono:style=Book')" || TITLE_FONT=""
MENU_FONT="$(find_font 'DejaVu Sans Mono:style=Book' 'Liberation Mono:style=Regular' \
    'Noto Sans Mono:style=Regular')" || MENU_FONT=""

TITLE_PAD=2
if [ "$SHADOW_ON" = on ]; then
    TITLE_PAD="$(awk -v s="$SHADOW_SIGMA" -v o="$SHADOW_OFFSET" 'BEGIN { printf "%d", 3 * s + o + 1.5 }')"
fi
title_args=(-background none -fill "$FG_HEX" -density 72 -pointsize "$TITLE_PT"
            -interline-spacing "$(( -TITLE_PT / 5 ))" -gravity center)
if [ -n "$TITLE_FONT" ]; then title_args+=(-font "$TITLE_FONT"); fi
"${IM[@]}" "${title_args[@]}" label:'>_GRUB
BOOTMENU' -trim +repage -bordercolor none -border "$TITLE_PAD" "${PNG_OUT[@]}" "PNG32:$OUT/title.png"
with_shadow "$OUT/title.png"
TITLE_W="$(im_identify -format '%w' "$OUT/title.png")"
TITLE_H="$(im_identify -format '%h' "$OUT/title.png")"

# ---- plain pieces: border line, selection box of the fallback menu -------------
# GRUB never draws an image component smaller than the image itself, so the
# border line is a BORDER_W x BORDER_W square stretched along each edge.
"${IM[@]}" -size "${BORDER_W}x${BORDER_W}" "xc:$FG_HEX" "${PNG_OUT[@]}" "PNG32:$OUT/line.png"
# Rounded corners: a quarter ring BORDER_RADIUS px square, outer edge on the
# frame line. Drawn 8x larger (pixel centres tested against the ring) and
# reduced by averaging, like the icons; mirrored for the other corners.
ss=8; S=$(( BORDER_RADIUS * ss )); RIN=$(( (BORDER_RADIUS - BORDER_W) * ss ))
"${IM[@]}" -size "${BORDER_RADIUS}x${BORDER_RADIUS}" "xc:$FG_HEX" \
    \( -size "${S}x${S}" xc:black -fx "hypot($S-i-0.5, $S-j-0.5) >= $RIN && hypot($S-i-0.5, $S-j-0.5) <= $S" \
       -scale "${BORDER_RADIUS}x${BORDER_RADIUS}!" \) \
    -alpha off -compose CopyOpacity -composite "${PNG_OUT[@]}" "PNG32:$OUT/corner_nw.png"
"${IM[@]}" "$OUT/corner_nw.png" -flop "${PNG_OUT[@]}" "PNG32:$OUT/corner_ne.png"
"${IM[@]}" "$OUT/corner_nw.png" -flip "${PNG_OUT[@]}" "PNG32:$OUT/corner_sw.png"
"${IM[@]}" "$OUT/corner_nw.png" -flip -flop "${PNG_OUT[@]}" "PNG32:$OUT/corner_se.png"
for s in nw n ne w c e sw s se; do
    "${IM[@]}" -size "${SEL_PAD}x${SEL_PAD}" "xc:$FG_HEX" "${PNG_OUT[@]}" "PNG32:$OUT/select_$s.png"
done

# ---- GRUB fonts (PF2) --------------------------------------------------------------
FONT_NAME_ITEM="Unknown Regular 16"
FONT_NAME_SMALL="Unknown Regular 16"
if [ -n "$MENU_FONT" ]; then
    for size in "$FONT_ITEM" "$FONT_SMALL"; do
        grub-mkfont -n "GIM Mono" -s "$size" -r 0x20-0x7E,0xA0-0x17F \
            -o "$OUT/gim-mono-$size.pf2" "$MENU_FONT" >/dev/null
    done
    FONT_NAME_ITEM="GIM Mono Regular $FONT_ITEM"
    FONT_NAME_SMALL="GIM Mono Regular $FONT_SMALL"
else
    log_warn "no monospace TTF found; GRUB's built-in font will be used for text"
fi

# ---- theme files -------------------------------------------------------------------
GRUB_VER="$(grub_version)"
grub_at_least() { [ "$(printf '%s\n' "$1" "${GRUB_VER:-0}" | sort -V | head -n1)" = "$1" ]; }
desktop_lines() {
    printf 'desktop-color: "%s"\n' "$DESKTOP_HEX"
    if [ -n "$BACKGROUND" ]; then
        # background.png already has the screen size; if GRUB runs another
        # mode, GRUB 2.06+ fills the screen without distorting it.
        printf 'desktop-image: "background.png"\n'
        if grub_at_least 2.06; then
            printf 'desktop-image-scale-method: "crop"\ndesktop-image-h-align: "center"\ndesktop-image-v-align: "center"\n'
        fi
    fi
    printf 'terminal-font: "%s"\nterminal-border: "0"\n' "$FONT_NAME_SMALL"
    # Full-screen text area: the command line (c), the editor (e) and the
    # screen shown while the chosen entry loads (the hook redraws the
    # background there) cover the whole screen instead of a box in the middle.
    if grub_at_least 2.02; then
        printf 'terminal-left: "0"\nterminal-top: "0"\nterminal-width: "100%%"\nterminal-height: "100%%"\n'
    fi
}
border_components() {
    local i="$BORDER_INSET" b="$BORDER_W" r="$BORDER_RADIUS" e=$(( BORDER_INSET + BORDER_RADIUS ))
    cat <<EOF
# thin frame with rounded corners
+ image { left = $e  top = $i  width = 100%-$((2 * e))  height = $b  file = "line.png" }
+ image { left = $e  top = 100%-$((i + b))  width = 100%-$((2 * e))  height = $b  file = "line.png" }
+ image { left = $i  top = $e  width = $b  height = 100%-$((2 * e))  file = "line.png" }
+ image { left = 100%-$((i + b))  top = $e  width = $b  height = 100%-$((2 * e))  file = "line.png" }
+ image { left = $i  top = $i  width = $r  height = $r  file = "corner_nw.png" }
+ image { left = 100%-$e  top = $i  width = $r  height = $r  file = "corner_ne.png" }
+ image { left = $i  top = 100%-$e  width = $r  height = $r  file = "corner_sw.png" }
+ image { left = 100%-$e  top = 100%-$e  width = $r  height = $r  file = "corner_se.png" }
EOF
}
title_component() {
    [ "$TITLE" = yes ] || return 0
    cat <<EOF
# ">_GRUB / BOOTMENU"
+ image { left = 50%-$((TITLE_W / 2))  top = 5%-$((TITLE_PAD - 2))  width = $TITLE_W  height = $TITLE_H  file = "title.png" }
EOF
}

cat >"$OUT/icon-menu.txt" <<EOF
# grub-icon-menu $GIM_VERSION - icon chooser theme
# Generated for ${SCREEN_W}x${SCREEN_H} by scripts/generate-assets.sh - do not edit,
# re-run update.sh instead.
#
# The menu shows exactly one row: the selected entry. Its icon (from icons/,
# chosen by the entry's --class) pictures all icons with the arrow under the
# selected one. GRUB draws a single row because item_height + item_spacing
# is 0 (gui_list.c: get_num_shown_items). GRUB draws the entry title right
# of the icon even outside the component; item_icon_space moves it far off
# the screen, so it never shows on any background.

title-text: ""
$(desktop_lines)

$(border_components)

$(title_component)

+ boot_menu {
    left = 50%-$((COMP_W / 2))
    top = 50%-$COMP_TOP_OFF
    width = $COMP_W
    height = $COMP_H
    item_height = $COMP_H
    icon_width = $COMP_W
    icon_height = $COMP_H
    item_icon_space = $((SCREEN_W * 4))
    item_padding = 0
    item_spacing = -$COMP_H
    item_font = "$FONT_NAME_SMALL"
    item_color = "$DESKTOP_HEX"
    selected_item_color = "$DESKTOP_HEX"
    scrollbar = false
}
EOF

cat >"$OUT/theme.txt" <<EOF
# grub-icon-menu $GIM_VERSION - full standard menu (reached with ESC from the
# icon chooser, or used alone if the chooser is disabled).
# Generated for ${SCREEN_W}x${SCREEN_H} by scripts/generate-assets.sh.

title-text: ""
$(desktop_lines)

$(border_components)

$(title_component)

+ boot_menu {
    left = 20%
    top = 24%
    width = 60%
    height = 58%
    item_font = "$FONT_NAME_ITEM"
    item_color = "$FG_HEX"
    selected_item_color = "$INV_HEX"
    selected_item_pixmap_style = "select_*.png"
    item_height = $ITEM_H
    item_padding = 0
    item_spacing = $ITEM_SPACING
    icon_width = 1
    icon_height = 1
    item_icon_space = $ICON_TEXT_GAP
    scrollbar = false
}

+ label {
    id = "__timeout__"
    left = 0
    top = 85%
    width = 100%
    height = $((FONT_SMALL * 2))
    align = "center"
    color = "$FG_HEX"
    font = "$FONT_NAME_SMALL"
    text = "Booting the selected entry in %d s"
}

+ label {
    left = 0
    top = 100%-$((BORDER_INSET + FONT_SMALL * 3))
    width = 100%
    height = $((FONT_SMALL * 2))
    align = "center"
    color = "$DIM_HEX"
    font = "$FONT_NAME_SMALL"
    text = "Enter: boot    e: edit    c: command line"
}
EOF

cp -f -- "$SRC/chooser.cfg" "$OUT/chooser.cfg"

cat >"$OUT/$GIM_MARKER" <<EOF
# grub-icon-menu theme directory (created by grub-icon-menu; safe to delete
# together with this directory after removing /etc/grub.d/99_grub_icon_menu)
VERSION=$GIM_VERSION
RESOLUTION=${SCREEN_W}x${SCREEN_H}
ORDER=$ORDER
TITLE=$TITLE
LAYOUTS=${LAYOUTS[*]}
BACKGROUND=$BG_SHA
ICON_COLOR=$ICON_COLOR
SHADOW=$SHADOW
FOREGROUND=$FG
CONSOLE_FG=$CONSOLE_FG
GENERATED=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF

# ---- self-check ---------------------------------------------------------------------
fail=0
for layout in "${LAYOUTS[@]}"; do
    n=$(( $(printf '%s' "$layout" | tr -cd '-' | wc -c) + 1 ))
    for (( sel = 0; sel < n; sel++ )); do
        png_ok "$OUT/icons/gim-$layout-$sel.png" "$COMP_W" "$COMP_H" \
            || { log_error "bad icon: icons/gim-$layout-$sel.png"; fail=1; }
    done
done
for f in title.png line.png corner_nw.png corner_ne.png corner_sw.png corner_se.png select_c.png; do
    png_ok "$OUT/$f" || { log_error "bad PNG: $f"; fail=1; }
done
if [ -n "$BACKGROUND" ]; then
    case "$(file -b "$OUT/background.png")" in
        "PNG image data, $SCREEN_W x $SCREEN_H, 8-bit/color RGB, non-interlaced") ;;
        *) log_error "bad background.png: $(file -b "$OUT/background.png")"; fail=1 ;;
    esac
fi
[ "$fail" = 0 ] || die "asset generation failed"

log_info "Theme generated: ${#LAYOUTS[@]} layouts (${LAYOUTS[*]}), composite ${COMP_W}x${COMP_H}"
