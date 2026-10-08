# shellcheck shell=bash
#
# grub-icon-menu - building blocks shared by install.sh and update.sh:
# backup snapshots, theme build/installation, configuration, validation and
# rollback. Requires lib/common.sh to be sourced first.

# ---------------------------------------------------------------------------
# Backup
# ---------------------------------------------------------------------------

# make_backup LABEL -> prints the snapshot directory
#
# Snapshot layout:
#   files/etc/default/grub, files/etc/default/grub.d/, files/etc/grub.d/,
#   files/boot/grub/                (everything, incl. grub.cfg and themes)
#   files/<esp>/EFI/ubuntu/         (read-only copy; never restored)
#   MANIFEST.txt  SHA256SUMS  system-info.txt  efibootmgr.txt
#   restore.sh + lib/common.sh      (restore works without this repository)
make_backup() {
    local label="$1" root dir esp p
    root="$(invoking_home)/$GIM_BACKUP_DIRNAME"
    dir="$root/$(date '+%Y%m%d-%H%M%S')-$label"
    install -d -m 0755 "$root"
    if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != root ]; then
        chown "$SUDO_USER": "$root" 2>/dev/null || true
    fi
    [ ! -e "$dir" ] || die "backup directory already exists: $dir"
    install -d -m 0700 "$dir" "$dir/files"

    esp="$(find_esp || true)"
    local paths=(/etc/default/grub /etc/default/grub.d /etc/grub.d /boot/grub)
    if [ -n "$esp" ] && [ -d "$esp/EFI/ubuntu" ]; then paths+=("$esp/EFI/ubuntu"); fi
    for p in "${paths[@]}"; do
        if [ -e "$p" ]; then
            # mode + timestamps + symlinks; ownership is root everywhere here
            cp -R --no-dereference --preserve=mode,timestamps,links --parents -- "$p" "$dir/files/" \
                || die "backup of $p failed"
        fi
    done

    (cd "$dir/files" && find . -type f -print0 | sort -z | xargs -0 sha256sum) >"$dir/SHA256SUMS"
    {
        echo "grub-icon-menu backup snapshot"
        echo "label:      $label"
        echo "created:    $(date -Iseconds)"
        echo "host:       $(hostname)"
        echo "kernel:     $(uname -r)"
        echo "grub:       $(grub_version)"
        echo "tool:       grub-icon-menu $GIM_VERSION"
        echo "boot mode:  $(boot_mode)"
        echo "esp:        ${esp:-none}"
        echo
        echo "backed up:"
        for p in "${paths[@]}"; do [ -e "$p" ] && echo "  $p"; done
        echo
        echo "restore:    sudo $dir/restore.sh $dir"
    } >"$dir/MANIFEST.txt"
    "$PROJECT_DIR/inspect.sh" >"$dir/system-info.txt" 2>&1 || true
    if command -v efibootmgr >/dev/null 2>&1 && [ -d /sys/firmware/efi ]; then
        efibootmgr -v >"$dir/efibootmgr.txt" 2>&1 || true
    fi
    install -d -m 0755 "$dir/lib"
    install -m 0755 "$PROJECT_DIR/restore.sh" "$dir/restore.sh"
    install -m 0644 "$PROJECT_DIR/lib/common.sh" "$dir/lib/common.sh"

    # Verify the copy of the files that matter most.
    for p in /etc/default/grub "$GIM_GRUB_CFG"; do
        if [ -f "$p" ] && ! cmp -s -- "$p" "$dir/files$p"; then
            die "backup verification failed for $p"
        fi
    done
    printf '%s\n' "$dir"
}

# ---------------------------------------------------------------------------
# Resolution
# ---------------------------------------------------------------------------

# Native resolution of the built-in panel (or first connected output).
native_resolution() {
    local f status mode best=""
    for f in /sys/class/drm/card*-eDP-* /sys/class/drm/card*-LVDS-* /sys/class/drm/card*-DSI-* /sys/class/drm/card*-*; do
        [ -r "$f/status" ] && [ -r "$f/modes" ] || continue
        status="$(cat "$f/status" 2>/dev/null)"
        [ "$status" = connected ] || continue
        mode="$(head -n1 "$f/modes" 2>/dev/null)"
        case "$mode" in [0-9]*x[0-9]*) best="${mode%%[!0-9x]*}"; break ;; esac
    done
    printf '%s\n' "$best"
}

