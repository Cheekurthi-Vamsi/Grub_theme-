#!/bin/bash
#
# update.sh - re-detect operating systems and refresh grub-icon-menu.
#
#   sudo ./update.sh [--resolution WxH] [--timeout N] [-rt | --show-title]
#                    [-bg FILE | -bg none] [--icon-color auto|black|white]
#                    [--shadow auto|on|off] [--plain | --icons]
#                    [--os-prober | --no-os-prober]
#                    [--windows-boot firmware|chainload] [--rebuild] [--yes]
#
#   -bg FILE      new background picture (-bg none: white screen again)
#   --icon-color  auto: black on light pictures, white on dark ones
#   --shadow      soft shadow under icons and title (auto: with a picture)
#   --plain       plain text menu instead of icons; Windows keeps its entry
#                 that does not ask for the BitLocker key (--icons: back)
#   --os-prober   also find systems on other partitions that have no boot
#                 entry of their own (Linux Mint, Zorin, elementary share
#                 Ubuntu's); Windows stays BitLocker-safe (--no-os-prober: off)
#
# Other systems (Kali, Fedora, Arch, ...) are found automatically: after
# installing one, run this script and it gets its icon (up to 6 icons).
#
# 1. reports the operating systems found (ESP / firmware / GRUB menu)
# 2. rebuilds the theme when needed: other resolution, background, colours,
#    new version of this tool, missing or invalid icons, outdated
#    handoff.img, or --rebuild
# 3. refreshes the hook and the settings drop-in
# 4. runs update-grub and validates the generated grub.cfg
#
# Settings not given keep their current value.
# Run it after adding/removing an operating system or changing the screen.
# (Kernel updates need nothing: update-grub runs the hook automatically.)

set -Eeuo pipefail
PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$PROJECT_DIR/lib/common.sh"
# shellcheck source=lib/actions.sh
. "$PROJECT_DIR/lib/actions.sh"

RESOLUTION=""
TIMEOUT=""
REBUILD=0
TITLE=""
WINDOWS_BOOT=""
BACKGROUND=""             # "" = keep, none = remove, else a picture file
ICON_COLOR=""
SHADOW=""
ICON_MENU=""
OS_PROBER=""
usage() { sed -n '3,32p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
while [ $# -gt 0 ]; do
    case "$1" in
        --resolution) RESOLUTION="${2:-}"; shift 2 ;;
        --timeout)    TIMEOUT="${2:-}"; shift 2 ;;
        --rebuild)    REBUILD=1; shift ;;
        -rt|--remove-title) TITLE=no; shift ;;
        --show-title) TITLE=yes; shift ;;
        --windows-boot) WINDOWS_BOOT="${2:-}"; shift 2 ;;
        -bg|--background) BACKGROUND="${2:-}"; [ -n "$BACKGROUND" ] || die "-bg needs a file (or none)"; shift 2 ;;
        --no-background) BACKGROUND=none; shift ;;
        --icon-color) ICON_COLOR="${2:-}"; shift 2 ;;
        --shadow)     SHADOW="${2:-}"; shift 2 ;;
        --plain)      ICON_MENU=false; shift ;;
        --icons)      ICON_MENU=true; shift ;;
        --os-prober)  OS_PROBER=true; shift ;;
        --no-os-prober) OS_PROBER=false; shift ;;
        --yes|-y)     GIM_ASSUME_YES=1; shift ;;
        -h|--help)    usage 0 ;;
        *)            log_error "unknown option: $1"; usage 1 ;;
    esac
done
case "$TIMEOUT" in ""|-1|[0-9]|[1-9][0-9]|[1-9][0-9][0-9]) ;; *) die "invalid --timeout '$TIMEOUT'" ;; esac
case "$RESOLUTION" in ""|[1-9][0-9]*x[1-9][0-9]*) ;; *) die "invalid --resolution '$RESOLUTION'" ;; esac
case "$WINDOWS_BOOT" in ""|firmware|chainload) ;; *) die "invalid --windows-boot '$WINDOWS_BOOT' (firmware or chainload)" ;; esac
case "$ICON_COLOR" in ""|auto|black|white) ;; *) die "invalid --icon-color '$ICON_COLOR' (auto, black or white)" ;; esac
case "$SHADOW" in ""|auto|on|off) ;; *) die "invalid --shadow '$SHADOW' (auto, on or off)" ;; esac
if [ -n "$BACKGROUND" ] && [ "$BACKGROUND" != none ]; then
    check_background "$BACKGROUND"
    BACKGROUND="$(realpath -e -- "$BACKGROUND")"
