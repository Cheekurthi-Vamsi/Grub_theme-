#!/bin/bash
#
# tests/sandbox-test.sh - full lifecycle test of the real scripts inside the
# bubblewrap sandbox (see tests/sandbox.sh): install, kernel update +
# update-grub, update.sh (no-op, new resolution, Windows removed/re-added,
# chainload <-> firmware, background picture, plain menu, other systems:
# Kali with its own UEFI entry, Linux Mint through --os-prober), failure +
# rollback, uninstall, restore, failed install + rollback.
#
#   tests/sandbox-test.sh [SANDBOX_DIR]
#
# Uses the real update-grub, grub-mkconfig and Ubuntu /etc/grub.d scripts.
# Also verifies that the host's /etc/default and /etc/grub.d were not touched.

set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$HERE/.." && pwd)"
SB="${1:-$(mktemp -d "${TMPDIR:-/tmp}/gim-sandbox.XXXXXX")}"
SBX=("$HERE/sandbox.sh" run "$SB")
cd "$PROJECT_DIR"

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ok    %s\n' "$*"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$*"; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
inbox() { "${SBX[@]}" "$@"; }
cfg="$SB/boot/grub/grub.cfg"
detect() { "$PROJECT_DIR/detect-os.sh" --cfg "$cfg" --platform efi | sed -n "s/^$1=//p"; }
has_chooser() { grep -q 'configfile "${gim_dir}/chooser.cfg"' "$cfg"; }
host_sum() { find /etc/default /etc/grub.d -type f -readable -exec sha256sum {} + 2>/dev/null | sort; }

host_before="$(host_sum)"

echo "== setup (sandbox: $SB)"
"$HERE/sandbox.sh" setup "$SB" >/dev/null
inbox update-grub >/dev/null 2>&1
cp "$cfg" "$SB/baseline.cfg"
check "baseline menu has no Windows entry (os-prober in auto mode)" [ "$(detect WINDOWS)" = 0 ]
base_etc="$(cd "$SB" && find etc-default etc-grub.d -type f -exec sha256sum {} + | sort)"

echo "== TEST 1: install (Windows + Ubuntu)"
if inbox ./install.sh --yes >"$SB/t1.log" 2>&1; then ok "install.sh exit 0"; else bad "install.sh failed (see $SB/t1.log)"; fi
check "success message printed" grep -q '^Installation completed successfully.$' "$SB/t1.log"
check "reboot advice printed" grep -q '^Reboot manually to test the GRUB menu.$' "$SB/t1.log"
check "hook installed" [ -x "$SB/etc-grub.d/99_grub_icon_menu" ]
check "settings drop-in installed" [ -f "$SB/etc-default/grub.d/99-grub-icon-menu.cfg" ]
dropin="$SB/etc-default/grub.d/99-grub-icon-menu.cfg"
check "Windows through the firmware (default)" grep -q '^GRUB_ICON_MENU_WINDOWS_BOOT=firmware$' "$dropin"
check "os-prober disabled by the drop-in (no chainload entry)" grep -q '^GRUB_DISABLE_OS_PROBER=true$' "$dropin"
check "handoff.img installed" [ -s "$SB/boot/grub/themes/grub-icon-menu/handoff.img" ]
check "Windows icon boots the handoff entry" [ "$(detect TARGET_WINDOWS)" = gim-windows-handoff ]
# Paths relative to the /boot partition, as grub-mkrelpath sees them (in the
# sandbox /boot is a bind mount, so they carry its source directory): the
# handoff kernel must be written exactly like 10_linux writes its kernels.
kdir="$(sed -n 's/^\s*linux\s\+\(\S*\)\/vmlinuz-7.0.0-38-generic .*/\1/p' "$cfg" | head -n1)"
check "handoff: newest kernel, BootNext=Boot0001" \
    grep -qF "  linux '$kdir/vmlinuz-7.0.0-38-generic' gim.bootnext=0001 quiet loglevel=0 panic=10" "$cfg"