# Resolution to design the theme for: --resolution, else the first mode of a
# user-set GRUB_GFXMODE, else the native panel mode, else 1920x1080.
choose_resolution() {
    local requested="$1" gfx first
    if [ -n "$requested" ]; then printf '%s\n' "$requested"; return; fi
    gfx="$(grub_setting_without_dropin GRUB_GFXMODE)"
    first="${gfx%%,*}"
    case "$first" in
        [0-9]*x[0-9]*) printf '%s\n' "${first%x*}x$(printf '%s' "${first#*x}" | sed 's/x.*//')"; return ;;
    esac
    first="$(native_resolution)"
    if [ -n "$first" ]; then printf '%s\n' "$first"; else printf '1920x1080\n'; fi
}

# ---------------------------------------------------------------------------
# Building and installing
# ---------------------------------------------------------------------------

# build_theme RES OUTDIR ORDER [TITLE yes|no] [WINDOWS_BOOT firmware|chainload]
#             [BACKGROUND file|""] [ICON_COLOR auto|black|white] [SHADOW auto|on|off]:
# generate and verify a theme directory (with handoff.img for firmware mode).
build_theme() {
    local opts=()
    if [ "${4:-yes}" = no ]; then opts+=(--no-title); fi
    if [ -n "${6:-}" ]; then opts+=(--background "$6"); fi
    opts+=(--icon-color "${7:-auto}" --shadow "${8:-auto}")
    run "$PROJECT_DIR/scripts/generate-assets.sh" --resolution "$1" --out "$2" --order "$3" "${opts[@]}" \
        || die "theme generation failed"
    if [ "${5:-firmware}" = firmware ]; then
        run "$PROJECT_DIR/scripts/build-handoff.sh" --out "$2/handoff.img" \
            || die "building the Windows handoff program (handoff.img) failed"
    fi
    local f
    for f in icon-menu.txt theme.txt chooser.cfg title.png line.png corner_nw.png "$GIM_MARKER"; do
        [ -s "$2/$f" ] || die "generated theme is missing $f"
    done
    grub-script-check "$2/chooser.cfg" || die "chooser.cfg has GRUB syntax errors"
}

# check_background FILE: a readable picture that ImageMagick understands.
check_background() {
    local f="$1" im=magick
    command -v magick >/dev/null 2>&1 || im=convert
    [ -f "$f" ] && [ -r "$f" ] || die "background picture not found or not readable: $f"
    "$im" "$f[0]" -ping -format '%w' info: >/dev/null 2>&1 \
        || die "background: '$f' is not a picture ImageMagick can read (JPEG, PNG, WebP, ...)"
}

# stored_background: the kept copy of the background picture, if any.
stored_background() {
    local f
    for f in "$GIM_BG_STORE".*; do
        if [ -f "$f" ]; then printf '%s\n' "$f"; return 0; fi
    done
    return 1
}

