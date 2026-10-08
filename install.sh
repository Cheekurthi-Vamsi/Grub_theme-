#!/bin/bash
#
# install.sh - install grub-icon-menu: an icon-only GRUB boot menu for Ubuntu.
#
#   sudo ./install.sh [options]
#
# Options:
#   --resolution WxH   design the theme for this screen size
#                      (default: GRUB_GFXMODE if set, else the native panel mode)
#   --timeout N        seconds before the preselected icon boots (default 10,
#                      -1 = wait forever)
#   -rt, --remove-title  hide the ">_GRUB / BOOTMENU" title text
#   -bg, --background FILE  use this picture (JPEG, PNG, WebP, ...) instead of
#                      the white screen; it is cropped to fill the screen
#   --icon-color C     auto (default: black on light pictures, white on dark
#                      ones), black or white
#   --shadow S         soft shadow under icons and title: auto (default: on
#                      with a background picture), on or off
#   --windows-boot MODE  how the Windows icon starts Windows:
#                      firmware  (default) the UEFI firmware starts it: one-time
#                                BootNext + restart, so BitLocker does not ask
#                                for the recovery key
#                      chainload GRUB starts it (BitLocker asks for the key)
#   --no-os-prober     chainload mode: do not enable os-prober (Windows will not
#                      be detected unless GRUB already has an entry for it)
#   --os-prober        firmware mode: also find systems on other partitions
#                      without a boot entry of their own (Linux Mint, Zorin);
#                      Windows is skipped (it would ask for the BitLocker key)
#
# Other systems with their own UEFI boot entry (Kali, Fedora, Arch, ...) get
# an icon automatically (up to 6 icons; after installing one later, run
# sudo ./update.sh).
#   --dry-run          inspect and build everything in a temporary directory,
#                      print the GRUB script that would be added; change nothing
#   --yes              do not ask for confirmation
#
# Never reboots. Never touches the Windows bootloader, EFI variables, the ESP
# or partitions. (At boot, picking the Windows icon in firmware mode sets the
# one-time UEFI variable BootNext; the firmware deletes it when it uses it.)
# Every change is backed up first (~/grub-icon-menu-backup/).

set -Eeuo pipefail
PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$PROJECT_DIR/lib/common.sh"
# shellcheck source=lib/actions.sh
. "$PROJECT_DIR/lib/actions.sh"

RESOLUTION=""
TIMEOUT=10
OS_PROBER=auto
DRY_RUN=0
ORDER="windows linux"
TITLE=yes
WINDOWS_BOOT=firmware
BACKGROUND=""
ICON_COLOR=auto
SHADOW=auto

usage() { sed -n '3,40p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
while [ $# -gt 0 ]; do
    case "$1" in
        --resolution)   RESOLUTION="${2:-}"; shift 2 ;;
        --timeout)      TIMEOUT="${2:-}"; shift 2 ;;
        --no-os-prober) OS_PROBER=no; shift ;;
        --os-prober)    OS_PROBER=yes; shift ;;
        --windows-boot) WINDOWS_BOOT="${2:-}"; shift 2 ;;
        -rt|--remove-title) TITLE=no; shift ;;
        -bg|--background) BACKGROUND="${2:-}"; shift 2 ;;
        --icon-color)   ICON_COLOR="${2:-}"; shift 2 ;;
        --shadow)       SHADOW="${2:-}"; shift 2 ;;
        --dry-run)      DRY_RUN=1; shift ;;
        --yes|-y)       GIM_ASSUME_YES=1; shift ;;
        -h|--help)      usage 0 ;;
        *)              log_error "unknown option: $1"; usage 1 ;;
    esac
done
case "$TIMEOUT" in -1|[0-9]|[1-9][0-9]|[1-9][0-9][0-9]) ;; *) die "invalid --timeout '$TIMEOUT'" ;; esac
case "$RESOLUTION" in ""|[1-9][0-9]*x[1-9][0-9]*) ;; *) die "invalid --resolution '$RESOLUTION'" ;; esac
case "$WINDOWS_BOOT" in firmware|chainload) ;; *) die "invalid --windows-boot '$WINDOWS_BOOT' (firmware or chainload)" ;; esac
case "$ICON_COLOR" in auto|black|white) ;; *) die "invalid --icon-color '$ICON_COLOR' (auto, black or white)" ;; esac
case "$SHADOW" in auto|on|off) ;; *) die "invalid --shadow '$SHADOW' (auto, on or off)" ;; esac
if [ "$BACKGROUND" = none ]; then BACKGROUND=""; fi
if [ -n "$BACKGROUND" ]; then
    check_background "$BACKGROUND"
    BACKGROUND="$(realpath -e -- "$BACKGROUND")"
