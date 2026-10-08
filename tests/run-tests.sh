#!/bin/bash
#
# tests/run-tests.sh - fast tests, no root, no VM.
#
#   tests/run-tests.sh
#
#  1. shell syntax of every script
#  2. detection on the fixtures (TEST 1-6 of the specification + BIOS)
#  3. hook output for every fixture: grub-script-check, no OS names in titles,
#     no chooser when nothing is supported
#  4. the grub-mkconfig mechanism (reading the menu from our own stdout file)
#     and the fallback (re-running the other /etc/grub.d scripts)
#  5. idempotence: same input -> byte-identical output
#  6. theme generation for 1280x720 ... 3840x2160 (sizes, PNG format, fit)
#  7. Windows through the firmware: handoff entry, BootNext number from the
#     UEFI boot entries, newest signed kernel, plain menu (GRUB_ICON_MENU=false),
#     handoff/init (busybox, fake efivars), handoff.img
#  8. look: background picture, automatic icon colour, shadow, sharp edges,
#     entry titles off the screen
#  9. doctor.sh: boot order and BootNext warnings (fake efibootmgr)
# 10. other systems: names, UEFI boot entries (Kali, Fedora, ...), os-prober
#     entries (Linux Mint, Arch), icons for them, handoff/init with gim.match
#
# Slower, more complete tests: tests/sandbox-test.sh (real update-grub and
# install/update/uninstall/restore) and tests/qemu-scenarios.sh (real GRUB).

set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
P="$(cd -- "$HERE/.." && pwd)"
FX="$HERE/fixtures"
W="$(mktemp -d)"
trap 'rm -rf -- "$W"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok    %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$*"; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

# Run the hook exactly like grub-mkconfig would, on a fixture (test mode:
# no disk lookups). Extra VAR=VALUE arguments are passed to the hook.
# Sections 3-5 test the menu logic with the chainload Windows icon; section 7
# tests the firmware handoff (the default).
mkdir -p "$W/etc/default/grub.d"
printf 'GRUB_ICON_MENU_THEME_DIR=%s\nGRUB_ICON_MENU_WINDOWS_BOOT=chainload\n' "$W/theme" >"$W/etc/default/grub.d/99-grub-icon-menu.cfg"
hook() {
    local fixture="$1"; shift
    env GIM_INPUT_CFG="$fixture" GIM_SYSCONFDIR="$W/etc" GIM_PLATFORM=efi GIM_CPU=x86_64 \
        GIM_TEST_DEVICE_PREP="" GIM_TEST_THEME_REL=/grub/themes/grub-icon-menu "$@" \
        "$P/grub.d/99_grub_icon_menu" 2>/dev/null
}
field() { "$P/detect-os.sh" --cfg "$1" --platform "${3:-efi}" | sed -n "s/^$2=//p"; }

echo "== 1. shell syntax"
for f in "$P"/*.sh "$P"/lib/*.sh "$P"/scripts/*.sh "$P"/tests/*.sh "$P"/grub.d/99_grub_icon_menu; do
    check "bash -n ${f#"$P"/}" bash -n "$f"
done
if [ -x /bin/busybox ]; then check "busybox sh -n handoff/init" /bin/busybox sh -n "$P/handoff/init"; fi
if command -v shellcheck >/dev/null 2>&1; then
    check "shellcheck" shellcheck -S warning "$P"/*.sh "$P"/lib/*.sh "$P"/scripts/*.sh "$P"/grub.d/99_grub_icon_menu
fi

echo "== 2. detection"
expect() {   # expect FIXTURE LAYOUT [WINDOWS_TARGET] [LINUX_TARGET_PREFIX]
    local f="$FX/$1.cfg"
    check "$1: layout '${2:-none}'" [ "$(field "$f" LAYOUT)" = "$2" ]
    if [ -n "${3:-}" ]; then check "$1: Windows target $3" [ "$(field "$f" TARGET_WINDOWS)" = "$3" ]; fi
    if [ -n "${4:-}" ]; then
        local t; t="$(field "$f" TARGET_LINUX)"
        check "$1: Linux target ${4}*" bash -c '[[ "$1" == "$2"* ]]' _ "$t" "$4"
    fi
}
expect windows-ubuntu        windows-linux osprober-efi-63A4-7C42 gnulinux-simple-   # TEST 1
expect ubuntu-only           linux         ""                     gnulinux-simple-   # TEST 2
expect windows-only          windows       osprober-efi-63A4-7C42                    # TEST 3
expect unknown-only          ""                                                       # TEST 4
expect ubuntu-unknown        linux         ""                     gnulinux-simple-   # TEST 4b
expect multi-kernel-flat     linux         ""                     gnulinux-7.0.0-40-generic-advanced-  # TEST 5
expect windows-multi-kernels windows-linux osprober-efi-63A4-7C42 gnulinux-simple-   # TEST 6
check "TEST 5: five kernels grouped into one icon" [ "$(field "$FX/multi-kernel-flat.cfg" ENTRIES_LINUX)" = 5 ]
check "TEST 6: two Windows entries grouped into one icon" [ "$(field "$FX/windows-multi-kernels.cfg" ENTRIES_WINDOWS)" = 2 ]
check "foreign Linux from os-prober is not grouped with Ubuntu" [ "$(field "$FX/ubuntu-unknown.cfg" ENTRIES_LINUX)" = 5 ]
check "BIOS: chainloader entry counts on pc, EFI entry does not" \
    [ "$(field "$FX/unknown-only.cfg" WINDOWS pc)" = 1 ] && [ "$(field "$FX/windows-only.cfg" WINDOWS pc)" = 0 ]
check "numeric index of Windows accounts for platform-conditional memtest" \
    bash -c "GIM_HOOK_LIB=1; . '$P/grub.d/99_grub_icon_menu'; GIM_PLATFORM=efi GIM_CPU=x86_64; GIM_ORDER='windows linux'; GIM_FOREIGN_LINUX=false; gim_classify <<<\"\$(gim_parse <'$FX/windows-ubuntu.cfg')\"; printf '%s' \"\$GIM_HEADS_windows\" | head -n1 | grep -qx 4"

echo "== 3. hook output"
"$P/scripts/generate-assets.sh" --resolution 1920x1080 --out "$W/theme" >/dev/null 2>&1
for f in "$FX"/*.cfg; do
    n="$(basename "$f" .cfg)"
    { cat "$f"; echo "### BEGIN /etc/grub.d/99_grub_icon_menu ###"; hook "$f"; echo "### END /etc/grub.d/99_grub_icon_menu ###"; } >"$W/$n.full.cfg"
    check "$n: grub-script-check" grub-script-check "$W/$n.full.cfg"
    titles="$(sed -n '/^function gim_entries/,/^}/p' "$W/$n.full.cfg" | sed -n "s/^ *menuentry '\([^']*\)'.*/\1/p")"
    check "$n: chooser titles contain no OS name" bash -c '! printf "%s" "$1" | grep -qi "windows\|ubuntu\|linux"' _ "$titles"