# store_background FILE|"": keep a copy of the picture (or remove the copy).
store_background() {
    local src="$1" ext old
    install -d -m 0755 "$GIM_STATE_DIR"
    if [ -n "$src" ]; then
        ext="${src##*.}"
        case "$ext" in */*|"$src"|"") ext=img ;; esac
        ext="$(printf '%s' "$ext" | tr -cd 'A-Za-z0-9' | tr 'A-Z' 'a-z')"
        if [ "$src" != "$GIM_BG_STORE.${ext:-img}" ]; then
            install -m 0644 -- "$src" "$GIM_STATE_DIR/.background.new"
            for old in "$GIM_BG_STORE".*; do [ -f "$old" ] && rm -f -- "$old"; done
            mv -f -- "$GIM_STATE_DIR/.background.new" "$GIM_BG_STORE.${ext:-img}"
        fi
    else
        for old in "$GIM_BG_STORE".*; do [ -f "$old" ] && rm -f -- "$old"; done
    fi
    return 0
}

# osprober_skip_list: sets OSPROBER_SKIP to the system's own skip list plus
# Windows Boot Manager on the ESP (<fs-uuid>@/EFI/Microsoft/Boot/bootmgfw.efi),
# so os-prober never creates a GRUB entry that starts Windows. Fails when
# the ESP cannot be identified (os-prober is then not switched on).
OSPROBER_SKIP=""
osprober_skip_list() {
    local esp uuid own
    esp="$(find_esp || true)"
    [ -n "$esp" ] || { log_error "EFI System Partition not found"; return 1; }
    uuid="$(grub-probe --target=fs_uuid "$esp" 2>/dev/null)" || true
    case "$uuid" in ""|*[!A-Za-z0-9-]*) log_error "cannot read the UUID of $esp"; return 1 ;; esac
    own="$(grub_setting_without_dropin GRUB_OS_PROBER_SKIP_LIST)"
    OSPROBER_SKIP="${own:+$own }$uuid@/EFI/Microsoft/Boot/bootmgfw.efi"
}

# kinds_without_icon: systems the generated grub.cfg found, but the theme
# has no icon for yet (e.g. Kali installed after grub-icon-menu).
kinds_without_icon() {
    "$PROJECT_DIR/detect-os.sh" --cfg "$GIM_GRUB_CFG" 2>/dev/null | sed -n 's/^MISSING_ICONS=//p' | tr -d "'\\"
}

# order_with ORDER KINDS: ORDER plus KINDS that have an icon file, at most 6
# icons (the others stay in the full menu).
order_with() {
    local o="$1" k
    for k in $2; do
        case " $o " in *" $k "*) continue ;; esac
        if [ ! -f "$PROJECT_DIR/icons/png/$k.png" ]; then
            log_warn "no icon file icons/png/$k.png: $k stays in the ESC menu only"; continue
        fi
        if [ "$(printf '%s\n' $o | wc -l)" -ge 6 ]; then
            log_warn "already 6 icons: $k stays in the ESC menu only"; continue
        fi
        o="$o $k"
    done
    printf '%s\n' "$o"
}

# Static busybox for handoff.img (firmware mode).
require_static_busybox() {
    case "$(file -bL /bin/busybox 2>/dev/null)" in
        *"statically linked"*) ;;
        *) die "the Windows handoff needs a static busybox: sudo apt install busybox-static (or use --windows-boot chainload)" ;;
    esac
}

# install_theme STAGE [again]: atomically replace the installed theme with
# STAGE. A previous installation is moved to $PREVIOUS_THEME for rollback.
# "again": the installed theme is this run's own first build (icons for newly
# found systems were added); it is replaced and $PREVIOUS_THEME is kept.
PREVIOUS_THEME=""
install_theme() {
    local stage="$1" again="${2:-}" parent tmp old
    parent="$(dirname -- "$GIM_THEME_DIR")"
    install -d -m 0755 "$parent"
    if [ -e "$GIM_THEME_DIR" ]; then
        [ -f "$GIM_THEME_DIR/$GIM_MARKER" ] \
            || die "$GIM_THEME_DIR exists but was not created by grub-icon-menu - not touching it"
    fi
    tmp="$(mktemp -d "$parent/.grub-icon-menu.new.XXXXXX")"
    cp -r -- "$stage/." "$tmp/"
    find "$tmp" -type d -exec chmod 0755 {} +
    find "$tmp" -type f -exec chmod 0644 {} +
    if [ -e "$GIM_THEME_DIR" ] && [ "$again" = again ]; then
        old="$(mktemp -d "$parent/.grub-icon-menu.drop.XXXXXX")"
        rmdir -- "$old"
        run mv -- "$GIM_THEME_DIR" "$old"
        run mv -- "$tmp" "$GIM_THEME_DIR"
        rm -r -- "$old"
        return 0
    fi
    if [ -e "$GIM_THEME_DIR" ]; then
        PREVIOUS_THEME="$(mktemp -d "$parent/.grub-icon-menu.old.XXXXXX")"
        rmdir -- "$PREVIOUS_THEME"
        run mv -- "$GIM_THEME_DIR" "$PREVIOUS_THEME"
    fi
    run mv -- "$tmp" "$GIM_THEME_DIR"
}

# Remove the theme kept for rollback once everything succeeded.
drop_previous_theme() {
    if [ -n "$PREVIOUS_THEME" ] && [ -f "$PREVIOUS_THEME/$GIM_MARKER" ]; then
        rm -r -- "$PREVIOUS_THEME"
    fi
    PREVIOUS_THEME=""
}

install_hook() {
    local tmp
    tmp="$(mktemp "$(dirname -- "$GIM_HOOK")/.99_grub_icon_menu.XXXXXX")"
    cp -- "$PROJECT_DIR/grub.d/99_grub_icon_menu" "$tmp"
    chmod 0755 "$tmp"
    run mv -f -- "$tmp" "$GIM_HOOK"
}

# write_dropin RES TIMEOUT ORDER OS_PROBER(enable|disable|skipwindows|keep)
#              [TITLE yes|no] [WINDOWS_BOOT firmware|chainload] [ICON_MENU true|false]
# skipwindows: os-prober on with GRUB_OS_PROBER_SKIP_LIST=$OSPROBER_SKIP
# (see osprober_skip_list).
write_dropin() {
    local res="$1" timeout="$2" order="$3" osprober="$4" title="${5:-yes}" winboot="${6:-firmware}"
    local icon_menu="${7:-true}" tmp prev
    install -d -m 0755 "$(dirname -- "$GIM_DROPIN")"
    tmp="$(mktemp "$(dirname -- "$GIM_DROPIN")/.99-grub-icon-menu.XXXXXX")"
    {
        echo "# grub-icon-menu configuration - managed by grub-icon-menu, removed by uninstall.sh"
        echo "# Sourced by update-grub after /etc/default/grub. After editing run: sudo update-grub"
        echo
        echo "# Icon chooser. false: the plain text menu instead; in firmware mode it keeps"
        echo "# the BitLocker-safe Windows entry (sudo ./update.sh --plain / --icons)."
        echo "GRUB_ICON_MENU=$icon_menu"
        echo "# Seconds before the preselected icon boots; -1 waits forever."
        echo "GRUB_ICON_MENU_TIMEOUT=$timeout"
        echo "GRUB_ICON_MENU_THEME_DIR=$GIM_THEME_DIR"
        echo "# Icons from left to right (assets are generated for this order; at most 6)."
        echo "# Systems found later get their icon with: sudo ./update.sh"
        echo "GRUB_ICON_MENU_ORDER=\"$order\""
        echo "# >_GRUB / BOOTMENU title on screen (no = removed with -rt; rebuild with update.sh)."
        echo "GRUB_ICON_MENU_TITLE=$title"
        echo "# How the Windows icon starts Windows. firmware: the UEFI firmware starts it"
        echo "# (one-time BootNext + restart), so BitLocker does not ask for the recovery key."
        echo "# chainload: GRUB starts it, and BitLocker asks for the recovery key."
        echo "GRUB_ICON_MENU_WINDOWS_BOOT=$winboot"
        echo
        echo "# Theme of the full standard menu (ESC in the icon chooser)."
        prev="$(grub_setting_without_dropin GRUB_THEME)"
        echo "# Previous GRUB_THEME: ${prev:-unset}"
        echo "GRUB_THEME=$GIM_THEME_DIR/theme.txt"
        prev="$(grub_setting_without_dropin GRUB_GFXMODE)"
        echo "# Resolution the theme was designed for (falls back to auto). Previous: ${prev:-unset}"
        echo "GRUB_GFXMODE=$res,auto"
        prev="$(grub_setting_without_dropin GRUB_DISABLE_OS_PROBER)"
        case "$osprober" in
            enable)
                echo
                echo "# Let os-prober add Windows Boot Manager to the menu. Previous: ${prev:-unset (Ubuntu: auto)}"
                echo "GRUB_DISABLE_OS_PROBER=false" ;;
            disable)
                echo
                echo "# No GRUB chainload entry for Windows: started from GRUB, Windows asks for"
                echo "# the BitLocker recovery key. Previous: ${prev:-unset (Ubuntu: auto)}"
                echo "GRUB_DISABLE_OS_PROBER=true" ;;
            skipwindows)
                echo
                echo "# os-prober finds systems on other partitions (Linux Mint, Zorin, ...); they"
                echo "# get their own icons. Windows is on the skip list: started from GRUB it would"
                echo "# ask for the BitLocker recovery key (its icon uses the firmware)."
                echo "# Previous GRUB_DISABLE_OS_PROBER: ${prev:-unset (Ubuntu: auto)}"
                echo "GRUB_ICON_MENU_OS_PROBER=true"
                echo "GRUB_ICON_MENU_FOREIGN_LINUX=true"
                echo "GRUB_DISABLE_OS_PROBER=false"
                echo "GRUB_OS_PROBER_SKIP_LIST=\"$OSPROBER_SKIP\"" ;;
        esac
    } >"$tmp"
    chmod 0644 "$tmp"
    run mv -f -- "$tmp" "$GIM_DROPIN"
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

# validate_cfg FILE EXPECT_WINDOWS(0|1) [MENU icons|plain]: checks a
# generated grub.cfg. Sets VALIDATED_KINDS. Returns non-zero on hard failures.
VALIDATED_KINDS=""
validate_cfg() {
    local cfg="$1" expect_windows="$2" menu="${3:-icons}" ok=0 out kinds layout tl tw kernel chain esp
    log_detail "grub-script-check $cfg"
    grub-script-check "$cfg" || { log_error "grub-script-check reports syntax errors in $cfg"; return 1; }

    if ! grep -q '^### BEGIN /etc/grub.d/99_grub_icon_menu ###$' "$cfg"; then
        log_error "the grub-icon-menu section is missing from $cfg"; return 1
    fi
    if [ "$menu" = plain ]; then
        if grep -q 'configfile "${gim_dir}/chooser.cfg"' "$cfg"; then
            log_error "GRUB_ICON_MENU=false, but grub.cfg still contains the icon chooser"; return 1
        fi
        log_detail "plain menu (icon chooser disabled)"
    elif ! grep -q 'configfile "${gim_dir}/chooser.cfg"' "$cfg"; then
        log_warn "grub.cfg contains no icon chooser:"
        sed -n '/^### BEGIN \/etc\/grub.d\/99_grub_icon_menu ###$/,/^### END/p' "$cfg" | sed 's/^/      /' >&2
        ok=2
    fi

    out="$("$PROJECT_DIR/detect-os.sh" --cfg "$cfg")" || { log_error "detection failed on $cfg"; return 1; }
    kinds="$(printf '%s\n' "$out" | sed -n "s/^KINDS=//p" | tr -d "'\\\\" )"
    layout="$(printf '%s\n' "$out" | sed -n 's/^LAYOUT=//p')"
    VALIDATED_KINDS="$kinds"
    log_detail "detected: ${kinds:-nothing} (layout ${layout:-none})"

    # Icons for this layout.
    if [ -n "$layout" ]; then
        local n i
        n=$(( $(printf '%s' "$layout" | tr -cd '-' | wc -c) + 1 ))
        for (( i = 0; i < n; i++ )); do
            png_ok "$GIM_THEME_DIR/icons/gim-$layout-$i.png" \
                || { log_error "icon missing or invalid: gim-$layout-$i.png"; return 1; }
        done
    fi
    # Theme referenced by grub.cfg.
    grep -q '^set theme=.*/grub-icon-menu/theme.txt' "$cfg" \
        || log_warn "grub.cfg does not load the grub-icon-menu fallback theme (GRUB_THEME overridden elsewhere?)"

    # Windows: the firmware handoff is complete, or the chainloader target
    # exists on the ESP.
    if printf '%s\n' "$out" | grep -q '^WINDOWS=1$'; then
        tw="$(eval "$(printf '%s\n' "$out" | grep '^TARGET_WINDOWS=')"; printf '%s' "$TARGET_WINDOWS")"
        log_detail "Windows icon boots entry: $tw"
    fi
    if printf '%s\n' "$out" | grep -q '^WINDOWS_BOOT=firmware$'; then
        validate_handoff "$cfg" || return 1
    elif printf '%s\n' "$out" | grep -q '^WINDOWS=1$'; then
        log_warn "the Windows icon chainloads Windows Boot Manager from GRUB: with BitLocker,"
        log_warn "Windows asks for the recovery key (sudo ./update.sh --windows-boot firmware avoids it)"
        esp="$(find_esp || true)"
        chain="$(awk '/chainloader/ && tolower($0) ~ /bootmgfw\.efi/ { print $2; exit }' "$cfg")"
        if [ -n "$esp" ] && [ -n "$chain" ]; then
            if find "$esp" -maxdepth 4 -ipath "$esp${chain}" -type f 2>/dev/null | grep -q .; then
                log_detail "Windows loader present: $esp$chain"
            else
                log_warn "Windows entry chainloads $chain but it was not found on $esp"
            fi
        fi
    elif [ "$expect_windows" = 1 ]; then
        log_warn "Windows Boot Manager is installed but the menu got no Windows icon (see the update-grub messages above); the menu shows the Tux icon only"
    fi

    # Linux: kernel of the primary entry exists.
    if printf '%s\n' "$out" | grep -q '^LINUX=1$'; then
        tl="$(eval "$(printf '%s\n' "$out" | grep '^TARGET_LINUX=')"; printf '%s' "$TARGET_LINUX")"
        log_detail "Tux icon boots entry: $tl"
        kernel="$(awk '/^[ \t]*linux[ \t]/ && $2 ~ /vmlinuz/ { print $2; exit }' "$cfg")"
        if [ -n "$kernel" ]; then
            # The path is relative to the partition holding it (/ or /boot):
            # look the kernel up by name in /boot.
            if [ -f "/boot/${kernel##*/}" ] || [ -f "$kernel" ]; then
                log_detail "kernel present: $kernel"
            else
                log_error "kernel $kernel referenced by grub.cfg not found"; return 1
            fi
        fi
    fi
    return "$ok"
}