fi

[ "$DRY_RUN" = 1 ] || require_root
WORK="$(mktemp -d)"
INSTALLING=0
BACKUP=""
CREATED=()

# ---- rollback: any non-zero exit after the first change undoes everything ----
on_exit() {
    local rc=$?
    trap - EXIT
    if [ "$INSTALLING" = 1 ] && [ "$rc" != 0 ]; then
        log_error "installation failed - rolling back"
        if [ -f "$GIM_HOOK" ] && grep -q 'grub-icon-menu hook' "$GIM_HOOK"; then rm -f -- "$GIM_HOOK"; fi
        if [ -f "$GIM_DROPIN" ] && grep -q 'managed by grub-icon-menu' "$GIM_DROPIN"; then rm -f -- "$GIM_DROPIN"; fi
        if [ -f "$GIM_THEME_DIR/$GIM_MARKER" ]; then rm -r -- "$GIM_THEME_DIR"; fi
        if [ -n "$PREVIOUS_THEME" ] && [ -d "$PREVIOUS_THEME" ]; then mv -- "$PREVIOUS_THEME" "$GIM_THEME_DIR"; fi
        rmdir --ignore-fail-on-non-empty -- "$(dirname -- "$GIM_THEME_DIR")" 2>/dev/null || true
        if [ "${GRUB_REGENERATED:-0}" = 1 ]; then
            log_info "regenerating grub.cfg without grub-icon-menu"
            if ! regenerate_grub; then
                log_error "update-grub failed; restoring grub.cfg from the backup"
                copy_preserve "$BACKUP/files$GIM_GRUB_CFG" "$GIM_GRUB_CFG"
            fi
        fi
        log_error "previous state restored (backup: ${BACKUP:-none})"
    fi
    rm -rf -- "$WORK"
    exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT TERM

if [ "$DRY_RUN" = 0 ]; then
    GIM_LOG_FILE="$WORK/install.log"
    _log INFO "grub-icon-menu $GIM_VERSION install started: $0 $*"
fi

# ============================================================================
log_step "PHASE 1 - Inspect (read-only)"
# ============================================================================
require_cmd grub-mkconfig grub-script-check grub-probe grub-mkfont file fc-list awk sha256sum
command -v magick >/dev/null 2>&1 || command -v convert >/dev/null 2>&1 \
    || die "ImageMagick is required to render the theme: sudo apt install imagemagick"
if [ "$WINDOWS_BOOT" = firmware ]; then require_cmd python3 gzip; require_static_busybox; fi

eval "$("$PROJECT_DIR/scripts/detect-ubuntu.sh")"
[ "$UBUNTU" = 1 ] || die "this tool targets Ubuntu; /etc/os-release does not identify Ubuntu"
log_info "Ubuntu $UBUNTU_VERSION, GRUB $(grub_version), $(boot_mode) boot, Secure Boot: $(secure_boot_state)"
[ -f "$GIM_GRUB_CFG" ] || die "$GIM_GRUB_CFG not found - is GRUB the boot loader?"
log_info "kernels in /boot: $UBUNTU_KERNELS; EFI loader: ${UBUNTU_EFI_LOADER:-n/a}"

if [ -f "$GIM_HOOK" ] || [ -f "$GIM_DROPIN" ]; then
    die "grub-icon-menu is already installed - use: sudo ./update.sh (or ./uninstall.sh first)"
fi
if [ -e "$GIM_THEME_DIR" ] && [ ! -f "$GIM_THEME_DIR/$GIM_MARKER" ]; then
    die "$GIM_THEME_DIR exists and was not created by grub-icon-menu"
fi

terminal="$(grub_setting GRUB_TERMINAL_OUTPUT)"
[ -n "$terminal" ] || terminal="$(grub_setting GRUB_TERMINAL)"
case " ${terminal:-gfxterm} " in
    *" gfxterm "*) ;;
    *) die "GRUB_TERMINAL/GRUB_TERMINAL_OUTPUT is '$terminal': themes need the graphical terminal (gfxterm). Remove that setting from /etc/default/grub first." ;;