check "handoff: initrd from the /boot partition" grep -qF "  set gim_handoff=\"(\${root})$kdir/grub/themes/grub-icon-menu/handoff.img\"" "$cfg"
check "handoff: /boot partition located by UUID" \
    bash -c "sed -n '/--id gim-windows-handoff/,/^}/p' '$cfg' | grep -q 'search --no-floppy --fs-uuid --set=root .*1f97a033-564c-48d9-87a0-0b664bc2adad'"
check "no GRUB chainload entry for Windows" bash -c "! grep -qi 'chainloader.*bootmgfw' '$cfg'"
check "/etc/default/grub not modified" cmp -s /etc/default/grub "$SB/etc-default/grub"
check "theme installed" [ -f "$SB/boot/grub/themes/grub-icon-menu/.grub-icon-menu" ]
check "grub.cfg passes grub-script-check" grub-script-check "$cfg"
check "grub.cfg contains the chooser" has_chooser
check "layout windows-linux" [ "$(detect LAYOUT)" = windows-linux ]
check "icon classes in grub.cfg" grep -q -- '--class gim-windows-linux-0 --id gim-windows' "$cfg"
check "no OS name in chooser titles" bash -c "! sed -n '/^function gim_entries/,/^}/p' '$cfg' | sed -n \"s/^ *menuentry '\\([^']*\\)'.*/\\1/p\" | grep -qi 'windows\\|ubuntu\\|linux'"
check "standard entries untouched (same Ubuntu entries as before)" \
    cmp -s <(grep -E "^\s*menuentry '(Ubuntu|Ubuntu, with Linux[^']*)'" "$SB/baseline.cfg") <(grep -E "^\s*menuentry '(Ubuntu|Ubuntu, with Linux[^']*)'" "$cfg")
backup_install="$(ls -d "$SB"/home/grub-icon-menu-backup/*-install | head -n1)"
check "backup snapshot with restore script" [ -x "$backup_install/restore.sh" ]
check "backup integrity (SHA256SUMS)" bash -c "cd '$backup_install/files' && sha256sum --quiet -c '$backup_install/SHA256SUMS'"

echo "== TEST 7: kernel update, plain update-grub"
: >"$SB/boot/vmlinuz-7.0.0-40-generic"; : >"$SB/boot/initrd.img-7.0.0-40-generic"
inbox update-grub >/dev/null 2>&1
check "chooser still present" has_chooser
check "still one Linux icon (layout windows-linux)" [ "$(detect LAYOUT)" = windows-linux ]
check "Linux target stable (gnulinux-simple)" bash -c "'$PROJECT_DIR/detect-os.sh' --cfg '$cfg' --platform efi | grep -q '^TARGET_LINUX=gnulinux-simple-'"
check "new kernel present in the menu" grep -q "vmlinuz-7.0.0-40-generic" "$cfg"
check "grouped Linux entries grew to 7" [ "$(detect ENTRIES_LINUX)" = 7 ]
check "handoff follows the newest kernel" grep -qF "  linux '$kdir/vmlinuz-7.0.0-40-generic' gim.bootnext=0001 " "$cfg"

echo "== update.sh (nothing to rebuild)"
if inbox ./update.sh --yes >"$SB/u1.log" 2>&1; then ok "update.sh exit 0"; else bad "update.sh failed ($SB/u1.log)"; fi
check "theme kept (no rebuild, handoff.img current)" grep -q 'theme up to date' "$SB/u1.log"

echo "== update.sh --resolution 1366x768"
if inbox ./update.sh --resolution 1366x768 --yes >"$SB/u2.log" 2>&1; then ok "update.sh exit 0"; else bad "update.sh failed ($SB/u2.log)"; fi
check "theme rebuilt for 1366x768" grep -q '^RESOLUTION=1366x768$' "$SB/boot/grub/themes/grub-icon-menu/.grub-icon-menu"
check "GRUB_GFXMODE updated" grep -q '^GRUB_GFXMODE=1366x768,auto$' "$SB/etc-default/grub.d/99-grub-icon-menu.cfg"
check "no leftover theme copies" bash -c "! ls -a '$SB/boot/grub/themes' | grep -q '^\.grub-icon-menu'"