# validate_handoff FILE: the firmware handoff entry of a generated grub.cfg
# has its kernel, its initrd and a Windows Boot Manager entry to start.
validate_handoff() {
    local cfg="$1" num kernel fwnum
    num="$(sed -n 's/.* gim\.bootnext=\([0-9A-F]\{4\}\) .*/\1/p' "$cfg" | head -n1)"
    kernel="$(awk '/gim\.bootnext=/ { print $2; exit }' "$cfg" | tr -d "'")"
    if [ -z "$num" ] || [ -z "$kernel" ]; then
        log_error "the Windows handoff entry in $cfg is incomplete"; return 1
    fi
    if [ ! -f "/boot/${kernel##*/}" ] && [ ! -f "$kernel" ]; then
        log_error "kernel $kernel of the Windows handoff entry not found"; return 1
    fi
    if [ ! -s "$GIM_THEME_DIR/handoff.img" ]; then
        log_error "$GIM_THEME_DIR/handoff.img is missing"; return 1
    fi
    fwnum="$(GIM_HOOK_LIB=1; . "$PROJECT_DIR/grub.d/99_grub_icon_menu"; gim_windows_bootnum || true)"
    if [ "$fwnum" != "$num" ]; then
        log_error "grub.cfg hands off to Boot$num, but the firmware's Windows Boot Manager is '${fwnum:-none}'"; return 1
    fi
    log_detail "Windows icon: kernel $kernel + handoff.img set BootNext=Boot$num (Windows Boot Manager) and restart"
    if grep -qi '^[[:space:]]*chainloader.*bootmgfw\.efi' "$cfg"; then
        if grep -q '^GRUB_ICON_MENU_OS_PROBER=true$' "$GIM_DROPIN" 2>/dev/null; then
            log_error "os-prober created a GRUB entry that starts Windows despite GRUB_OS_PROBER_SKIP_LIST;"
            log_error "Windows started from it would ask for the BitLocker recovery key"
            return 1
        fi
        log_warn "GRUB still lists a chainload entry for Windows (os-prober enabled elsewhere?). It is only"
        log_warn "in the ESC menu; Windows started from it asks for the BitLocker recovery key."
    fi
    local k t
    for k in $(printf '%s\n' "$out" | sed -n 's/^TARGET_\([A-Z0-9]*\)=gim-.*-handoff$/\1/p'); do
        [ "$k" = WINDOWS ] && continue
        t="$(printf '%s\n' "$out" | sed -n "s/^TARGET_$k=//p")"
        log_detail "$(printf '%s' "$k" | tr 'A-Z' 'a-z') icon: started by the UEFI firmware ($t)"
    done
}
