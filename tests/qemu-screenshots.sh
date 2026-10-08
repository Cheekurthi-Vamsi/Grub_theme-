#!/bin/bash
#
# tests/qemu-screenshots.sh - make the README screenshots (docs/*.png) with
# REAL GRUB in QEMU/OVMF (see tests/qemu-test.sh).
#
#   QEMU_ROOT=/path/to/extracted/qemu tests/qemu-screenshots.sh [WORKDIR]
#
# The menu is the one this laptop gets: Ubuntu entries, no os-prober entry,
# the Windows icon through the firmware handoff (fake UEFI boot entries with
# Windows Boot Manager = Boot0001, dummy handoff.img). Screens are taken at
# 1920x1080 and saved at 960x540; docs/sharpness.png shows the icons 1:1 and
# enlarged 3x without smoothing. Screens 12 and 13 add Kali (own UEFI entry)
# and Linux Mint (os-prober, fixture ubuntu-mint.cfg); docs/os-icons.png shows
# every icon in icons/png/.
#
# Backgrounds: "Red Acer" by mendhak (Ubuntu wallpaper, CC BY-SA 4.0, package
# ubuntu-wallpapers-resolute) and a light paper gradient made here.

set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
P="$(cd -- "$HERE/.." && pwd)"
W="${1:-$(mktemp -d "${TMPDIR:-/tmp}/gim-shots.XXXXXX")}"
DOCS="$P/docs"
FX="$P/tests/fixtures/ubuntu-only.cfg"
DARK=/usr/share/backgrounds/mendhak-Red_Acer.jpg
LIGHT="$W/light-paper.png"
IM=magick; command -v magick >/dev/null 2>&1 || IM=convert
mkdir -p "$W" "$DOCS"
[ -f "$DARK" ] || { echo "missing $DARK (package ubuntu-wallpapers-resolute)" >&2; exit 1; }
"$IM" -size 2560x1440 radial-gradient:'#fffdf8-#ddd5c8' -attenuate 0.3 +noise Gaussian -blur 0x0.8 "$LIGHT"

# Fake UEFI boot entries: Ubuntu, Windows Boot Manager (Boot0001).
GUID=8be4df61-93ca-11d2-aa0d-00e098032b8c
u16() { printf '%s' "$1" | iconv -f UTF-8 -t UTF-16LE; }
bootvar() {
    { printf '\007\000\000\000\001\000\000\000\074\000'; u16 "$3"; printf '\000\000\004\004\100\000'
      u16 "$4"; printf '\000\000\177\377\004\000'; } >"$1/Boot$2-$GUID"
}
mkdir -p "$W/efivars"
bootvar "$W/efivars" 0000 Ubuntu '\EFI\ubuntu\shimx64.efi'
bootvar "$W/efivars" 0001 "Windows Boot Manager" '\EFI\Microsoft\Boot\bootmgfw.efi'
HOOK_ENV="GIM_EFIVARS=$W/efivars GIM_TEST_HANDOFF_KERNEL=/vmlinuz-7.0.0-38-generic"
mkdir -p "$W/efivars-multi"
cp "$W"/efivars/Boot000[01]-* "$W/efivars-multi/"
bootvar "$W/efivars-multi" 0003 kali '\EFI\kali\shimx64.efi'
MULTI_ENV="GIM_EFIVARS=$W/efivars-multi GIM_TEST_HANDOFF_KERNEL=/vmlinuz-7.0.0-38-generic"

theme() {   # theme NAME [generate-assets options]
    local name="$1"; shift
    rm -rf "$W/theme-$name"
    "$P/scripts/generate-assets.sh" --resolution 1920x1080 --out "$W/theme-$name" "$@" >/dev/null 2>&1
    echo dummy >"$W/theme-$name/handoff.img"
}
shots() {   # shots THEME OUTNAME [qemu-test options] -- ACTIONS
    local t="$1" n="$2"; shift 2
    rm -rf "$W/run-$n"
    "$HERE/qemu-test.sh" --fixture "${SHOT_FX:-$FX}" --theme "$W/theme-$t" --out "$W/run-$n" \
        --hook-env "${SHOT_ENV:-$HOOK_ENV}" --timeout 60 "$@" >"$W/run-$n.log" 2>&1
}
save() {    # save RUN SHOT DOCNAME
    "$IM" "$W/run-$1/$2.png" -filter Lanczos -resize 960x540 -strip "$DOCS/$3.png"
    echo "  docs/$3.png"
}