echo "== Windows removed, then back"
touch "$SB/no-windows"
inbox ./update.sh --yes >"$SB/u3.log" 2>&1 || true
check "layout linux only" [ "$(detect LAYOUT)" = linux ]
check "Tux-only icon class" grep -q -- '--class gim-linux-0 --id gim-linux' "$cfg"
rm -f "$SB/no-windows"
inbox update-grub >/dev/null 2>&1
check "Windows icon back after update-grub" [ "$(detect LAYOUT)" = windows-linux ]

echo "== update.sh --windows-boot chainload, then back to firmware"
if inbox ./update.sh --windows-boot chainload --yes >"$SB/u5.log" 2>&1; then ok "update.sh exit 0"; else bad "update.sh failed ($SB/u5.log)"; fi
check "chainload: os-prober enabled" grep -q '^GRUB_DISABLE_OS_PROBER=false$' "$dropin"
check "chainload: icon boots the os-prober entry" [ "$(detect TARGET_WINDOWS)" = osprober-efi-63A4-7C42 ]
check "chainload: BitLocker warning printed" grep -q 'asks for the recovery key' "$SB/u5.log"
if inbox ./update.sh --yes >"$SB/u6.log" 2>&1; then ok "update.sh exit 0 (setting kept)"; else bad "update.sh failed ($SB/u6.log)"; fi
check "chainload kept by a plain update.sh" [ "$(detect TARGET_WINDOWS)" = osprober-efi-63A4-7C42 ]
if inbox ./update.sh --windows-boot firmware --yes >"$SB/u7.log" 2>&1; then ok "update.sh exit 0"; else bad "update.sh failed ($SB/u7.log)"; fi
check "firmware again: handoff entry" [ "$(detect TARGET_WINDOWS)" = gim-windows-handoff ]
check "firmware again: os-prober disabled, chainload entry gone" \
    bash -c "grep -q '^GRUB_DISABLE_OS_PROBER=true$' '$dropin' && ! grep -qi 'chainloader.*bootmgfw' '$cfg'"

echo "== update.sh failure -> rollback"
pre_cfg="$(sha256sum <"$cfg")"; pre_hook="$(sha256sum <"$SB/etc-grub.d/99_grub_icon_menu")"
echo '*.cfg.new' >"$SB/fail-script-check"   # fail only the final check of grub-mkconfig
if inbox ./update.sh --rebuild --yes >"$SB/u4.log" 2>&1; then bad "update.sh should have failed"; else ok "update.sh failed as expected"; fi
rm -f "$SB/fail-script-check"
check "rollback reported" grep -q 'previous installation restored' "$SB/u4.log"
check "grub.cfg unchanged after rollback" [ "$pre_cfg" = "$(sha256sum <"$cfg")" ]
check "hook unchanged after rollback" [ "$pre_hook" = "$(sha256sum <"$SB/etc-grub.d/99_grub_icon_menu")" ]
check "theme still valid after rollback" [ -f "$SB/boot/grub/themes/grub-icon-menu/icons/gim-windows-linux-1.png" ]

echo "== update.sh -bg (background picture), --plain / --icons, -bg none"
theme="$SB/boot/grub/themes/grub-icon-menu"
mk() { sed -n "s/^$1=//p" "$theme/.grub-icon-menu"; }
IMG=magick; command -v magick >/dev/null 2>&1 || IMG=convert
mkdir -p "$SB/pics"
"$IMG" -size 2732x1536 gradient:'#0d1b2a-#1b263b' "$SB/pics/night sky.jpg"
"$IMG" -size 2732x1536 xc:'#f0ece4' "$SB/pics/paper.png"
if inbox ./update.sh -bg "$SB/pics/night sky.jpg" --yes >"$SB/b1.log" 2>&1; then ok "update.sh -bg exit 0"; else bad "update.sh -bg failed ($SB/b1.log)"; fi
check "background.png installed at the theme resolution" \
    bash -c "file -b '$theme/background.png' | grep -q '1366 x 768, 8-bit/color RGB'"
