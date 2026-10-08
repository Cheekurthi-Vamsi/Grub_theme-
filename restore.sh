#!/bin/bash
#
# restore.sh - put the GRUB configuration back exactly as it was in a backup.
#
#   sudo ./restore.sh BACKUP_DIR [--yes]
#   sudo ~/grub-icon-menu-backup/<snapshot>/restore.sh ~/grub-icon-menu-backup/<snapshot>
#
# Every snapshot contains a copy of this script and lib/common.sh, so a
# restore does not depend on the grub-icon-menu repository.
#
# Restores (after showing the differences and asking):
#   /etc/default/grub, /etc/default/grub.d/*, /etc/grub.d/*
#   /boot/grub/themes/grub-icon-menu (removed if it was not in the snapshot)
# then regenerates /boot/grub/grub.cfg with update-grub. If update-grub
# fails, the snapshot's grub.cfg is copied back instead.
#
# Never restored or modified: the EFI System Partition, EFI variables,
# /boot/grub/grubenv (boot-time state) and kernels.

set -Eeuo pipefail
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SELF_DIR/lib/common.sh"

SNAP=""
while [ $# -gt 0 ]; do
    case "$1" in
        --yes|-y)  GIM_ASSUME_YES=1; shift ;;
        -h|--help) sed -n '3,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)        die "unknown option: $1" ;;
        *)         SNAP="$1"; shift ;;
    esac
done
[ -n "$SNAP" ] || die "usage: sudo $0 BACKUP_DIR"
SNAP="$(cd -- "$SNAP" && pwd)"
require_root
[ -f "$SNAP/MANIFEST.txt" ] && [ -d "$SNAP/files" ] && [ -f "$SNAP/SHA256SUMS" ] \
    || die "$SNAP is not a grub-icon-menu backup snapshot"
F="$SNAP/files"

log_step "Verifying the snapshot"
(cd "$F" && sha256sum --quiet -c "$SNAP/SHA256SUMS") || die "snapshot is damaged (checksum mismatch) - not restoring"
sed -n '1,9p' "$SNAP/MANIFEST.txt" | sed 's/^/    /' >&2

# ---- plan --------------------------------------------------------------------
copy_back=()   # files to restore from the snapshot
remove=()      # files of ours that did not exist in the snapshot
keep=()        # files that appeared later and are not ours (left alone)

plan_dir() {   # plan_dir /etc/grub.d
    local dir="$1" f rel
    if [ -d "$F$dir" ]; then
        while IFS= read -r -d '' f; do
            rel="${f#"$F"}"
            cmp -s -- "$f" "$rel" 2>/dev/null || copy_back+=("$rel")
        done < <(find "$F$dir" -mindepth 1 -maxdepth 1 -type f -print0)
    fi
    if [ -d "$dir" ]; then
        while IFS= read -r -d '' f; do
            [ -e "$F$f" ] && continue
            case "$f" in
                "$GIM_HOOK"|"$GIM_DROPIN") remove+=("$f") ;;
                *) keep+=("$f") ;;
            esac
        done < <(find "$dir" -mindepth 1 -maxdepth 1 -type f -print0)
    fi
}
if [ -f "$F/etc/default/grub" ] && ! cmp -s "$F/etc/default/grub" /etc/default/grub; then
    copy_back+=(/etc/default/grub)
fi
plan_dir /etc/default/grub.d
plan_dir /etc/grub.d

theme_action="none"
if [ -d "$F$GIM_THEME_DIR" ]; then
    theme_action="restore"
elif [ -f "$GIM_THEME_DIR/$GIM_MARKER" ]; then
    theme_action="remove"
fi

log_step "Restore plan"
for f in "${copy_back[@]}"; do
    echo "    restore  $f" >&2
    if [ -f "$f" ] && [ -f "$F$f" ]; then diff -u -- "$f" "$F$f" | sed -n '3,40p' | sed 's/^/             /' >&2 || true; fi
done
for f in "${remove[@]}"; do echo "    remove   $f (added by grub-icon-menu)" >&2; done
for f in "${keep[@]}"; do echo "    keep     $f (created after the snapshot, not by grub-icon-menu)" >&2; done
echo "    theme    $GIM_THEME_DIR: $theme_action" >&2
echo "    then     update-grub" >&2
if [ "${#copy_back[@]}" -eq 0 ] && [ "${#remove[@]}" -eq 0 ] && [ "$theme_action" = none ]; then
    log_info "configuration already matches the snapshot"
fi
confirm "Restore this snapshot?" || die "aborted - nothing was changed"

# ---- apply --------------------------------------------------------------------
log_step "Restoring"
for f in "${copy_back[@]}"; do
    run copy_preserve "$F$f" "$f"
done
for f in "${remove[@]}"; do
    run rm -f -- "$f"
done
case "$theme_action" in
    restore)
        if [ -e "$GIM_THEME_DIR" ]; then
            [ -f "$GIM_THEME_DIR/$GIM_MARKER" ] || die "$GIM_THEME_DIR is not ours - not replacing it"
            run rm -r -- "$GIM_THEME_DIR"
        fi
        run copy_preserve "$F$GIM_THEME_DIR" "$GIM_THEME_DIR" ;;
    remove)
        run rm -r -- "$GIM_THEME_DIR" ;;
esac
if [ ! -f "$GIM_HOOK" ] && [ -d "$GIM_STATE_DIR" ]; then
    rm -f -- "$GIM_STATE_FILE" "$GIM_STATE_DIR"/background.*; rmdir -- "$GIM_STATE_DIR" 2>/dev/null || true
fi

log_step "Regenerating grub.cfg"
if regenerate_grub && grub-script-check "$GIM_GRUB_CFG"; then
    log_info "grub.cfg regenerated"
else
    log_error "update-grub failed"
    if [ -f "$F$GIM_GRUB_CFG" ] && confirm "Copy the snapshot's grub.cfg back instead?"; then
        run copy_preserve "$F$GIM_GRUB_CFG" "$GIM_GRUB_CFG"
        grub-script-check "$GIM_GRUB_CFG" && log_info "snapshot grub.cfg restored"
    else
        die "grub.cfg was not regenerated - fix the error above and run: sudo update-grub"
    fi
fi

echo
echo "Restore completed. Reboot manually when ready."