fi

require_root
[ -f "$GIM_HOOK" ] && [ -f "$GIM_DROPIN" ] && [ -f "$GIM_THEME_DIR/$GIM_MARKER" ] \
    || die "grub-icon-menu is not (completely) installed - run: sudo ./install.sh"
require_cmd grub-mkconfig grub-script-check grub-mkfont file fc-list

WORK="$(mktemp -d)"
UPDATING=0
BACKUP=""
on_exit() {
    local rc=$?
    trap - EXIT
    if [ "$UPDATING" = 1 ] && [ "$rc" != 0 ]; then
        log_error "update failed - restoring the previous installation"
        copy_preserve "$BACKUP/files$GIM_HOOK" "$GIM_HOOK" 2>/dev/null || true
        copy_preserve "$BACKUP/files$GIM_DROPIN" "$GIM_DROPIN" 2>/dev/null || true
        if [ -n "$PREVIOUS_THEME" ] && [ -d "$PREVIOUS_THEME" ]; then
            [ -f "$GIM_THEME_DIR/$GIM_MARKER" ] && rm -r -- "$GIM_THEME_DIR"
            mv -- "$PREVIOUS_THEME" "$GIM_THEME_DIR"
        fi
        # The snapshot's grub.cfg is exactly the state before this update
        # (regenerating could differ, e.g. when os-prober now finds more).
        if [ -f "$BACKUP/files$GIM_GRUB_CFG" ]; then
            copy_preserve "$BACKUP/files$GIM_GRUB_CFG" "$GIM_GRUB_CFG"
        else
            regenerate_grub || true
        fi
        log_error "previous installation restored (backup: $BACKUP)"
    fi
    rm -rf -- "$WORK"
    exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT TERM

marker_get() { sed -n "s/^$1=//p" "$GIM_THEME_DIR/$GIM_MARKER" | tail -n1; }

# ---- 1. detection report ----------------------------------------------------
log_step "Detecting operating systems"
eval "$("$PROJECT_DIR/scripts/detect-windows.sh")"
eval "$("$PROJECT_DIR/scripts/detect-ubuntu.sh")"
log_info "ESP: Windows Boot Manager ${WINDOWS_EFI_LOADER:-not found}; Ubuntu kernels in /boot: $UBUNTU_KERNELS"
"$PROJECT_DIR/detect-os.sh" --cfg "$GIM_GRUB_CFG" -v >/dev/null 2>"$WORK/entries.txt" || true
sed 's/^/    /' "$WORK/entries.txt" >&2
os_prober_enabled="$(state_get OS_PROBER_ENABLED || echo false)"
# Installations from before 1.1.0 have no setting: they move to firmware.
windows_boot="${WINDOWS_BOOT:-$(grub_setting GRUB_ICON_MENU_WINDOWS_BOOT)}"
windows_boot="${windows_boot:-firmware}"
expect_windows=0
if [ "$windows_boot" = firmware ]; then
    require_static_busybox
    # No GRUB chainload entry: it would only lead to the recovery-key prompt.
    # With --os-prober, os-prober runs for the other systems and skips Windows.
    os_prober_setting="${OS_PROBER:-$(grub_setting GRUB_ICON_MENU_OS_PROBER)}"
    if [ "$os_prober_setting" = true ]; then
        command -v os-prober >/dev/null 2>&1 || die "os-prober is not installed: sudo apt install os-prober"
        osprober_skip_list || die "os-prober was not switched on (the Windows entry could not be excluded safely)"
        osprober_mode=skipwindows
        os_prober_enabled=true
        log_info "os-prober: on for other systems; skipped: $OSPROBER_SKIP"
    else
        osprober_mode=disable
        os_prober_enabled=false
    fi
    [ "$WINDOWS_FIRMWARE" = 1 ] && expect_windows=1
    if [ -n "$WINDOWS_EFI_LOADER" ] && [ "$expect_windows" = 0 ]; then
        log_warn "Windows Boot Manager is on the ESP but not in the UEFI boot entries: it will not get an icon"
    fi
else
    osprober_after="$(grub_setting_without_dropin GRUB_DISABLE_OS_PROBER)"
    # Chainloading needs os-prober's entry (e.g. after switching from firmware).
    if [ -n "$WINDOWS_EFI_LOADER" ] && [ "$osprober_after" != false ] && command -v os-prober >/dev/null 2>&1; then
        os_prober_enabled=true
    fi
    if [ "$os_prober_enabled" = true ]; then osprober_mode=enable; osprober_after=false; else osprober_mode=keep; fi
    if [ -n "$WINDOWS_EFI_LOADER" ] && [ "$osprober_after" = false ]; then expect_windows=1; fi
    if [ -n "$WINDOWS_EFI_LOADER" ] && [ "$expect_windows" = 0 ]; then
        log_warn "Windows is on the ESP but os-prober is disabled: it will not get an icon"
    fi
fi

# ---- 2. what needs refreshing --------------------------------------------------
cur_res="$(marker_get RESOLUTION)"
order="$(marker_get ORDER)"; order="${order:-windows linux}"
res="${RESOLUTION:-$cur_res}"
timeout="${TIMEOUT:-$(grub_setting GRUB_ICON_MENU_TIMEOUT)}"; timeout="${timeout:-10}"

cur_title="$(marker_get TITLE)"; cur_title="${cur_title:-yes}"
title="${TITLE:-$cur_title}"

# Background: the new picture, none, or the kept copy of the current one (if
# that copy is gone, the installed background.png, which has the screen size).
cur_bg="$(marker_get BACKGROUND)"; cur_bg="${cur_bg:-none}"
case "$BACKGROUND" in
    none) bg_src="" ;;
    "")   bg_src="$(stored_background || true)"
          if [ -z "$bg_src" ] && [ "$cur_bg" != none ] && [ -f "$GIM_THEME_DIR/background.png" ]; then
              cp -- "$GIM_THEME_DIR/background.png" "$WORK/background.png"
              bg_src="$WORK/background.png"
              log_warn "the kept copy of the background picture is missing; using the installed one"
          fi ;;
    *)    bg_src="$BACKGROUND" ;;