check "dark picture -> white icons" [ "$(mk FOREGROUND)" = white ]
check "copy of the picture kept in /var/lib/grub-icon-menu" [ -f "$SB/varlib/grub-icon-menu/background.jpg" ]
check "state records the picture" grep -q '^BACKGROUND=/var/lib/grub-icon-menu/background.jpg$' "$SB/varlib/grub-icon-menu/state"
check "grub.cfg: background while the entry loads, white console text" \
    bash -c "grep -q 'set gim_bg=' '$cfg' && grep -q 'set color_normal=white/black' '$cfg'"
check "grub.cfg valid" grub-script-check "$cfg"
rm -f "$SB/pics/night sky.jpg"
if inbox ./update.sh --resolution 1920x1080 --yes >"$SB/b2.log" 2>&1; then ok "update.sh (original picture deleted) exit 0"; else bad "update.sh failed ($SB/b2.log)"; fi
check "rebuilt for 1920x1080 from the kept copy" \
    bash -c "file -b '$theme/background.png' | grep -q '1920 x 1080, 8-bit/color RGB' && [ \"\$(sed -n 's/^FOREGROUND=//p' '$theme/.grub-icon-menu')\" = white ]"
if inbox ./update.sh --plain --yes >"$SB/b3.log" 2>&1; then ok "update.sh --plain exit 0"; else bad "update.sh --plain failed ($SB/b3.log)"; fi
check "plain: drop-in GRUB_ICON_MENU=false" grep -q '^GRUB_ICON_MENU=false$' "$dropin"
check "plain: no icon chooser" bash -c "! grep -q 'chooser.cfg' '$cfg'"
check "plain: BitLocker-safe Windows entry in the menu" grep -q -- '--id gim-windows-handoff {' "$cfg"
check "plain: no chainload entry" bash -c "! grep -qi 'chainloader.*bootmgfw' '$cfg'"
check "plain: menu is shown" grep -q '^  set timeout_style=menu$' "$cfg"
if inbox ./update.sh --yes >"$SB/b4.log" 2>&1; then ok "update.sh exit 0 (plain kept)"; else bad "update.sh failed ($SB/b4.log)"; fi
check "plain kept by a plain update.sh" bash -c "! grep -q 'chooser.cfg' '$cfg'"
if inbox ./update.sh --icons --yes >"$SB/b5.log" 2>&1; then ok "update.sh --icons exit 0"; else bad "update.sh --icons failed ($SB/b5.log)"; fi
check "icons: chooser back" has_chooser
if inbox ./update.sh -bg none --yes >"$SB/b6.log" 2>&1; then ok "update.sh -bg none exit 0"; else bad "update.sh -bg none failed ($SB/b6.log)"; fi
check "-bg none: white screen, black icons" bash -c "[ ! -e '$theme/background.png' ] && [ \"\$(sed -n 's/^FOREGROUND=//p' '$theme/.grub-icon-menu')\" = black ]"
check "-bg none: kept copy removed" bash -c "! ls '$SB'/varlib/grub-icon-menu/background.* >/dev/null 2>&1"
if inbox ./update.sh -bg "$SB/pics/paper.png" --icon-color white --yes >"$SB/b7.log" 2>&1; then ok "update.sh -bg --icon-color exit 0"; else bad "update.sh failed ($SB/b7.log)"; fi
check "--icon-color white kept over auto (light picture)" [ "$(mk FOREGROUND)/$(mk ICON_COLOR)" = white/white ]
if inbox ./update.sh -bg "$SB/pics/missing.jpg" --yes >"$SB/b8.log" 2>&1; then bad "missing picture accepted"; else ok "missing picture refused"; fi
check "refused before any change" bash -c "[ -f '$theme/background.png' ] && grep -q 'not found or not readable' '$SB/b8.log'"

