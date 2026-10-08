#!/bin/bash
#
# tests/qemu-scenarios.sh - behaviour of the chooser in REAL GRUB (QEMU/OVMF).
#
#   QEMU_ROOT=/path/to/extracted/qemu tests/qemu-scenarios.sh [OUTDIR]
#
# Every scenario boots GRUB, drives it with keys and asserts which standard
# menu entry was finally executed (reported on the serial port by the test
# harness, see tests/qemu-test.sh). Screenshots are kept in OUTDIR.
#
# The Windows icon works like on the laptop: firmware mode, fake UEFI boot
# entries (Windows Boot Manager = Boot0001) and a dummy handoff.img, so it
# boots the handoff entry gim-windows-handoff.

set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
P="$(cd -- "$HERE/.." && pwd)"
OUT="${1:-$(mktemp -d "${TMPDIR:-/tmp}/gim-qemu-scenarios.XXXXXX")}"
mkdir -p "$OUT"
FX="$HERE/fixtures"
R=8c6f1b2e-3d4a-4f5b-9c6d-7e8f9a0b1c2d
LINUX="gnulinux-simple-$R"
WINDOWS="gim-windows-handoff"           # the Windows icon (firmware handoff)
CHAIN="osprober-efi-63A4-7C42"          # os-prober's chainload entry (fixtures only)
IM=magick; command -v magick >/dev/null 2>&1 || IM=convert

GUID=8be4df61-93ca-11d2-aa0d-00e098032b8c
u16() { printf '%s' "$1" | iconv -f UTF-8 -t UTF-16LE; }
bootvar() {
    { printf '\007\000\000\000\001\000\000\000\074\000'; u16 "$3"; printf '\000\000\004\004\100\000'
      u16 "$4"; printf '\000\000\177\377\004\000'; } >"$1/Boot$2-$GUID"
}
mkdir -p "$OUT/efivars"
bootvar "$OUT/efivars" 0000 Ubuntu '\EFI\ubuntu\shimx64.efi'
bootvar "$OUT/efivars" 0001 "Windows Boot Manager" '\EFI\Microsoft\Boot\bootmgfw.efi'
ENV="GIM_EFIVARS=$OUT/efivars GIM_TEST_HANDOFF_KERNEL=/vmlinuz-7.0.0-38-generic"
# Four systems: + Kali with its own UEFI entry (Boot0003), + Linux Mint found
# by os-prober (fixture ubuntu-mint.cfg, GRUB_ICON_MENU_FOREIGN_LINUX=true).
mkdir -p "$OUT/efivars-multi"
cp "$OUT"/efivars/Boot000[01]-* "$OUT/efivars-multi/"
bootvar "$OUT/efivars-multi" 0003 kali '\EFI\kali\shimx64.efi'
MENV="GIM_EFIVARS=$OUT/efivars-multi GIM_TEST_HANDOFF_KERNEL=/vmlinuz-7.0.0-38-generic"

theme() {   # theme NAME RESOLUTION [generate-assets options]
    local d="$OUT/theme-$1" res="$2"; shift 2
    [ -d "$d" ] || "$P/scripts/generate-assets.sh" --resolution "$res" --out "$d" "$@" >/dev/null 2>&1
    echo dummy >"$d/handoff.img"
}
"$IM" -size 1920x1080 gradient:'#0b1320-#30203a' "$OUT/dark.png"
theme 1920x1080 1920x1080
theme 1280x720 1280x720
theme 2560x1440 2560x1440
theme dark 1920x1080 --background "$OUT/dark.png"
theme multi 1920x1080 --order "windows linux kali linuxmint"

PASS=0; FAIL=0
scenario() {   # scenario NAME EXPECTED_CHOSEN|none [qemu-test options] -- ACTIONS
    local name="$1" expect="$2"; shift 2
    local dir="$OUT/$name" got
    rm -rf "$dir"
    if ! "$HERE/qemu-test.sh" --out "$dir" --hook-env "${SCENARIO_ENV:-$ENV}" "$@" >"$dir.log" 2>&1; then
        FAIL=$((FAIL + 1)); printf '  FAIL  %-34s (harness error, see %s.log)\n' "$name" "$dir"; return
    fi
    # GRUB's serial console wraps at 80 columns (a wrap may replace the space
    # before "default="): join the lines, then cut at "default=".
    got=""
    if tr -d '\r\n' <"$dir/serial.log" | grep -aq 'GIMTEST-BOOTED *chosen='; then
        got="$(tr -d '\r\n' <"$dir/serial.log" | sed 's/.*GIMTEST-BOOTED *chosen=//; s/ *default=.*//')"
    fi
    if [ "$expect" = none ]; then
        if [ -z "$got" ]; then PASS=$((PASS + 1)); printf '  ok    %-34s nothing booted\n' "$name"
        else FAIL=$((FAIL + 1)); printf '  FAIL  %-34s booted %s\n' "$name" "$got"; fi
    elif [ "$got" = "$expect" ]; then
        PASS=$((PASS + 1)); printf '  ok    %-34s booted %s\n' "$name" "$got"
    else
        FAIL=$((FAIL + 1)); printf '  FAIL  %-34s expected %s, got %s\n' "$name" "$expect" "${got:-nothing}"
    fi
}
# like_background NAME SHOT THEME: while the chosen entry loads, the screen
# is the theme's picture (apart from the harness's line of text at the top).
like_background() {
    local d
    d="$("$IM" "$OUT/$1/$2.png" -crop 1920x980+0+100 +repage \
        \( "$OUT/theme-$3/background.png" -crop 1920x980+0+100 +repage \) \
        -metric RMSE -compare -format '%[distortion]' info: 2>/dev/null || echo 1)"
    if awk -v d="$d" 'BEGIN { exit !(d < 0.03) }'; then
        PASS=$((PASS + 1)); printf '  ok    %-34s screen = background picture (RMSE %.4f)\n' "$1/$2" "$d"
    else
        FAIL=$((FAIL + 1)); printf '  FAIL  %-34s screen differs from the picture (RMSE %s)\n' "$1/$2" "$d"
    fi
}
T="--theme $OUT/theme-1920x1080"
WU="--fixture $FX/windows-ubuntu.cfg"
UO="--fixture $FX/ubuntu-only.cfg"

