# shellcheck shell=bash
#
# grub-icon-menu - shared helpers for install.sh, update.sh, uninstall.sh,
# restore.sh and the scripts in scripts/. Source it; do not execute it.

GIM_VERSION="1.3.0"

# ---- installed locations (fixed, so uninstall never has to guess) ----------
GIM_THEME_DIR="/boot/grub/themes/grub-icon-menu"
GIM_HOOK="/etc/grub.d/99_grub_icon_menu"
GIM_DROPIN="/etc/default/grub.d/99-grub-icon-menu.cfg"
GIM_STATE_DIR="/var/lib/grub-icon-menu"
GIM_STATE_FILE="$GIM_STATE_DIR/state"
# Copy of the --background picture (background.<ext>), kept so the theme can
# be rebuilt later (new resolution, new version) even if the original moved.
GIM_BG_STORE="$GIM_STATE_DIR/background"
GIM_MARKER=".grub-icon-menu"            # identifies a theme dir we created
GIM_GRUB_CFG="/boot/grub/grub.cfg"
GIM_BACKUP_DIRNAME="grub-icon-menu-backup"

# ---- logging ----------------------------------------------------------------
if [ -t 2 ]; then
    _c_red=$'\033[31m'; _c_yel=$'\033[33m'; _c_grn=$'\033[32m'; _c_dim=$'\033[2m'; _c_off=$'\033[0m'
else
    _c_red=""; _c_yel=""; _c_grn=""; _c_dim=""; _c_off=""
fi
GIM_LOG_FILE="${GIM_LOG_FILE:-}"

_log() {
    local level="$1"; shift
    if [ -n "$GIM_LOG_FILE" ]; then
        printf '%s [%s] %s\n' "$(date '+%F %T')" "$level" "$*" >>"$GIM_LOG_FILE" 2>/dev/null || true
    fi
}
log_info()  { _log INFO "$@";  printf '%s\n' "$*" >&2; }
log_step()  { _log STEP "$@";  printf '\n%s==> %s%s\n' "$_c_grn" "$*" "$_c_off" >&2; }
log_warn()  { _log WARN "$@";  printf '%sWARNING:%s %s\n' "$_c_yel" "$_c_off" "$*" >&2; }
log_error() { _log ERROR "$@"; printf '%sERROR:%s %s\n' "$_c_red" "$_c_off" "$*" >&2; }
log_detail(){ _log INFO "$@";  printf '%s    %s%s\n' "$_c_dim" "$*" "$_c_off" >&2; }
die()       { log_error "$@"; exit 1; }

# Run a command, logging it (the "commands executed" record of the report).
run() {
    _log CMD "$*"
    printf '%s    $ %s%s\n' "$_c_dim" "$*" "$_c_off" >&2
    "$@"
}

# ---- preconditions ------------------------------------------------------------
require_root() {
    [ "$(id -u)" -eq 0 ] || die "this script must be run as root (sudo $0)"
}

require_cmd() {
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
    done
}

# Interactive yes/no; GIM_ASSUME_YES=1 answers yes.
confirm() {
    if [ "${GIM_ASSUME_YES:-0}" = 1 ]; then return 0; fi
    if [ ! -t 0 ]; then
        log_error "no terminal to ask for confirmation; re-run with --yes"
        return 1
    fi
    local answer
    printf '%s [y/N] ' "$1" >&2
    read -r answer || return 1
    case "$answer" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

# Home directory of the user who invoked sudo (backups go there).
invoking_home() {
    local user="${SUDO_USER:-}"
    if [ -n "$user" ] && [ "$user" != root ]; then
        getent passwd "$user" | cut -d: -f6
    else
        printf '%s\n' "${HOME:-/root}"
    fi
}

# ---- GRUB configuration ---------------------------------------------------------

# Effective value of a /etc/default/grub setting: sourced exactly like
# grub-mkconfig does (/etc/default/grub, then /etc/default/grub.d/*.cfg).
grub_setting() {
    local var="$1"
    (
        set +eu
        if [ -f /etc/default/grub ]; then . /etc/default/grub >/dev/null 2>&1; fi
        for f in /etc/default/grub.d/*.cfg; do
            if [ -e "$f" ]; then . "$f" >/dev/null 2>&1; fi
        done
        printf '%s' "${!var-}"
    )
}

# Same as grub_setting but ignoring our own drop-in, i.e. the value the
# system had before grub-icon-menu was installed.
grub_setting_without_dropin() {
    local var="$1"
    (
        set +eu
        if [ -f /etc/default/grub ]; then . /etc/default/grub >/dev/null 2>&1; fi
        for f in /etc/default/grub.d/*.cfg; do
            [ "$f" = "$GIM_DROPIN" ] && continue
            if [ -e "$f" ]; then . "$f" >/dev/null 2>&1; fi
        done
        printf '%s' "${!var-}"
    )
}

grub_version() {
    grub-install --version 2>/dev/null | sed -n 's/.*(GRUB) *//p' | head -n1
}

boot_mode() {
    if [ -d /sys/firmware/efi ]; then echo UEFI; else echo BIOS; fi
}

secure_boot_state() {
    if command -v mokutil >/dev/null 2>&1; then
        mokutil --sb-state 2>/dev/null | head -n1
    else
        echo "unknown (mokutil not installed)"
    fi
}

# Mount point of the EFI System Partition, without hard-coding /boot/efi.
find_esp() {
    local t
    for t in /boot/efi /efi /boot; do
        if mountpoint -q "$t" 2>/dev/null && [ -d "$t/EFI" ]; then
            printf '%s\n' "$t"; return 0
        fi
    done
    # Any mounted vfat filesystem with an EFI directory.
    findmnt -rn -t vfat -o TARGET 2>/dev/null | while read -r t; do
        if [ -d "$t/EFI" ]; then printf '%s\n' "$t"; break; fi
    done
}

# Regenerate grub.cfg the Ubuntu way.
regenerate_grub() {
    if command -v update-grub >/dev/null 2>&1; then
        run update-grub
    else
        run grub-mkconfig -o "$GIM_GRUB_CFG"
    fi
}

# Copy keeping mode, timestamps and symlinks (not ownership: every file
# handled here belongs to root, and preserving owners can fail needlessly).
copy_preserve() {
    cp -R --no-dereference --preserve=mode,timestamps,links -- "$1" "$2"
}

# ---- image checks ------------------------------------------------------------------

# A PNG GRUB can load: 8-bit RGBA, not interlaced. Optional exact size.
png_ok() {
    local f="$1" w="${2:-}" h="${3:-}" info
    [ -s "$f" ] || return 1
    info="$(file -b "$f" 2>/dev/null)" || return 1
    case "$info" in
        "PNG image data, "*", 8-bit/color RGBA, non-interlaced") ;;
        *) return 1 ;;
    esac
    if [ -n "$w" ]; then
        case "$info" in *", $w x $h,"*) ;; *) return 1 ;; esac
    fi
    return 0
}

# ---- state ----------------------------------------------------------------------------
state_get() {
    [ -f "$GIM_STATE_FILE" ] || return 1
    sed -n "s/^$1=//p" "$GIM_STATE_FILE" | tail -n1
}

state_write() {
    # state_write KEY=VALUE ... (replaces the file)
    install -d -m 0755 "$GIM_STATE_DIR"
    local tmp
    tmp="$(mktemp "$GIM_STATE_DIR/.state.XXXXXX")"
    printf '%s\n' "$@" >"$tmp"
    chmod 0644 "$tmp"
    mv -f "$tmp" "$GIM_STATE_FILE"
}