echo "== other systems: Kali installed later (own UEFI boot entry)"
touch "$SB/with-kali"
inbox update-grub >"$SB/k0.log" 2>&1 || true
check "update-grub alone: Kali reported, no icon yet" grep -q 'found without an icon yet: kali' "$SB/k0.log"
check "update-grub alone: Kali already in the full menu" grep -q -- '--id gim-kali-handoff {' "$cfg"
check "update-grub alone: icons unchanged (windows-linux)" [ "$(detect LAYOUT)" = windows-linux ]
if inbox ./update.sh --yes >"$SB/k1.log" 2>&1; then ok "update.sh exit 0"; else bad "update.sh failed ($SB/k1.log)"; fi
check "update.sh adds the Kali icon" grep -q 'New systems found: kali - adding their icons' "$SB/k1.log"
check "theme built for windows linux kali" [ "$(mk ORDER)" = "windows linux kali" ]
check "drop-in order includes kali" grep -q '^GRUB_ICON_MENU_ORDER="windows linux kali"$' "$dropin"
check "layout windows-linux-kali" [ "$(detect LAYOUT)" = windows-linux-kali ]
check "Kali icon: BootNext=Boot0003, file checked" grep -q "gim.bootnext=0003 gim.match=/efi/kali/shimx64.efi quiet" "$cfg"
check "Kali icon target" [ "$(detect TARGET_KALI)" = gim-kali-handoff ]
check "grub.cfg valid" grub-script-check "$cfg"
check "no leftover theme copies" bash -c "! ls -a '$SB/boot/grub/themes' | grep -q '^\.grub-icon-menu'"
if inbox ./update.sh --yes >"$SB/k2.log" 2>&1; then ok "update.sh again exit 0"; else bad "update.sh failed ($SB/k2.log)"; fi
check "second update: nothing new" bash -c "! grep -q 'New systems found' '$SB/k2.log'"
rm -f "$SB/with-kali"
inbox update-grub >/dev/null 2>&1 || true
check "Kali removed: back to windows-linux, no Kali entry" \
    bash -c "[ \"\$('$PROJECT_DIR/detect-os.sh' --cfg '$cfg' --platform efi | sed -n 's/^LAYOUT=//p')\" = windows-linux ] && ! grep -q gim-kali '$cfg'"

echo "== other systems: Linux Mint on another partition (--os-prober)"
touch "$SB/with-mint"
if inbox ./update.sh --os-prober --yes >"$SB/m1.log" 2>&1; then ok "update.sh --os-prober exit 0"; else bad "update.sh --os-prober failed ($SB/m1.log)"; fi
check "drop-in: os-prober on, Windows on the skip list" \
    bash -c "grep -q '^GRUB_DISABLE_OS_PROBER=false$' '$dropin' && grep -q '^GRUB_OS_PROBER_SKIP_LIST=\"63A4-7C42@/EFI/Microsoft/Boot/bootmgfw.efi\"$' '$dropin'"
check "no GRUB entry that chainloads Windows" bash -c "! grep -qi 'chainloader.*bootmgfw' '$cfg'"
check "Windows icon still started by the firmware" [ "$(detect TARGET_WINDOWS)" = gim-windows-handoff ]
check "Linux Mint gets its own icon" [ "$(detect TARGET_LINUXMINT)" = "osprober-gnulinux-simple-6666aaaa-bbbb-4ccc-8ddd-eeeeffff0006" ]
check "theme built for windows linux kali linuxmint" [ "$(mk ORDER)" = "windows linux kali linuxmint" ]
check "layout windows-linux-linuxmint" [ "$(detect LAYOUT)" = windows-linux-linuxmint ]
check "Ubuntu keeps the Tux icon" bash -c "'$PROJECT_DIR/detect-os.sh' --cfg '$cfg' --platform efi | grep -q '^TARGET_LINUX=gnulinux-simple-'"
check "grub.cfg valid" grub-script-check "$cfg"
pre_cfg="$(sha256sum <"$cfg")"
touch "$SB/skip-mismatch"
if inbox ./update.sh --rebuild --yes >"$SB/m2.log" 2>&1; then bad "Windows entry slipped through and update.sh succeeded"; else ok "update.sh refused: os-prober created a Windows entry"; fi
rm -f "$SB/skip-mismatch"
check "safety net: error explains the BitLocker risk" grep -q 'would ask for the BitLocker recovery key' "$SB/m2.log"
check "safety net: rolled back, grub.cfg unchanged" [ "$pre_cfg" = "$(sha256sum <"$cfg")" ]
if inbox ./update.sh --no-os-prober --yes >"$SB/m3.log" 2>&1; then ok "update.sh --no-os-prober exit 0"; else bad "update.sh --no-os-prober failed ($SB/m3.log)"; fi
check "os-prober off again, Linux Mint not shown" \
    bash -c "grep -q '^GRUB_DISABLE_OS_PROBER=true$' '$dropin' && ! grep -q osprober-gnulinux '$cfg'"