done
check "unknown-only: no chooser emitted" bash -c "! grep -q gim_entries '$W/unknown-only.full.cfg'"
check "windows-ubuntu: Tux preselected for GRUB_DEFAULT=0" grep -q "if \[ \"\${gim_def}\" = '0' \]; then set gim_kind=linux; fi" "$W/windows-ubuntu.full.cfg"
check "GRUB_ICON_MENU=false disables the chooser" bash -c "
    printf 'GRUB_ICON_MENU=false\n' >'$W/etc/default/grub.d/zz.cfg'
    out=\$(GIM_INPUT_CFG='$FX/windows-ubuntu.cfg' GIM_SYSCONFDIR='$W/etc' GIM_TEST_DEVICE_PREP='' '$P/grub.d/99_grub_icon_menu' 2>/dev/null)
    rm -f '$W/etc/default/grub.d/zz.cfg'
    printf '%s' \"\$out\" | grep -q 'disabled' && ! printf '%s' \"\$out\" | grep -q gim_entries"
check "missing theme: no chooser, standard menu kept" bash -c "
    printf 'GRUB_ICON_MENU_THEME_DIR=/nonexistent\n' >'$W/etc/default/grub.d/zz.cfg'
    out=\$(GIM_INPUT_CFG='$FX/windows-ubuntu.cfg' GIM_SYSCONFDIR='$W/etc' GIM_TEST_DEVICE_PREP='' '$P/grub.d/99_grub_icon_menu' 2>/dev/null)
    rm -f '$W/etc/default/grub.d/zz.cfg'
    ! printf '%s' \"\$out\" | grep -q gim_entries"
check "hook never fails update-grub (broken config file)" bash -c "
    printf 'GRUB_ICON_MENU_TIMEOUT=abc\n' >'$W/etc/default/grub.d/zz.cfg'
    GIM_INPUT_CFG='$FX/windows-ubuntu.cfg' GIM_SYSCONFDIR='$W/etc' GIM_TEST_DEVICE_PREP='' '$P/grub.d/99_grub_icon_menu' >/dev/null 2>&1; rc=\$?
    rm -f '$W/etc/default/grub.d/zz.cfg'; [ \$rc = 0 ]"

echo "== 4. grub-mkconfig mechanism"
# (a) stdout is grub.cfg.new: the hook reads what was written before it.
(
    exec >"$W/mk.cfg.new"
    cat "$FX/windows-ubuntu.cfg"
    echo "### BEGIN /etc/grub.d/99_grub_icon_menu ###"
    GIM_SYSCONFDIR="$W/etc" GIM_PLATFORM=efi GIM_CPU=x86_64 GIM_TEST_DEVICE_PREP="" \
        GIM_TEST_THEME_REL=/grub/themes/grub-icon-menu "$P/grub.d/99_grub_icon_menu" 2>/dev/null
    echo "### END /etc/grub.d/99_grub_icon_menu ###"
)
check "reads the partial grub.cfg.new and emits the chooser" grep -q -- '--class gim-windows-linux-1' "$W/mk.cfg.new"
check "result passes grub-script-check" grub-script-check "$W/mk.cfg.new"
# (b) stdout is a pipe: the hook re-runs the sibling scripts instead.
mkdir -p "$W/grub.d"
awk -v d="$W/grub.d" '
    /^### BEGIN \/etc\/grub.d\// { n = $3; sub(/.*\//, "", n); f = d "/" n ".txt"; next }
    /^### END / { f = ""; next }
    f != "" { print > f }' "$FX/windows-ubuntu.cfg"