echo "== real GRUB scenarios (screenshots: $OUT)"
# shellcheck disable=SC2086
{
scenario enter-default-linux      "$LINUX"   $UO $T -- wait:12 shot:chooser ret wait:5
scenario up-enter-windows         "$WINDOWS" $UO $T -- wait:12 up wait:1 shot:windows-selected ret wait:5
scenario right-key-boots-selected "$LINUX"   $UO $T -- wait:12 right wait:5
scenario timeout-boots-default    "$LINUX"   $UO $T --timeout 2 -- wait:16
scenario default-windows-index    "$WINDOWS" $WU $T --timeout 2 --default 4 -- wait:6 shot:preselected-windows wait:10
scenario pinned-old-kernel        "gnulinux-advanced-$R>gnulinux-7.0.0-34-generic-advanced-$R" $UO $T \
         --default "gnulinux-advanced-$R>gnulinux-7.0.0-34-generic-advanced-$R" -- wait:12 shot:pinned ret wait:5
scenario one-time-boot-skips-menu "$CHAIN"   $WU $T --extra "set default=\"$CHAIN\"; set boot_once=true" -- wait:12
scenario recordfail-longer-wait   none       $UO $T --timeout 2 --extra "set recordfail=1" -- wait:16 shot:recordfail-still-waiting
scenario esc-full-menu-enter      "$LINUX"   $UO $T -- wait:12 esc wait:2 shot:full-menu ret wait:5
scenario console-key-c            none       $UO $T -- wait:12 c wait:2 shot:console
scenario windows-only             "$WINDOWS" --fixture "$FX/windows-only.cfg" $T -- wait:12 shot:windows-only ret wait:5
scenario res-1280x720             "$LINUX"   $UO --theme "$OUT/theme-1280x720" --resolution 1280x720 -- wait:12 shot:chooser ret wait:5
scenario res-2560x1440            "$LINUX"   $UO --theme "$OUT/theme-2560x1440" --resolution 2560x1440 -- wait:12 shot:chooser ret wait:5
scenario theme-1080-on-1366x768   "$LINUX"   $UO $T --resolution 1366x768 -- wait:12 shot:chooser ret wait:5
# background picture
scenario bg-enter-linux           "$LINUX"   $UO --theme "$OUT/theme-dark" -- wait:12 shot:chooser ret wait:4 shot:loading
like_background bg-enter-linux loading dark
scenario bg-up-enter-windows      "$WINDOWS" $UO --theme "$OUT/theme-dark" -- wait:12 up wait:1 ret wait:4 shot:loading
like_background bg-up-enter-windows loading dark
scenario bg-esc-full-menu         "$LINUX"   $UO --theme "$OUT/theme-dark" -- wait:12 esc wait:2 shot:full-menu ret wait:5
# plain menu (GRUB_ICON_MENU=false): Ubuntu hides its menu (timeout 0); the
# Windows entry must still be reachable, and Ubuntu still boots by default
scenario plain-menu-windows       "$WINDOWS" $UO $T --setting GRUB_ICON_MENU=false -- \
         wait:12 shot:plain down wait:1 down wait:1 down wait:1 down wait:1 down wait:1 shot:plain-windows ret wait:5
scenario plain-menu-timeout       "$LINUX"   $UO $T --setting GRUB_ICON_MENU=false --timeout 2 -- wait:16
# four systems: Windows, Ubuntu (Tux, preselected), Kali, Linux Mint
M="--fixture $FX/ubuntu-mint.cfg --theme $OUT/theme-multi --setting GRUB_ICON_MENU_FOREIGN_LINUX=true"
SCENARIO_ENV="$MENV"
scenario multi-enter-ubuntu       "$LINUX"   $M -- wait:12 shot:multi ret wait:5
scenario multi-down-kali          "gim-kali-handoff" $M -- wait:12 down wait:1 shot:kali-selected ret wait:5
scenario multi-down-down-mint     "osprober-gnulinux-simple-6666" $M -- wait:12 down wait:1 down wait:1 shot:mint-selected ret wait:5
scenario multi-wraps-to-windows   "$WINDOWS" $M -- wait:12 down wait:1 down wait:1 down wait:1 shot:wrapped ret wait:5
scenario multi-up-windows         "$WINDOWS" $M -- wait:12 up wait:1 ret wait:5
unset SCENARIO_ENV
}

echo
echo "QEMU scenarios: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