esac
old_theme="$(grub_setting GRUB_THEME)"
[ -z "$old_theme" ] || log_warn "GRUB_THEME is currently '$old_theme'; the drop-in overrides it (your file is not edited)"
log_info "GRUB_DEFAULT=$(grub_setting GRUB_DEFAULT) GRUB_TIMEOUT=$(grub_setting GRUB_TIMEOUT) GRUB_TIMEOUT_STYLE=$(grub_setting GRUB_TIMEOUT_STYLE)"

eval "$("$PROJECT_DIR/scripts/detect-windows.sh")"
grub_windows=0; grub_linux=0
if [ -r "$GIM_GRUB_CFG" ]; then
    detected="$("$PROJECT_DIR/detect-os.sh" --cfg "$GIM_GRUB_CFG" -v 2>"$WORK/entries.txt")"
    sed 's/^/    /' "$WORK/entries.txt" >&2
    printf '%s\n' "$detected" | grep -q '^WINDOWS=1$' && grub_windows=1
    printf '%s\n' "$detected" | grep -q '^LINUX=1$' && grub_linux=1
else
    log_warn "cannot read $GIM_GRUB_CFG (not root?) - skipping menu analysis"
fi
log_info "current GRUB menu: Windows entry: $grub_windows, Ubuntu entries: $grub_linux"
log_info "Windows Boot Manager on the ESP: ${WINDOWS_EFI_LOADER:-no}; in UEFI boot entries: $WINDOWS_FIRMWARE"

osprober_setting="$(grub_setting GRUB_DISABLE_OS_PROBER)"
enable_osprober=false
osprober_mode=keep
expect_windows=0
if [ "$WINDOWS_BOOT" = firmware ]; then
    # The Windows icon uses the firmware's own Windows Boot Manager entry. A
    # GRUB chainload entry would only be a way to get the recovery-key prompt.
    osprober_mode=disable
    log_info "Windows icon: started by the UEFI firmware (BootNext); os-prober will be disabled,"
    log_info "so GRUB has no chainload entry for Windows"
    if [ "$OS_PROBER" = yes ]; then
        command -v os-prober >/dev/null 2>&1 || die "os-prober is not installed: sudo apt install os-prober"
        osprober_skip_list || die "os-prober was not switched on (the Windows entry could not be excluded safely)"
        osprober_mode=skipwindows
        enable_osprober=true
        log_info "--os-prober: os-prober runs for other systems; skipped: $OSPROBER_SKIP"
    fi
    if [ "$WINDOWS_FIRMWARE" = 1 ]; then
        expect_windows=1
    elif [ -n "$WINDOWS_EFI_LOADER" ]; then
        log_warn "Windows Boot Manager is on the ESP but not in the UEFI boot entries: no Windows icon"
    fi
else
    if [ -n "$WINDOWS_EFI_LOADER" ] && [ "$OS_PROBER" != no ] && [ "$osprober_setting" != false ]; then
        if command -v os-prober >/dev/null 2>&1; then
            enable_osprober=true
            osprober_mode=enable
            log_info "os-prober is installed but not enabled (GRUB_DISABLE_OS_PROBER=${osprober_setting:-unset}); it will be enabled so GRUB can list Windows"
        else
            log_warn "Windows is present but os-prober is not installed: sudo apt install os-prober, then run update.sh"
        fi
    fi
    if [ -n "$WINDOWS_EFI_LOADER" ] && { [ "$enable_osprober" = true ] || [ "$osprober_setting" = false ] || [ "$grub_windows" = 1 ]; }; then
        expect_windows=1
    fi
    if [ "$WINDOWS_BITLOCKER" = 1 ]; then
        log_warn "BitLocker/Device Encryption is in use on Windows. Windows started from GRUB"
        log_warn "(--windows-boot chainload) asks for the BitLocker recovery key."
    fi
fi

RES="$(choose_resolution "$RESOLUTION")"
log_info "theme resolution: $RES (native panel: $(native_resolution || true))"