for t in "$W"/grub.d/*.txt; do
    s="${t%.txt}"; printf '#!/bin/sh\ncat "%s"\n' "$t" >"$s"; chmod +x "$s"   # .txt: not executable, skipped
done
cp "$P/grub.d/99_grub_icon_menu" "$W/grub.d/99_grub_icon_menu"
GIM_SYSCONFDIR="$W/etc" GIM_PLATFORM=efi GIM_CPU=x86_64 GIM_TEST_DEVICE_PREP="" \
    GIM_TEST_THEME_REL=/grub/themes/grub-icon-menu "$W/grub.d/99_grub_icon_menu" 2>/dev/null | cat >"$W/rescan.out"
check "fallback rescan finds the same entries" grep -q -- '--class gim-windows-linux-1' "$W/rescan.out"

echo "== 5. idempotence"
hook "$FX/windows-ubuntu.cfg" >"$W/a.out"; hook "$FX/windows-ubuntu.cfg" >"$W/b.out"
check "identical output on identical input" cmp -s "$W/a.out" "$W/b.out"

echo "== 6. theme generation"
for res in 1280x720 1366x768 1600x900 1920x1080 2560x1440 3840x2160; do
    out="$W/t-$res"
    if "$P/scripts/generate-assets.sh" --resolution "$res" --out "$out" >/dev/null 2>&1; then
        ok "$res: generated"
    else
        bad "$res: generation failed"; continue
    fi
    w="${res%x*}"; h="${res#*x}"
    read -r cw ch < <(identify -format '%w %h\n' "$out/icons/gim-windows-linux-0.png" 2>/dev/null || magick identify -format '%w %h\n' "$out/icons/gim-windows-linux-0.png")
    check "$res: icons fit on screen (${cw}x${ch})" [ "$cw" -lt "$w" ] && [ "$ch" -lt "$((h / 2))" ]
    check "$res: all 4 composites are 8-bit RGBA PNG" bash -c "file '$out'/icons/*.png | grep -c '8-bit/color RGBA, non-interlaced' | grep -qx 4"
    check "$res: theme references existing files" bash -c "cd '$out' && for f in \$(grep -ho 'file = \"[^\"]*\"' icon-menu.txt theme.txt | cut -d'\"' -f2 | sort -u); do [ -f \"\$f\" ] || exit 1; done"
    check "$res: fonts generated" bash -c "ls '$out'/gim-mono-*.pf2 >/dev/null"
    check "$res: one-row trick (item_spacing = -item_height)" bash -c "h=\$(sed -n 's/^ *item_height = //p' '$out/icon-menu.txt'); grep -q \"item_spacing = -\$h\$\" '$out/icon-menu.txt'"
done

echo "== 7. Windows through the firmware"
GUID=8be4df61-93ca-11d2-aa0d-00e098032b8c
# Synthetic UEFI load options: attributes, description and a device path
# whose file name is UTF-16 (enough for the Windows Boot Manager test).
u16() { printf '%s' "$1" | iconv -f UTF-8 -t UTF-16LE; }
bootvar() {   # bootvar DIR NUM DESCRIPTION [FILE]
    { printf '\007\000\000\000\001\000\000\000\074\000'; u16 "$3"; printf '\000\000\004\004\100\000'
      [ -n "${4:-}" ] && { u16 "$4"; printf '\000\000'; }; printf '\177\377\004\000'; } >"$1/Boot$2-$GUID"
}
mkdir -p "$W/efivars" "$W/efivars-nowin"
bootvar "$W/efivars" 0000 Ubuntu '\EFI\ubuntu\shimx64.efi'
bootvar "$W/efivars" 0002 "Internal Hard Disk"
bootvar "$W/efivars" 0003 "Windows Boot Manager" '\EFI\MICROSOFT\BOOT\BOOTMGFW.EFI'
cp "$W/efivars/Boot0000-$GUID" "$W/efivars/Boot0002-$GUID" "$W/efivars-nowin/"
echo dummy >"$W/theme/handoff.img"
mkdir -p "$W/fw/etc/default/grub.d"
printf 'GRUB_ICON_MENU_THEME_DIR=%s\n' "$W/theme" >"$W/fw/etc/default/grub.d/99-grub-icon-menu.cfg"
fwhook() {   # fwhook FIXTURE OUT [VAR=VALUE...]: firmware mode (default), full grub.cfg in OUT
    local fixture="$1" out="$2"; shift 2
    { cat "$fixture"; echo "### BEGIN /etc/grub.d/99_grub_icon_menu ###"
      hook "$fixture" GIM_SYSCONFDIR="$W/fw/etc" GIM_EFIVARS="$W/efivars" \
          GIM_TEST_HANDOFF_KERNEL=/vmlinuz-7.0.0-38-generic "$@"
      echo "### END /etc/grub.d/99_grub_icon_menu ###"; } >"$out"
}
fwfield() { "$P/detect-os.sh" --cfg "$1" --platform efi | sed -n "s/^$2=//p"; }

fwhook "$FX/windows-ubuntu.cfg" "$W/fw1.cfg"
check "firmware: grub-script-check" grub-script-check "$W/fw1.cfg"
check "firmware: handoff entry added" grep -q -- "--id gim-windows-handoff {" "$W/fw1.cfg"
check "firmware: BootNext number from the UEFI entries (Boot0003, any case)" \
    grep -q "^    linux '/vmlinuz-7.0.0-38-generic' gim.bootnext=0003 quiet loglevel=0 panic=10 fbcon=font:TER16x32$" "$W/fw1.cfg"
check "firmware: handoff.img from the theme directory" grep -q '^  set gim_handoff="(${root})/grub/themes/grub-icon-menu/handoff.img"$' "$W/fw1.cfg"
check "firmware: Windows icon boots the handoff entry" grep -q "^    set gim_target_windows='gim-windows-handoff'$" "$W/fw1.cfg"
check "firmware: \$default never redirects the Windows icon to a chainload entry" \
    bash -c "! grep -q 'set gim_target_windows=\"\${gim_def}\"' '$W/fw1.cfg'"
check "firmware: a chainload default still preselects Windows" \
    grep -q "if \[ \"\${gim_def}\" = 'osprober-efi-63A4-7C42' \]; then set gim_kind=windows; fi" "$W/fw1.cfg"
check "firmware: detect-os reports the handoff" \
    [ "$(fwfield "$W/fw1.cfg" TARGET_WINDOWS)" = gim-windows-handoff ] && [ "$(fwfield "$W/fw1.cfg" WINDOWS_BOOT)" = firmware ]
fwhook "$FX/ubuntu-only.cfg" "$W/fw2.cfg"
check "firmware: Windows icon without any os-prober entry" [ "$(fwfield "$W/fw2.cfg" LAYOUT)" = windows-linux ]
check "firmware: grub-script-check (no os-prober entry)" grub-script-check "$W/fw2.cfg"
fwhook "$FX/windows-ubuntu.cfg" "$W/fw3.cfg" GIM_EFIVARS="$W/efivars-nowin"
check "firmware: no Windows Boot Manager entry -> no Windows icon (never chainload)" \
    bash -c "! grep -q 'gim_target_windows' '$W/fw3.cfg' && grep -q -- '--class gim-linux-0' '$W/fw3.cfg'"
check "firmware: detect-os follows the hook (WINDOWS=0)" [ "$(fwfield "$W/fw3.cfg" WINDOWS)" = 0 ]
rm "$W/theme/handoff.img"
fwhook "$FX/windows-ubuntu.cfg" "$W/fw4.cfg"
check "firmware: handoff.img missing -> no Windows icon" bash -c "! grep -q 'gim_target_windows' '$W/fw4.cfg'"
echo dummy >"$W/theme/handoff.img"
fwhook "$FX/windows-ubuntu.cfg" "$W/fw5.cfg" GIM_PLATFORM=pc GIM_CPU=i386
check "firmware: BIOS boot -> no Windows icon" bash -c "! grep -q 'gim-windows-handoff' '$W/fw5.cfg'"
printf 'GRUB_ICON_MENU_ORDER=linux\n' >"$W/fw/etc/default/grub.d/zz.cfg"
fwhook "$FX/ubuntu-only.cfg" "$W/fw6.cfg"
rm -f "$W/fw/etc/default/grub.d/zz.cfg"
check "firmware: GRUB_ICON_MENU_ORDER=linux -> no Windows icon" bash -c "! grep -q 'gim-windows' '$W/fw6.cfg'"
fwhook "$FX/windows-ubuntu.cfg" "$W/fw7.cfg" GIM_SYSCONFDIR="$W/etc"
check "chainload mode: icon boots the os-prober entry, no handoff" \
    bash -c "grep -q \"set gim_target_windows='osprober-efi-63A4-7C42'\" '$W/fw7.cfg' && ! grep -q 'gim-windows-handoff\\|gim.bootnext' '$W/fw7.cfg'"
fwhook "$FX/windows-ubuntu.cfg" "$W/fw8.cfg"
check "firmware: identical output on identical input" cmp -s "$W/fw1.cfg" "$W/fw8.cfg"

# Plain menu (GRUB_ICON_MENU=false): no chooser, but the safe Windows entry
# stays and the menu is shown (Ubuntu hides a menu that lists only Ubuntu).
printf 'GRUB_ICON_MENU=false\n' >"$W/fw/etc/default/grub.d/zz.cfg"
fwhook "$FX/ubuntu-only.cfg" "$W/fw9.cfg"
rm -f "$W/fw/etc/default/grub.d/zz.cfg"
check "plain: grub-script-check" grub-script-check "$W/fw9.cfg"
check "plain: no icon chooser" bash -c "! grep -q 'gim_entries\|chooser.cfg' '$W/fw9.cfg'"
check "plain: BitLocker-safe Windows entry kept" grep -q -- "--id gim-windows-handoff {" "$W/fw9.cfg"
check "plain: menu shown, timeout 0 raised to 10" \
    bash -c "grep -q '^  set timeout_style=menu$' '$W/fw9.cfg' && grep -q 'if \[ \"\${timeout}\" = 0 \]; then set timeout=10; fi' '$W/fw9.cfg'"
check "plain: grub-reboot (boot_once) is not interrupted" grep -q 'if \[ "${boot_once}" != true \]; then' "$W/fw9.cfg"
printf 'GRUB_ICON_MENU=false\nGRUB_ICON_MENU_WINDOWS_BOOT=chainload\n' >"$W/fw/etc/default/grub.d/zz.cfg"
fwhook "$FX/windows-ubuntu.cfg" "$W/fw10.cfg"
rm -f "$W/fw/etc/default/grub.d/zz.cfg"
check "plain + chainload: nothing added" bash -c "! grep -q 'gim-windows-handoff\|timeout_style' <(sed -n '/BEGIN \/etc\/grub.d\/99_grub_icon_menu/,\$p' '$W/fw10.cfg')"

# Background picture: the second pass shows it again while the entry loads.
check "no background: second pass keeps the white console" \
    bash -c "grep -q 'if \[ -f \"\${gim_dir}/background.png\" \]; then set gim_bg=' '$W/fw1.cfg' && grep -q 'export gim_bg' '$W/fw1.cfg'"
check "second pass: background_image, else black on white" \
    bash -c "grep -q 'if background_image \"\${gim_bg}\"; then set color_normal=black/black; fi' '$W/fw1.cfg' && grep -q '^  set color_normal=black/white$' '$W/fw1.cfg'"

# Kernel of the handoff: the newest SIGNED one (a minimal PE image with or
# without a certificate table stands in for a kernel).
pe() {   # pe FILE CERT_SIZE
    python3 - "$1" "$2" <<'EOF'
import struct, sys
b = bytearray(512)
b[0:2] = b"MZ"; struct.pack_into("<I", b, 60, 64)
b[64:68] = b"PE\0\0"; struct.pack_into("<H", b, 64 + 24, 0x20b)
struct.pack_into("<II", b, 64 + 24 + 112 + 32, 256 if int(sys.argv[2]) else 0, int(sys.argv[2]))
open(sys.argv[1], "wb").write(b)
EOF
}
mkdir -p "$W/kboot"
pe "$W/kboot/vmlinuz-7.0.0-38-generic" 1024; pe "$W/kboot/vmlinuz-7.0.0-40-generic" 0
pe "$W/kboot/vmlinuz-6.9.0-1-generic" 1024; printf 'x' >"$W/kboot/vmlinuz-7.0.0-38-generic.old"
kernel_for_handoff() { bash -c "GIM_HOOK_LIB=1; . '$P/grub.d/99_grub_icon_menu'; GIM_BOOT_DIR='$1' gim_handoff_kernel"; }
check "handoff kernel: newest signed (unsigned 7.0.0-40 skipped)" [ "$(kernel_for_handoff "$W/kboot")" = "$W/kboot/vmlinuz-7.0.0-38-generic" ]
mkdir -p "$W/kboot2"; pe "$W/kboot2/vmlinuz-7.0.0-40-generic" 0; pe "$W/kboot2/vmlinuz-7.0.0-38-generic" 0
check "handoff kernel: none signed -> newest" [ "$(kernel_for_handoff "$W/kboot2")" = "$W/kboot2/vmlinuz-7.0.0-40-generic" ]
if [ -r /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed ]; then
    check "signature test: Canonical-signed EFI binary" bash -c "GIM_HOOK_LIB=1; . '$P/grub.d/99_grub_icon_menu'; gim_kernel_signed /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed"
fi
check "signature test: not a PE file" bash -c "GIM_HOOK_LIB=1; . '$P/grub.d/99_grub_icon_menu'; ! gim_kernel_signed '$FX/windows-ubuntu.cfg'"

if [ -x /bin/busybox ] && file -bL /bin/busybox | grep -q 'statically linked'; then
    mkdir -p "$W/bb"
    for a in $(/bin/busybox --list); do ln -sf /bin/busybox "$W/bb/$a"; done
    handoff() {   # handoff VARS_DIR CMDLINE [BOOTNEXT_BYTES] -> REBOOT|POWEROFF; BootNext left in $W/h
        rm -rf "$W/h"; mkdir -p "$W/h"; cp -r "$1" "$W/h/efivars"; printf '%s\n' "$2" >"$W/h/cmdline"
        if [ -n "${3:-}" ]; then printf "$3" >"$W/h/efivars/BootNext-$GUID"; fi
        env -i PATH="$W/bb" GIM_HANDOFF_TEST="$W/h" /bin/busybox sh "$P/handoff/init" </dev/null 2>&1 | tail -n1
    }
    bootnext() { od -An -tx1 "$W/h/efivars/BootNext-$GUID" 2>/dev/null | tr -d ' \n'; }
    check "init: hint verified, BootNext=Boot0003 written, restart" \
        bash -c '[ "$1" = REBOOT ] && [ "$2" = 070000000300 ]' _ "$(handoff "$W/efivars" "quiet gim.bootnext=0003")" "$(bootnext)"
    check "init: stale hint -> searches the entries" \
        bash -c '[ "$1" = REBOOT ] && [ "$2" = 070000000300 ]' _ "$(handoff "$W/efivars" "gim.bootnext=0002")" "$(bootnext)"
    mkdir -p "$W/efivars-hi"; bootvar "$W/efivars-hi" 0A1F "Windows Boot Manager" '\EFI\Microsoft\Boot\bootmgfw.efi'
    check "init: UINT16 stored little-endian (Boot0A1F -> 1f 0a)" \
        bash -c '[ "$1" = REBOOT ] && [ "$2" = 070000001f0a ]' _ "$(handoff "$W/efivars-hi" "gim.bootnext=0a1f")" "$(bootnext)"
    check "init: no Windows entry -> nothing written, power off" \
        bash -c '[ "$1" = POWEROFF ] && [ -z "$2" ]' _ "$(handoff "$W/efivars-nowin" "gim.bootnext=0003")" "$(bootnext)"
    check "init: BootNext still set from last time -> removed, power off (no loop)" \
        bash -c '[ "$1" = POWEROFF ] && [ -z "$2" ]' _ "$(handoff "$W/efivars" "gim.bootnext=0003" '\007\000\000\000\003\000')" "$(bootnext)"
    check "init: other pending BootNext is replaced" \
        bash -c '[ "$1" = REBOOT ] && [ "$2" = 070000000300 ]' _ "$(handoff "$W/efivars" "gim.bootnext=0003" '\007\000\000\000\000\000')" "$(bootnext)"
    mkdir -p "$W/efivars-empty"
    check "init: no UEFI variables -> power off" [ "$(handoff "$W/efivars-empty" "gim.bootnext=0003")" = POWEROFF ]

    "$P/scripts/build-handoff.sh" --out "$W/h1.img" && "$P/scripts/build-handoff.sh" --out "$W/h2.img"
    check "handoff.img: reproducible build" cmp -s "$W/h1.img" "$W/h2.img"
    check "handoff.img: init, static busybox and /dev/console" bash -c "
        zcat '$W/h1.img' | cpio -t 2>/dev/null | sort | tr '\n' ' ' | grep -qx 'bin bin/busybox dev dev/console init proc sys tmp '"
    check "handoff.img: /init is handoff/init" bash -c "
        cd '$W' && mkdir -p x && cd x && zcat '$W/h1.img' | cpio -i --quiet init 2>/dev/null; cmp -s init '$P/handoff/init'"
else
    echo "  skip  handoff/init tests (no static /bin/busybox: sudo apt install busybox-static)"
fi

echo "== 8. look: background, colours, sharpness"
IMG=magick; command -v magick >/dev/null 2>&1 || IMG=convert
"$IMG" -size 800x450 gradient:'#101418-#2a2f38' "$W/dark.jpg"
"$IMG" -size 2400x1600 xc:'#e8e4dc' "$W/light.png"
marker() { sed -n "s/^$2=//p" "$1/.grub-icon-menu"; }
"$P/scripts/generate-assets.sh" --resolution 1920x1080 --out "$W/l-dark" --background "$W/dark.jpg" >"$W/l-dark.log" 2>&1
check "dark picture: white icons, shadow on" \
    bash -c '[ "$1" = white/auto ] && grep -q "shadow: on" "$2"' _ "$(marker "$W/l-dark" FOREGROUND)/$(marker "$W/l-dark" SHADOW)" "$W/l-dark.log"
check "dark picture: background.png fills 1920x1080 (RGB PNG)" \
    bash -c "file -b '$W/l-dark/background.png' | grep -qx 'PNG image data, 1920 x 1080, 8-bit/color RGB, non-interlaced'"
check "small picture: warning about soft result" grep -q 'smaller than the screen' "$W/l-dark.log"
check "dark picture: theme uses it, console white" \
    bash -c "grep -q '^desktop-image: \"background.png\"' '$W/l-dark/icon-menu.txt' && [ \"\$(sed -n 's/^CONSOLE_FG=//p' '$W/l-dark/.grub-icon-menu')\" = white ]"
check "dark picture: full menu text white, selected text black" \
    bash -c "grep -q 'item_color = \"#ffffff\"' '$W/l-dark/theme.txt' && grep -q 'selected_item_color = \"#000000\"' '$W/l-dark/theme.txt'"
"$P/scripts/generate-assets.sh" --resolution 1920x1080 --out "$W/l-light" --background "$W/light.png" >"$W/l-light.log" 2>&1
check "light picture: black icons" [ "$(marker "$W/l-light" FOREGROUND)" = black ]
check "large picture: no warning" bash -c "! grep -q 'smaller than the screen' '$W/l-light.log'"
"$P/scripts/generate-assets.sh" --resolution 1920x1080 --out "$W/l-forced" --background "$W/light.png" --icon-color white --shadow off >/dev/null 2>&1
check "--icon-color white / --shadow off override auto" \
    [ "$(marker "$W/l-forced" FOREGROUND)/$(marker "$W/l-forced" SHADOW)" = white/off ]
check "no picture: no background.png, white desktop" \
    bash -c "[ ! -e '$W/theme/background.png' ] && grep -q '^desktop-color: \"#ffffff\"' '$W/theme/icon-menu.txt'"
check "bad picture is refused" bash -c "! '$P/scripts/generate-assets.sh' --resolution 1920x1080 --out '$W/l-bad' --background '$FX/windows-ubuntu.cfg' >/dev/null 2>&1"
check "chooser: entry titles drawn off the screen" \
    bash -c "[ \"\$(sed -n 's/^ *item_icon_space = //p' '$W/l-dark/icon-menu.txt')\" -ge 1920 ]"
check "full-screen text area (no box while the entry loads)" \
    bash -c "grep -q '^terminal-width: \"100%\"' '$W/l-dark/icon-menu.txt' && grep -q '^terminal-height: \"100%\"' '$W/l-dark/theme.txt'"
# Sharpness: a row through the upper panes of the Windows logo crosses the
# vertical gap with fully opaque / fully transparent pixels only (the snapped
# edges have no blurred column), and the gap is at least 2 px wide.
if python3 -c 'import PIL' 2>/dev/null; then
    check "Windows logo: crisp vertical gap (no partial pixels)" python3 - "$W/theme/icons/gim-windows-0.png" <<'EOF'
import sys
from PIL import Image
a = Image.open(sys.argv[1]).getchannel("A")
w, h = a.size
px = a.load()
cols = [x for x in range(w) if any(px[x, y] for y in range(h))]
rows = [y for y in range(h) if any(px[x, y] for x in range(cols[0], cols[0] + 5))]
y = rows[0] + (rows[-1] - rows[0]) // 4          # upper panes, left edge rows
line = [px[x, y] for x in range(cols[0], cols[0] + 200) if x < w]
inner = line[: max(i for i, v in enumerate(line) if v == 255) + 1]
gap = [i for i, v in enumerate(inner) if v == 0]
partial = [v for v in inner if 0 < v < 255]
sys.exit(0 if len(gap) >= 2 and not partial else 1)
EOF
else
    echo "  skip  sharpness test (python3-pil not installed)"
fi

echo "== 9. doctor.sh (read-only health check)"
# A fake efibootmgr: Windows put itself first and a BootNext is pending.
mkdir -p "$W/stub"
cat >"$W/stub/efibootmgr" <<'EOF'
#!/bin/sh
cat <<'OUT'
BootCurrent: 0000
BootNext: 0001
Timeout: 0 seconds
BootOrder: 0001,0000,0002
Boot0000* Ubuntu	HD(1,GPT,63a47c42,0x800,0x82000)/\EFI\ubuntu\shimx64.efi
Boot0001* Windows Boot Manager	HD(1,GPT,63a47c42,0x800,0x82000)/\EFI\Microsoft\Boot\bootmgfw.efi
Boot0002* Internal Hard Disk	PciRoot(0x0)/Pci(0x2,0x4)
OUT
EOF
chmod +x "$W/stub/efibootmgr"
if [ -d /sys/firmware/efi ]; then
    PATH="$W/stub:$PATH" "$P/doctor.sh" --no-fwupd >"$W/doctor.out" 2>&1 || true
    check "doctor: Windows first in BootOrder -> exact fix command" grep -q 'sudo efibootmgr -o 0000,0001,0002' "$W/doctor.out"
    check "doctor: pending BootNext reported with the undo command" grep -q 'efibootmgr --delete-bootnext' "$W/doctor.out"
    check "doctor: Windows Boot Manager entry found" grep -q 'Windows Boot Manager: Boot0001' "$W/doctor.out"
else
    echo "  skip  doctor tests (not booted in UEFI mode)"
fi

echo "== 10. other systems (Kali, Linux Mint, Arch, ...)"
oskind() { bash -c "GIM_HOOK_LIB=1; . '$P/grub.d/99_grub_icon_menu'; gim_os_kind \"\$1\"" _ "$1"; }
for c in "kali|kali" "Kali GNU/Linux Rolling (on /dev/sda5)|kali" "Linux Mint 22.1 Xia (22.1) (on /dev/nvme0n1p6)|linuxmint" \
         "linuxmint gnu-linux gnu os|linuxmint" "fedora/shimx64.efi|fedora" "Pop!_OS 24.04|popos" \
         "opensuse-secureboot/shim.efi|opensuse" "ManjaroLinux|manjaro" "Kubuntu 24.04 (on /dev/sda3)|kubuntu" \
         "Ubuntu 24.04 LTS (on /dev/sda3)|ubuntu" "EndeavourOS|endeavouros" "Arch Linux|arch" "Debian GNU/Linux 13|debian"; do
    check "name: '${c%|*}' -> ${c#*|}" [ "$(oskind "${c%|*}")" = "${c#*|}" ]
done
check "name: unknown tool -> no icon" bash -c "! GIM_HOOK_LIB=1 . '$P/grub.d/99_grub_icon_menu' 2>/dev/null; GIM_HOOK_LIB=1; . '$P/grub.d/99_grub_icon_menu'; ! gim_os_kind 'HP Diagnostics' >/dev/null"
missing_png=""
for k in $(bash -c "GIM_HOOK_LIB=1; . '$P/grub.d/99_grub_icon_menu'; echo \$GIM_ALL_KINDS"); do
    case "$k" in windows|linux) continue ;; esac
    [ -f "$P/icons/png/$k.png" ] && [ -f "$P/icons/os/$k.svg" ] || missing_png="$missing_png $k"
done
check "every known system has icons/os/<kind>.svg and icons/png/<kind>.png${missing_png:+ (missing:$missing_png)}" [ -z "$missing_png" ]

# Fake UEFI boot entries: Ubuntu (this system), Windows, Kali, an inactive
# Fedora, a USB stick, the fallback loader, a vendor tool and a second Kali.
fwvar() {   # fwvar DIR NUM ACTIVE(0|1) DESCRIPTION [FILE]
    { printf '\007\000\000\000'; printf "\\$(printf %03o "$3")\\000\\000\\000"; printf '\074\000'; u16 "$4"
      printf '\000\000\004\004\100\000'; [ -n "${5:-}" ] && { u16 "$5"; printf '\000\000'; }; printf '\177\377\004\000'; } >"$1/Boot$2-$GUID"
}
mkdir -p "$W/fwsys"
fwvar "$W/fwsys" 0000 1 Ubuntu '\EFI\ubuntu\shimx64.efi'
fwvar "$W/fwsys" 0001 1 "Windows Boot Manager" '\EFI\Microsoft\Boot\bootmgfw.efi'
fwvar "$W/fwsys" 0003 1 kali '\EFI\kali\shimx64.efi'
fwvar "$W/fwsys" 0004 0 Fedora '\EFI\fedora\shimx64.efi'
fwvar "$W/fwsys" 0005 1 "USB Drive (UEFI)"
fwvar "$W/fwsys" 0006 1 "UEFI OS" '\EFI\BOOT\BOOTX64.EFI'
fwvar "$W/fwsys" 0007 1 "HP Diagnostics" '\EFI\HP\diags.efi'
fwvar "$W/fwsys" 0008 1 "kali (backup)" '\EFI\kali\grubx64.efi'
printf '\007\000\000\000\000\000\001\000\003\000\010\000\004\000' >"$W/fwsys/BootOrder-$GUID"
fwsys() { bash -c "GIM_HOOK_LIB=1; . '$P/grub.d/99_grub_icon_menu'; GIM_EFIVARS='$1' gim_firmware_systems"; }
check "firmware entries: only Kali (Ubuntu, Windows, inactive, USB, fallback, tools, duplicate skipped)" \
    [ "$(fwsys "$W/fwsys")" = "kali 0003 /efi/kali/shimx64.efi Kali Linux" ]
printf '\007\000\000\000\003\000' >"$W/fwsys/BootCurrent-$GUID"
check "firmware entries: the entry this system started from is skipped" [ -z "$(fwsys "$W/fwsys" | grep ' 0003 ')" ]
rm -f "$W/fwsys/BootCurrent-$GUID"

# Hook: Kali gets an icon when the theme has one, else it is reported.
"$P/scripts/generate-assets.sh" --resolution 1920x1080 --out "$W/theme3" --order "windows linux kali" >/dev/null 2>&1
echo dummy >"$W/theme3/handoff.img"
printf 'GRUB_ICON_MENU_THEME_DIR=%s\n' "$W/theme3" >"$W/fw/etc/default/grub.d/zz.cfg"
fwhook "$FX/ubuntu-only.cfg" "$W/os1.cfg" GIM_EFIVARS="$W/fwsys"
check "Kali icon: grub-script-check" grub-script-check "$W/os1.cfg"
check "Kali icon: layout windows-linux-kali" [ "$(fwfield "$W/os1.cfg" LAYOUT)" = windows-linux-kali ]
check "Kali icon: firmware handoff to Boot0003, file checked by handoff/init" \
    grep -q "^    linux '/vmlinuz-7.0.0-38-generic' gim.bootnext=0003 gim.match=/efi/kali/shimx64.efi quiet" "$W/os1.cfg"
check "Kali icon: entry in the full menu" grep -q -- "^menuentry 'Kali Linux (started by the UEFI firmware)' --class kali --class os --id gim-kali-handoff {" "$W/os1.cfg"
check "Kali icon: detect-os reports it" [ "$(fwfield "$W/os1.cfg" TARGET_KALI)" = gim-kali-handoff ]
check "Windows line unchanged (no gim.match)" grep -q "gim.bootnext=0001 quiet loglevel=0" "$W/os1.cfg"
printf 'GRUB_ICON_MENU_THEME_DIR=%s\n' "$W/theme" >"$W/fw/etc/default/grub.d/zz.cfg"
fwhook "$FX/ubuntu-only.cfg" "$W/os2.cfg" GIM_EFIVARS="$W/fwsys"
check "no Kali icon in the theme yet: icons for Windows + Ubuntu" [ "$(fwfield "$W/os2.cfg" LAYOUT)" = windows-linux ]
check "no Kali icon yet: reported as MISSING_ICONS" [ "$(fwfield "$W/os2.cfg" MISSING_ICONS)" = kali ]
check "no Kali icon yet: still in the full menu" grep -q -- "--id gim-kali-handoff {" "$W/os2.cfg"
check "no Kali icon yet: grub-script-check" grub-script-check "$W/os2.cfg"
printf 'GRUB_ICON_MENU_THEME_DIR=%s\nGRUB_ICON_MENU_FIRMWARE_SYSTEMS=false\n' "$W/theme3" >"$W/fw/etc/default/grub.d/zz.cfg"
fwhook "$FX/ubuntu-only.cfg" "$W/os3.cfg" GIM_EFIVARS="$W/fwsys"
check "GRUB_ICON_MENU_FIRMWARE_SYSTEMS=false: no Kali" bash -c "! grep -q gim-kali '$W/os3.cfg'"

# os-prober: Linux Mint and Arch get their own icons (FOREIGN_LINUX=true).
cp "$FX/ubuntu-mint.cfg" "$W/mint.cfg"
"$P/scripts/generate-assets.sh" --resolution 1920x1080 --out "$W/theme4" --order "windows linux linuxmint arch" >/dev/null 2>&1
echo dummy >"$W/theme4/handoff.img"
printf 'GRUB_ICON_MENU_THEME_DIR=%s\nGRUB_ICON_MENU_FOREIGN_LINUX=true\n' "$W/theme4" >"$W/fw/etc/default/grub.d/zz.cfg"
fwhook "$W/mint.cfg" "$W/os4.cfg"
check "os-prober Linux Mint: own icon (layout windows-linux-linuxmint)" [ "$(fwfield "$W/os4.cfg" LAYOUT)" = windows-linux-linuxmint ]
check "os-prober Linux Mint: boots its os-prober entry" [ "$(fwfield "$W/os4.cfg" TARGET_LINUXMINT)" = osprober-gnulinux-simple-6666 ]
check "os-prober Linux Mint: Ubuntu keeps the Tux icon" bash -c "[ \"\$('$P/detect-os.sh' --cfg '$W/os4.cfg' --platform efi | sed -n 's/^TARGET_LINUX=//p')\" != osprober-gnulinux-simple-6666 ]"
fwhook "$FX/ubuntu-unknown.cfg" "$W/os5.cfg"
check "os-prober Arch Linux: own icon" [ "$(fwfield "$W/os5.cfg" TARGET_ARCH)" = osprober-gnulinux-simple-1111 ]
rm -f "$W/fw/etc/default/grub.d/zz.cfg"
check "generate-assets: 3 icons -> 7 layouts, 12 images" bash -c "[ \$(ls '$W/theme3/icons' | wc -l) = 12 ]"
check "generate-assets: at most 6 icons" bash -c "! '$P/scripts/generate-assets.sh' --out '$W/t7' --order 'windows linux kali arch fedora debian opensuse' >/dev/null 2>&1"
check "generate-assets: unknown icon refused" bash -c "! '$P/scripts/generate-assets.sh' --out '$W/t8' --order 'windows haiku' >/dev/null 2>&1"

if [ -x /bin/busybox ] && file -bL /bin/busybox | grep -q 'statically linked'; then
    check "init: gim.match Kali -> BootNext=Boot0003" \
        bash -c '[ "$1" = REBOOT ] && [ "$2" = 070000000300 ]' _ "$(handoff "$W/fwsys" "gim.bootnext=0003 gim.match=/efi/kali/shimx64.efi")" "$(bootnext)"
    check "init: gim.match with a stale number -> searches (Boot0003)" \
        bash -c '[ "$1" = REBOOT ] && [ "$2" = 070000000300 ]' _ "$(handoff "$W/fwsys" "gim.bootnext=0001 gim.match=/efi/kali/shimx64.efi")" "$(bootnext)"
    check "init: gim.match not in the boot list -> nothing written, power off" \
        bash -c '[ "$1" = POWEROFF ] && [ -z "$2" ]' _ "$(handoff "$W/fwsys" "gim.bootnext=0009 gim.match=/efi/arch/grubx64.efi")" "$(bootnext)"
    check "init: invalid gim.match -> nothing written, power off" \
        bash -c '[ "$1" = POWEROFF ] && [ -z "$2" ]' _ "$(handoff "$W/fwsys" "gim.bootnext=0003 gim.match=/efi/kali/*.efi")" "$(bootnext)"
    check "init: without gim.match still Windows" \
        bash -c '[ "$1" = REBOOT ] && [ "$2" = 070000000100 ]' _ "$(handoff "$W/fwsys" "gim.bootnext=0003")" "$(bootnext)"
fi

echo
echo "unit tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
