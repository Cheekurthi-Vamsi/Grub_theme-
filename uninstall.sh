#!/bin/bash
#
# uninstall.sh - remove grub-icon-menu and regenerate the normal GRUB menu.
#
#   sudo ./uninstall.sh [--yes]
#
# Removes only files grub-icon-menu created (each is checked before removal):
#   /etc/grub.d/99_grub_icon_menu, /etc/default/grub.d/99-grub-icon-menu.cfg,
#   /boot/grub/themes/grub-icon-menu/, /var/lib/grub-icon-menu/ (state and
#   the kept copy of the background picture)
# then runs update-grub. Operating system entries are not removed: the
# Windows entry stays in the menu as long as os-prober finds it (Ubuntu's
# default "auto" mode keeps running os-prober once grub.cfg contains its
# entries). In firmware mode (the default) grub-icon-menu disabled os-prober,
# so after uninstalling GRUB lists no Windows entry until os-prober is
# enabled again; the firmware boot menu still starts Windows. To get the
# plain text menu WITH the BitLocker-safe Windows entry, do not uninstall:
# run "sudo ./update.sh --plain". A backup snapshot is taken first.
#
# To return to the exact configuration from before installation, use the
# restore script of the install backup instead (see README).

set -Eeuo pipefail
PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$PROJECT_DIR/lib/common.sh"
# shellcheck source=lib/actions.sh
. "$PROJECT_DIR/lib/actions.sh"

while [ $# -gt 0 ]; do
    case "$1" in
        --yes|-y)  GIM_ASSUME_YES=1; shift ;;
        -h|--help) sed -n '3,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)         die "unknown option: $1" ;;
    esac
done
require_root

found=()
[ -f "$GIM_HOOK" ] && found+=("$GIM_HOOK")
[ -f "$GIM_DROPIN" ] && found+=("$GIM_DROPIN")
[ -e "$GIM_THEME_DIR" ] && found+=("$GIM_THEME_DIR/")
[ -d "$GIM_STATE_DIR" ] && found+=("$GIM_STATE_DIR/")
if [ "${#found[@]}" -eq 0 ]; then
    log_info "grub-icon-menu is not installed - nothing to do"
    exit 0
fi

# Refuse to delete anything that does not carry our signature.
if [ -f "$GIM_HOOK" ] && ! grep -q 'grub-icon-menu hook' "$GIM_HOOK"; then
    die "$GIM_HOOK was not created by grub-icon-menu - not removing it"
fi
if [ -f "$GIM_DROPIN" ] && ! grep -q 'managed by grub-icon-menu' "$GIM_DROPIN"; then
    die "$GIM_DROPIN was not created by grub-icon-menu - not removing it"
fi
if [ -e "$GIM_THEME_DIR" ] && [ ! -f "$GIM_THEME_DIR/$GIM_MARKER" ]; then
    die "$GIM_THEME_DIR was not created by grub-icon-menu - not removing it"
fi

osprober_disabled=0
if [ -f "$GIM_DROPIN" ] && grep -q '^GRUB_DISABLE_OS_PROBER=true$' "$GIM_DROPIN"; then osprober_disabled=1; fi

log_step "Uninstall plan"
printf '    remove: %s\n' "${found[@]}" >&2
log_info "then regenerate $GIM_GRUB_CFG with update-grub"
if [ "$osprober_disabled" = 1 ]; then
    log_warn "afterwards GRUB has NO Windows entry: start Windows with the firmware boot menu"
    log_warn "(F9 on HP). For the plain text menu with a Windows entry that does not ask for"
    log_warn "the BitLocker recovery key, answer N and run: sudo $PROJECT_DIR/update.sh --plain"
fi
confirm "Remove grub-icon-menu?" || die "aborted - nothing was changed"

BACKUP="$(make_backup uninstall)"
GIM_LOG_FILE="$BACKUP/uninstall.log"
log_info "backup: $BACKUP"

log_step "Removing files"
[ -f "$GIM_HOOK" ] && run rm -f -- "$GIM_HOOK"
[ -f "$GIM_DROPIN" ] && run rm -f -- "$GIM_DROPIN"
if [ -f "$GIM_THEME_DIR/$GIM_MARKER" ]; then
    run rm -r -- "$GIM_THEME_DIR"
    rmdir --ignore-fail-on-non-empty -- "$(dirname -- "$GIM_THEME_DIR")" 2>/dev/null || true
fi
if [ -d "$GIM_STATE_DIR" ]; then
    rm -f -- "$GIM_STATE_FILE" "$GIM_BG_STORE".*
    rmdir -- "$GIM_STATE_DIR" 2>/dev/null || log_warn "$GIM_STATE_DIR not empty - left in place"
fi

log_step "Regenerating the standard GRUB menu"
if ! regenerate_grub; then
    log_error "update-grub failed; restoring the previous grub.cfg from $BACKUP"
    copy_preserve "$BACKUP/files$GIM_GRUB_CFG" "$GIM_GRUB_CFG"
    die "uninstall incomplete: grub-icon-menu files are removed, but grub.cfg is the old one (still bootable). Fix the update-grub error and run: sudo update-grub"
fi
grub-script-check "$GIM_GRUB_CFG" || die "grub-script-check failed on the new grub.cfg - restore with: sudo cp $BACKUP/files$GIM_GRUB_CFG $GIM_GRUB_CFG"
if grep -q 'grub_icon_menu\|gim_entries' "$GIM_GRUB_CFG"; then
    die "grub.cfg still references grub-icon-menu (another copy of the hook in /etc/grub.d?)"
fi
"$PROJECT_DIR/detect-os.sh" --cfg "$GIM_GRUB_CFG" -v >/dev/null 2>"$BACKUP/entries-after.txt" || true
log_info "menu entries after uninstall:"
sed 's/^/    /' "$BACKUP/entries-after.txt" >&2

echo
echo "grub-icon-menu removed. The standard GRUB menu is active again."
echo "Backup of the removed files: $BACKUP"
if [ "$osprober_disabled" = 1 ] && ! grep -qi 'chainloader.*bootmgfw\.efi' "$GIM_GRUB_CFG"; then
    echo
    echo "Windows: GRUB no longer lists it (grub-icon-menu had disabled os-prober). Start"
    echo "Windows from the firmware boot menu (F9 on HP laptops): BitLocker does not ask"
    echo "for the recovery key that way. Windows started from GRUB would ask for it."
    echo "To get a GRUB entry for Windows that does not ask for the key: install again"
    echo "(sudo ./install.sh), then sudo ./update.sh --plain for the plain text menu."
fi