# ============================================================================
log_step "PHASE 2 - Plan"
# ============================================================================
cat >&2 <<EOF
    detection : grub.cfg entries -> classify (windows | linux | other)
                -> one icon per kind -> GRUB snippet at the end of grub.cfg
    files to create:
      $GIM_THEME_DIR/            theme, icons, chooser.cfg$( [ "$WINDOWS_BOOT" = firmware ] && printf ', handoff.img')
      $GIM_HOOK            detection hook run by update-grub
      $GIM_DROPIN   settings (GRUB_THEME, GRUB_GFXMODE$(case "$osprober_mode" in enable) printf ', os-prober on' ;; disable) printf ', os-prober off' ;; esac))
      $GIM_STATE_FILE
    files modified : $GIM_GRUB_CFG (regenerated by update-grub only)
    not touched    : /etc/default/grub, other /etc/grub.d scripts, the ESP,
                     EFI variables, Windows Boot Manager, partitions
    Windows icon   : $( [ "$WINDOWS_BOOT" = firmware ] && printf 'started by the UEFI firmware (sets the one-time BootNext\n                     variable, then restarts; no BitLocker recovery key)' || printf 'chainloaded by GRUB (BitLocker asks for the recovery key)')
    icon order     : $ORDER, timeout ${TIMEOUT}s, title text: $TITLE
    background     : ${BACKGROUND:-white}$( [ -n "$BACKGROUND" ] && printf ' (a copy is kept in %s.*)' "$GIM_BG_STORE")
    icon colour    : $ICON_COLOR, shadow: $SHADOW
    keys           : Up/Down move (wraps around Windows <-> Ubuntu), Enter boots, ESC full menu
EOF

# ============================================================================
log_step "PHASE 3/4 - Build and validate in a staging area"
# ============================================================================
build_theme "$RES" "$WORK/theme" "$ORDER" "$TITLE" "$WINDOWS_BOOT" "$BACKGROUND" "$ICON_COLOR" "$SHADOW"
bash -n "$PROJECT_DIR/grub.d/99_grub_icon_menu" || die "hook has shell syntax errors"

# Simulate the hook on the current grub.cfg with the staged theme.
if [ -r "$GIM_GRUB_CFG" ]; then
    mkdir -p "$WORK/etc/default/grub.d"
    printf 'GRUB_ICON_MENU_THEME_DIR=%q\nGRUB_ICON_MENU_TIMEOUT=%s\nGRUB_ICON_MENU_ORDER=%q\nGRUB_ICON_MENU_WINDOWS_BOOT=%s\n' \
        "$WORK/theme" "$TIMEOUT" "$ORDER" "$WINDOWS_BOOT" >"$WORK/etc/default/grub.d/99-test.cfg"
    {
        sed '/^### BEGIN \/etc\/grub.d\/99_grub_icon_menu ###$/,$d' "$GIM_GRUB_CFG"
        echo "### BEGIN /etc/grub.d/99_grub_icon_menu ###"
        GIM_INPUT_CFG="$GIM_GRUB_CFG" GIM_SYSCONFDIR="$WORK/etc" GIM_TEST_DEVICE_PREP="" \
            GIM_TEST_THEME_REL=/grub/themes/grub-icon-menu "$PROJECT_DIR/grub.d/99_grub_icon_menu"
        echo "### END /etc/grub.d/99_grub_icon_menu ###"
    } >"$WORK/simulated.cfg"
    grub-script-check "$WORK/simulated.cfg" || die "simulated grub.cfg has syntax errors"
    log_info "simulation on the current menu: OK (grub-script-check passed)"
fi

if [ "$DRY_RUN" = 1 ]; then
    log_step "Dry run finished - nothing was changed"
    log_info "theme preview files: $WORK/theme (deleted on exit); GRUB script that would be added:"
    if [ -f "$WORK/simulated.cfg" ]; then
        sed -n '/^### BEGIN \/etc\/grub.d\/99_grub_icon_menu ###$/,$p' "$WORK/simulated.cfg"
    fi
    exit 0
fi

confirm "Install grub-icon-menu now?" || die "aborted by user - nothing was changed"

# ============================================================================
log_step "PHASE 3 - Backup"
# ============================================================================
BACKUP="$(make_backup install)"
GIM_LOG_FILE="$BACKUP/install.log"
cat "$WORK/install.log" >>"$GIM_LOG_FILE" 2>/dev/null || true
log_info "backup: $BACKUP"