echo "== themes"
theme white
theme notitle --no-title
theme dark --background "$DARK"
theme light --background "$LIGHT"
theme multi --order "windows linux kali linuxmint"
theme multidark --order "windows linux kali linuxmint" --background "$DARK"

echo "== screens (real GRUB)"
shots white keys -- wait:12 shot:default down wait:1 shot:down1 down wait:1 shot:down2 up wait:1 shot:up esc wait:2 shot:full
save keys default 1-default-ubuntu
save keys down1 2-down-windows
save keys down2 3-down-ubuntu-again
save keys up 4-up-windows
save keys full 5-esc-full-menu
shots notitle rt -- wait:12 shot:chooser
save rt chooser 6-no-title-rt
shots dark dark -- wait:12 shot:chooser up wait:1 shot:windows esc wait:2 shot:full
save dark chooser 7-background-dark
save dark windows 8-background-dark-windows
save dark full 9-background-full-menu
shots light light -- wait:12 shot:chooser
save light chooser 10-background-light
shots white plain --setting GRUB_ICON_MENU=false -- wait:12 shot:menu
save plain menu 11-plain-menu
SHOT_FX="$P/tests/fixtures/ubuntu-mint.cfg" SHOT_ENV="$MULTI_ENV"
shots multi multi --setting GRUB_ICON_MENU_FOREIGN_LINUX=true -- wait:12 shot:chooser esc wait:2 shot:full
save multi chooser 12-four-systems
save multi full 14-four-systems-full-menu
shots multidark multidark --setting GRUB_ICON_MENU_FOREIGN_LINUX=true -- wait:12 down wait:1 shot:kali
save multidark kali 13-four-systems-dark
unset SHOT_FX SHOT_ENV

echo "== sharpness (1:1 and 3x, no smoothing)"
crop=420x220+750+440
"$IM" \( "$W/run-keys/default.png" -crop "$crop" +repage \) \( "$W/run-dark/chooser.png" -crop "$crop" +repage \) \
      \( "$W/run-light/chooser.png" -crop "$crop" +repage \) +append "$W/sharp-1x.png"
"$IM" "$W/sharp-1x.png" -filter point -resize 300% "$W/sharp-3x.png"
"$IM" "$W/sharp-3x.png" -strip "$DOCS/sharpness.png"
echo "  docs/sharpness.png"

echo "== every icon in icons/png (black masters, as on a light screen)"
rm -rf "$W/icons-sheet"; mkdir -p "$W/icons-sheet"
for f in "$P"/icons/png/*.png; do
    k="$(basename "$f" .png)"
    "$IM" "$f" -filter Lanczos -resize 64x64 -background none -gravity center -extent 120x80 \
        -gravity south -splice 0x22 -background white -flatten -font DejaVu-Sans -pointsize 13 \
        -fill '#333333' -annotate +0+3 "$k" "$W/icons-sheet/$k.png"
done
"$IM" montage "$W"/icons-sheet/*.png -tile 10x -geometry +6+6 -background white -strip "$DOCS/os-icons.png"
echo "  docs/os-icons.png"

echo "== contact sheet"
"$IM" \( "$DOCS/1-default-ubuntu.png" "$DOCS/2-down-windows.png" +append \) \
      \( "$DOCS/7-background-dark.png" "$DOCS/10-background-light.png" +append \) \
      \( "$DOCS/5-esc-full-menu.png" "$DOCS/9-background-full-menu.png" +append \) \
      -append -resize 50% -strip "$DOCS/all-screens.png"
echo "  docs/all-screens.png"

echo "== boot checks"
for r in keys dark light plain; do
    printf '  %-6s %s\n' "$r" "$(tr -d '\r' <"$W/run-$r/serial.log" | grep -ao 'GIMTEST-BOOTED[^$]*' | head -n1 || echo 'no boot (as expected for screenshots)')"
done
