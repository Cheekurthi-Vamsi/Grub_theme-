#!/bin/bash
#
# inspect.sh - read-only report of the boot setup (Phase 1 of install.sh).
#
#   sudo ./inspect.sh      # complete report
#   ./inspect.sh           # partial: grub.cfg and some firmware data are root-only
#
# Changes nothing. Safe to run at any time.

set -Eeuo pipefail
PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$PROJECT_DIR/lib/common.sh"

section() { printf '\n== %s ==\n' "$*"; }
kv() { printf '  %-28s %s\n' "$1" "$2"; }

section "System"
kv "Kernel" "$(uname -srm)"
if [ -r /etc/os-release ]; then
    kv "Distribution" "$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-unknown}")"
fi
kv "GRUB" "$(grub_version || echo unknown)"
kv "Boot mode" "$(boot_mode)"
kv "Secure Boot" "$(secure_boot_state)"
kv "/boot" "$(findmnt -n -o SOURCE,FSTYPE /boot 2>/dev/null || echo 'part of /')"
esp="$(find_esp || true)"
kv "EFI System Partition" "${esp:-not found}${esp:+ ($(findmnt -n -o SOURCE,FSTYPE "$esp" 2>/dev/null))}"

section "GRUB settings (effective: /etc/default/grub + /etc/default/grub.d/*.cfg)"
for v in GRUB_DEFAULT GRUB_SAVEDEFAULT GRUB_TIMEOUT GRUB_TIMEOUT_STYLE GRUB_THEME \
         GRUB_TERMINAL GRUB_TERMINAL_OUTPUT GRUB_GFXMODE GRUB_DISABLE_OS_PROBER \
         GRUB_DISABLE_SUBMENU GRUB_ICON_MENU GRUB_ICON_MENU_TIMEOUT GRUB_ICON_MENU_WINDOWS_BOOT; do
    val="$(grub_setting "$v")"
    kv "$v" "${val:-(unset)}"
done
if [ -d /etc/default/grub.d ]; then
    kv "drop-in files" "$(cd /etc/default/grub.d && ls -1 ./*.cfg 2>/dev/null | sed 's|^\./||' | paste -sd ' ' -)"
fi
kv "os-prober" "$(command -v os-prober >/dev/null && echo installed || echo 'not installed')"
kv "/etc/grub.d scripts" "$(cd /etc/grub.d && for f in *; do [ -x "$f" ] && [ -f "$f" ] && printf '%s ' "$f"; done)"

section "grub-icon-menu"
kv "hook" "$( [ -f "$GIM_HOOK" ] && echo "$GIM_HOOK" || echo 'not installed')"
kv "config drop-in" "$( [ -f "$GIM_DROPIN" ] && echo "$GIM_DROPIN" || echo 'not installed')"
kv "theme" "$( [ -f "$GIM_THEME_DIR/$GIM_MARKER" ] && sed -n 's/^RESOLUTION=/generated for /p' "$GIM_THEME_DIR/$GIM_MARKER" || echo 'not installed')"
kv "last backup" "$(state_get BACKUP 2>/dev/null || echo none)"
kv "Windows handoff" "$( [ -f "$GIM_THEME_DIR/handoff.img" ] && echo present || echo 'not installed')"
kv "background" "$( [ -f "$GIM_THEME_DIR/background.png" ] && echo "picture ($(ls "$GIM_BG_STORE".* 2>/dev/null | head -n1 || echo 'no kept copy'))" || echo white)"
fg="$(sed -n 's/^FOREGROUND=//p' "$GIM_THEME_DIR/$GIM_MARKER" 2>/dev/null || true)"
kv "icon colour" "${fg:-black}"
kv "health check" "sudo $PROJECT_DIR/doctor.sh"

section "Firmware / filesystem evidence"
"$PROJECT_DIR/scripts/detect-windows.sh" | sed 's/^/  /'
"$PROJECT_DIR/scripts/detect-ubuntu.sh" | sed 's/^/  /'
if command -v efibootmgr >/dev/null 2>&1 && [ -d /sys/firmware/efi ]; then
    echo "  UEFI boot entries:"
    efibootmgr 2>/dev/null | grep -E '^Boot[0-9A-F]{4}|^BootNext' | sed 's/\t.*//; s/^/    /' || true
fi

section "GRUB menu (current $GIM_GRUB_CFG)"
if [ -r "$GIM_GRUB_CFG" ]; then
    "$PROJECT_DIR/detect-os.sh" --cfg "$GIM_GRUB_CFG" -v 2>&1 | sed 's/^/  /'
    if grep -q '^### BEGIN /etc/grub.d/99_grub_icon_menu ###' "$GIM_GRUB_CFG"; then
        kv "icon chooser in grub.cfg" "yes"
    else
        kv "icon chooser in grub.cfg" "no"
    fi
else
    echo "  $GIM_GRUB_CFG is readable by root only - run: sudo $0"
fi
echo