# ============================================================================
log_step "PHASE 6 - Install"
# ============================================================================
INSTALLING=1
install_theme "$WORK/theme";              CREATED+=("$GIM_THEME_DIR/")
install_hook;                             CREATED+=("$GIM_HOOK")
write_dropin "$RES" "$TIMEOUT" "$ORDER" "$osprober_mode" "$TITLE" "$WINDOWS_BOOT"; CREATED+=("$GIM_DROPIN")

# Trial run into a temporary file first: the real grub.cfg is only replaced
# once the complete generated configuration is known to be valid.
log_info "trial run of grub-mkconfig (output to a temporary file)"
run grub-mkconfig -o "$WORK/trial.cfg"
rc=0; validate_cfg "$WORK/trial.cfg" "$expect_windows" || rc=$?
[ "$rc" != 1 ] || false
log_info "trial configuration valid"

GRUB_REGENERATED=1
regenerate_grub
rc=0; validate_cfg "$GIM_GRUB_CFG" "$expect_windows" || rc=$?
[ "$rc" != 1 ] || false

# Icons for the other systems that were found (Kali, Linux Mint, ...).
new_kinds="$(kinds_without_icon)"
if [ -n "$new_kinds" ]; then
    new_order="$(order_with "$ORDER" "$new_kinds")"
    if [ "$new_order" != "$ORDER" ]; then
        log_step "Other systems found: $new_kinds - adding their icons"
        ORDER="$new_order"
        build_theme "$RES" "$WORK/theme2" "$ORDER" "$TITLE" "$WINDOWS_BOOT" "$BACKGROUND" "$ICON_COLOR" "$SHADOW"
        install_theme "$WORK/theme2" again
        write_dropin "$RES" "$TIMEOUT" "$ORDER" "$osprober_mode" "$TITLE" "$WINDOWS_BOOT"
        regenerate_grub
        rc=0; validate_cfg "$GIM_GRUB_CFG" "$expect_windows" || rc=$?
        [ "$rc" != 1 ] || false
    fi
fi
INSTALLING=0
drop_previous_theme

store_background "$BACKGROUND"
state_write "VERSION=$GIM_VERSION" "INSTALLED=$(date -Iseconds)" "BACKUP=$BACKUP" \
    "RESOLUTION=$RES" "ORDER=$ORDER" "TIMEOUT=$TIMEOUT" "OS_PROBER_ENABLED=$enable_osprober" \
    "WINDOWS_BOOT=$WINDOWS_BOOT" "BACKGROUND=$(stored_background || echo none)" \
    "ICON_COLOR=$ICON_COLOR" "SHADOW=$SHADOW" "OS_PROBER=$enable_osprober"
CREATED+=("$GIM_STATE_FILE")
if [ -n "$BACKGROUND" ]; then CREATED+=("$(stored_background)"); fi

{
    echo "grub-icon-menu install - $(date -Iseconds)"
    echo "created:";  printf '  %s\n' "${CREATED[@]}"
    echo "modified:"; echo "  $GIM_GRUB_CFG (regenerated by update-grub)"
    echo "detected:"; echo "  ${VALIDATED_KINDS:-none}"
} >"$BACKUP/CHANGES.txt"

# ============================================================================
log_step "PHASE 8 - Report"
# ============================================================================
cat >&2 <<EOF
    detected operating systems : ${VALIDATED_KINDS:-none}
    icons                      : ${ORDER} (windows -> Windows logo, linux = this Ubuntu -> Tux)
    background                 : ${BACKGROUND:-white}, icons $(sed -n 's/^FOREGROUND=//p' "$GIM_THEME_DIR/$GIM_MARKER")
    Windows icon               : $( [ "$WINDOWS_BOOT" = firmware ] && echo "started by the UEFI firmware (no BitLocker prompt)" || echo "chainloaded by GRUB")
    backup                     : $BACKUP
    log                        : $BACKUP/install.log
    update later               : sudo $PROJECT_DIR/update.sh
    uninstall                  : sudo $PROJECT_DIR/uninstall.sh
    restore backup             : sudo $BACKUP/restore.sh $BACKUP
    in the menu                : Up/Down select, Enter boots, ESC = full menu
EOF
if [ -z "$VALIDATED_KINDS" ]; then
    log_warn "no Windows/Ubuntu entries were recognised: GRUB keeps showing the standard menu"
fi
echo
echo "Installation completed successfully."
echo "Reboot manually to test the GRUB menu."