rm -f "$SB/with-mint"

echo "== uninstall"
if inbox ./uninstall.sh --yes >"$SB/x1.log" 2>&1; then ok "uninstall.sh exit 0"; else bad "uninstall.sh failed ($SB/x1.log)"; fi
check "hook removed" [ ! -e "$SB/etc-grub.d/99_grub_icon_menu" ]
check "drop-in removed" [ ! -e "$SB/etc-default/grub.d/99-grub-icon-menu.cfg" ]
check "theme removed" [ ! -e "$SB/boot/grub/themes/grub-icon-menu" ]
check "state and kept picture removed" [ ! -e "$SB/varlib/grub-icon-menu" ]
check "uninstall pointed to the plain menu first" grep -q 'update.sh --plain' "$SB/x1.log"
check "grub.cfg valid" grub-script-check "$cfg"
check "no grub-icon-menu code left in grub.cfg" bash -c "! grep -q 'gim_' '$cfg'"
check "Ubuntu entries preserved" [ "$(detect LINUX)" = 1 ]
check "no Windows entry left (os-prober was off; auto mode does not re-enable it)" [ "$(detect WINDOWS)" = 0 ]
check "uninstall explains how to start Windows" grep -q 'firmware boot menu' "$SB/x1.log"

echo "== restore the install backup"
rm -f "$SB/boot/vmlinuz-7.0.0-40-generic" "$SB/boot/initrd.img-7.0.0-40-generic"
if inbox "$backup_install/restore.sh" "$backup_install" --yes >"$SB/r1.log" 2>&1; then ok "restore.sh exit 0"; else bad "restore.sh failed ($SB/r1.log)"; fi
now_etc="$(cd "$SB" && find etc-default etc-grub.d -type f -exec sha256sum {} + | sort)"
check "/etc/default and /etc/grub.d identical to before installation" [ "$base_etc" = "$now_etc" ]
check "grub.cfg valid after restore" grub-script-check "$cfg"

echo "== failed install -> rollback"
pre_cfg="$(sha256sum <"$cfg")"
echo '*.cfg.new' >"$SB/fail-script-check"
if inbox ./install.sh --yes >"$SB/t2.log" 2>&1; then bad "install.sh should have failed"; else ok "install.sh failed as expected"; fi
rm -f "$SB/fail-script-check"
check "rollback reported" grep -q 'previous state restored' "$SB/t2.log"
check "no hook left" [ ! -e "$SB/etc-grub.d/99_grub_icon_menu" ]
check "no drop-in left" [ ! -e "$SB/etc-default/grub.d/99-grub-icon-menu.cfg" ]
check "no theme left" [ ! -e "$SB/boot/grub/themes/grub-icon-menu" ]
check "grub.cfg untouched" [ "$pre_cfg" = "$(sha256sum <"$cfg")" ]

echo "== host system"
check "host /etc/default and /etc/grub.d unchanged" [ "$host_before" = "$(host_sum)" ]

echo
echo "sandbox lifecycle: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