esac
new_bg=none
if [ -n "$bg_src" ]; then new_bg="$(sha256sum <"$bg_src" | cut -c1-64)"; fi
cur_icon_color="$(marker_get ICON_COLOR)"; cur_icon_color="${cur_icon_color:-auto}"
icon_color="${ICON_COLOR:-$cur_icon_color}"
cur_shadow="$(marker_get SHADOW)"; cur_shadow="${cur_shadow:-auto}"
shadow="${SHADOW:-$cur_shadow}"
icon_menu="${ICON_MENU:-$(grub_setting GRUB_ICON_MENU)}"
case "$icon_menu" in false|0|no) icon_menu=false; menu_mode=plain ;; *) icon_menu=true; menu_mode=icons ;; esac

reasons=()
[ "$REBUILD" = 1 ] && reasons+=("--rebuild")
[ "$title" != "$cur_title" ] && reasons+=("title text $cur_title -> $title")
[ "$res" != "$cur_res" ] && reasons+=("resolution $cur_res -> $res")
[ "$new_bg" != "$cur_bg" ] && reasons+=("background $( [ "$new_bg" = none ] && echo removed || echo "${bg_src##*/}")")
[ "$icon_color" != "$cur_icon_color" ] && reasons+=("icon colour $cur_icon_color -> $icon_color")
[ "$shadow" != "$cur_shadow" ] && reasons+=("shadow $cur_shadow -> $shadow")
[ "$(marker_get VERSION)" != "$GIM_VERSION" ] && reasons+=("version $(marker_get VERSION) -> $GIM_VERSION")
for layout in $(marker_get LAYOUTS); do
    n=$(( $(printf '%s' "$layout" | tr -cd '-' | wc -c) + 1 ))
    for (( i = 0; i < n; i++ )); do
        png_ok "$GIM_THEME_DIR/icons/gim-$layout-$i.png" || { reasons+=("icon gim-$layout-$i.png missing/invalid"); break 2; }
    done
done
for f in icon-menu.txt theme.txt chooser.cfg title.png; do
    [ -s "$GIM_THEME_DIR/$f" ] || reasons+=("$f missing")
done
if [ "$windows_boot" = firmware ]; then
    # Reproducible build: any difference means handoff/init or busybox changed.
    "$PROJECT_DIR/scripts/build-handoff.sh" --out "$WORK/handoff.img" || die "building handoff.img failed"
    if [ ! -f "$GIM_THEME_DIR/handoff.img" ]; then
        reasons+=("handoff.img missing (Windows through the firmware)")
    elif ! cmp -s "$WORK/handoff.img" "$GIM_THEME_DIR/handoff.img"; then
        reasons+=("handoff.img outdated")
    fi
fi
hook_changed=0; cmp -s "$PROJECT_DIR/grub.d/99_grub_icon_menu" "$GIM_HOOK" || hook_changed=1

log_step "Plan"
if [ "${#reasons[@]}" -gt 0 ]; then
    log_info "rebuild theme for $res: ${reasons[*]}"
else
    log_info "theme up to date ($cur_res)"
fi
[ "$hook_changed" = 1 ] && log_info "hook will be updated to this version"
log_info "settings: timeout ${timeout}s, resolution $res, os-prober: $osprober_mode"
log_info "look: background ${bg_src:+${bg_src##*/}}${bg_src:-white}, icon colour $icon_color, shadow $shadow, menu: $menu_mode"
if [ "$windows_boot" = firmware ]; then
    log_info "Windows icon: started by the UEFI firmware (one-time BootNext + restart, no BitLocker prompt)"
else
    log_info "Windows icon: chainloaded by GRUB (BitLocker asks for the recovery key)"
fi
confirm "Update grub-icon-menu and regenerate grub.cfg?" || die "aborted - nothing was changed"

if [ "${#reasons[@]}" -gt 0 ]; then
    build_theme "$res" "$WORK/theme" "$order" "$title" "$windows_boot" "$bg_src" "$icon_color" "$shadow"
fi

# ---- 3. apply ---------------------------------------------------------------------
BACKUP="$(make_backup update)"
GIM_LOG_FILE="$BACKUP/update.log"
log_info "backup: $BACKUP"
UPDATING=1
if [ "${#reasons[@]}" -gt 0 ]; then install_theme "$WORK/theme"; fi
if [ "$hook_changed" = 1 ]; then install_hook; fi
write_dropin "$res" "$timeout" "$order" "$osprober_mode" "$title" "$windows_boot" "$icon_menu"

# ---- 4. regenerate and validate ------------------------------------------------------
regenerate_grub
rc=0; validate_cfg "$GIM_GRUB_CFG" "$expect_windows" "$menu_mode" || rc=$?
[ "$rc" != 1 ] || false

# ---- 5. icons for newly found systems (Kali, Linux Mint, ...) ---------------------
if [ "$menu_mode" = icons ]; then
    new_kinds="$(kinds_without_icon)"
    if [ -n "$new_kinds" ]; then
        new_order="$(order_with "$order" "$new_kinds")"
        if [ "$new_order" != "$order" ]; then
            log_step "New systems found: $new_kinds - adding their icons"
            order="$new_order"
            build_theme "$res" "$WORK/theme2" "$order" "$title" "$windows_boot" "$bg_src" "$icon_color" "$shadow"
            if [ "${#reasons[@]}" -gt 0 ]; then install_theme "$WORK/theme2" again; else install_theme "$WORK/theme2"; fi
            write_dropin "$res" "$timeout" "$order" "$osprober_mode" "$title" "$windows_boot" "$icon_menu"
            regenerate_grub
            rc=0; validate_cfg "$GIM_GRUB_CFG" "$expect_windows" "$menu_mode" || rc=$?
            [ "$rc" != 1 ] || false
        fi
    fi
fi
UPDATING=0
drop_previous_theme
store_background "$bg_src"
state_write "VERSION=$GIM_VERSION" "INSTALLED=$(state_get INSTALLED || true)" "UPDATED=$(date -Iseconds)" \
    "BACKUP=$BACKUP" "RESOLUTION=$res" "ORDER=$order" "TIMEOUT=$timeout" "OS_PROBER_ENABLED=$os_prober_enabled" \
    "WINDOWS_BOOT=$windows_boot" "BACKGROUND=$(stored_background || echo none)" \
    "ICON_COLOR=$icon_color" "SHADOW=$shadow" "ICON_MENU=$icon_menu" "OS_PROBER=$os_prober_enabled"

echo
echo "Update completed successfully: ${VALIDATED_KINDS:-no supported entries} detected."
echo "Reboot manually to see the result."
