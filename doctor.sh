#!/bin/bash
#
# doctor.sh - read-only health check of the dual boot (Ubuntu + Windows with
# BitLocker) and of grub-icon-menu. Prints OK / WARN / FAIL with the fix.
#
#   sudo ./doctor.sh       # everything (grub.cfg and kernels are root-only)
#   ./doctor.sh            # what a normal user can read
#   ./doctor.sh --no-fwupd # skip the firmware update check (needs network)
#
# Changes nothing. Run it after Windows or BIOS updates, after kernel
# updates, or whenever something looks wrong. docs/help.html explains every
# message in detail.

set -Eeuo pipefail
PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$PROJECT_DIR/lib/common.sh"

FWUPD=1
while [ $# -gt 0 ]; do
    case "$1" in
        --no-fwupd) FWUPD=0; shift ;;
        -h|--help)  sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)          die "unknown option: $1" ;;
    esac
done

NOK=0; NWARN=0; NFAIL=0
ok()   { NOK=$((NOK + 1));     printf '  %sOK%s    %s\n' "$_c_grn" "$_c_off" "$1"; }
warn() { NWARN=$((NWARN + 1)); printf '  %sWARN%s  %s\n' "$_c_yel" "$_c_off" "$1"; shift; fix "$@"; }
fail() { NFAIL=$((NFAIL + 1)); printf '  %sFAIL%s  %s\n' "$_c_red" "$_c_off" "$1"; shift; fix "$@"; }
fix()  { local l; for l in "$@"; do printf '        %s-> %s%s\n' "$_c_dim" "$l" "$_c_off"; done; }
info() { printf '  %s..%s    %s\n' "$_c_dim" "$_c_off" "$1"; }
section() { printf '\n== %s\n' "$*"; }
ROOT=0; [ "$(id -u)" = 0 ] && ROOT=1

# ---------------------------------------------------------------------------
section "Firmware"
if [ ! -d /sys/firmware/efi ]; then
    fail "not booted in UEFI mode" "the Windows icon needs UEFI; check the BIOS boot mode"
    echo; echo "doctor: $NOK ok, $NWARN warnings, $NFAIL problems"; exit 1
fi
ok "booted in UEFI mode"
sb="$(secure_boot_state)"
case "$sb" in
    *enabled*)  ok "Secure Boot: $sb" ;;
    *disabled*) warn "Secure Boot: $sb" "BitLocker sealed its key with Secure Boot ON: turning it off (or on) makes Windows ask for the recovery key" ;;
    *)          info "Secure Boot: $sb" ;;
esac

if ! command -v efibootmgr >/dev/null 2>&1; then
    warn "efibootmgr is not installed - boot entries not checked" "sudo apt install efibootmgr"
else
    efi="$(efibootmgr 2>/dev/null || true)"
    order="$(printf '%s\n' "$efi" | sed -n 's/^BootOrder: //p')"
    win="$(printf '%s\n' "$efi" | grep -i 'EFI\\Microsoft\\Boot\\bootmgfw.efi' | sed -n 's/^Boot\([0-9A-F]\{4\}\).*/\1/p' | head -n1)"
    [ -n "$win" ] || win="$(printf '%s\n' "$efi" | grep -i 'Windows Boot Manager' | sed -n 's/^Boot\([0-9A-F]\{4\}\).*/\1/p' | head -n1)"
    ubu="$(printf '%s\n' "$efi" | grep -i 'EFI\\ubuntu\\\(shim\|grub\)' | sed -n 's/^Boot\([0-9A-F]\{4\}\).*/\1/p' | head -n1)"
    [ -n "$ubu" ] || ubu="$(printf '%s\n' "$efi" | grep -i '^Boot[0-9A-F]\{4\}\*\? *ubuntu' | sed -n 's/^Boot\([0-9A-F]\{4\}\).*/\1/p' | head -n1)"
    if [ -n "$win" ]; then
        ok "firmware entry for Windows Boot Manager: Boot$win"
    else
        fail "the firmware has no Windows Boot Manager entry: the Windows icon cannot work" \
             "boot Windows once with F9 (HP boot menu) or repair it from Windows; then: sudo ./update.sh"
    fi
    first="${order%%,*}"
    if [ -n "$ubu" ] && [ "$first" = "$ubu" ]; then
        ok "the laptop starts Ubuntu (GRUB) first: BootOrder $order"
    elif [ -n "$ubu" ]; then
        warn "the firmware starts Boot$first first, not Ubuntu (Boot$ubu): no GRUB menu at power-on" \
             "Windows updates sometimes do this. Fix: sudo efibootmgr -o $(printf '%s' "$ubu,$(printf '%s' "$order" | tr ',' '\n' | grep -vx "$ubu" | paste -sd,)")" \
             "(only changes the order; nothing is deleted)"
    else
        warn "no Ubuntu entry found in the firmware boot list" "check: sudo efibootmgr -v"
    fi
    next="$(printf '%s\n' "$efi" | sed -n 's/^BootNext: //p')"
    if [ -n "$next" ]; then
        warn "BootNext=Boot$next is set: the NEXT start skips GRUB once" \
             "if you did not just pick the Windows icon: sudo efibootmgr --delete-bootnext"
    else
        ok "no pending one-time boot (BootNext)"
    fi
fi

# ---------------------------------------------------------------------------
section "grub-icon-menu"
if [ ! -f "$GIM_HOOK" ] || [ ! -f "$GIM_DROPIN" ]; then
    info "not installed (sudo ./install.sh)"
else
    ver="$(state_get VERSION 2>/dev/null || true)"
    if [ "$ver" = "$GIM_VERSION" ]; then ok "installed version $ver"
    else warn "installed version ${ver:-unknown}, this folder has $GIM_VERSION" "sudo ./update.sh"; fi
    if cmp -s "$PROJECT_DIR/grub.d/99_grub_icon_menu" "$GIM_HOOK"; then ok "hook up to date"
    else warn "/etc/grub.d/99_grub_icon_menu differs from this folder" "sudo ./update.sh"; fi
    winboot="$(grub_setting GRUB_ICON_MENU_WINDOWS_BOOT)"; winboot="${winboot:-firmware}"
    if [ "$winboot" = firmware ]; then
        ok "Windows icon: started by the UEFI firmware (no BitLocker prompt)"
    else
        warn "Windows icon chainloads Windows from GRUB: BitLocker asks for the recovery key every time" \
             "sudo ./update.sh --windows-boot firmware"
    fi
    if [ "$(grub_setting GRUB_DISABLE_OS_PROBER)" = true ]; then
        ok "os-prober off: GRUB has no Windows entry that would ask for the key"
    elif [ "$(grub_setting GRUB_ICON_MENU_OS_PROBER)" = true ]; then
        case " $(grub_setting GRUB_OS_PROBER_SKIP_LIST) " in
            *"@/EFI/Microsoft/Boot/bootmgfw.efi "*)
                ok "os-prober on for other systems, Windows on its skip list (no entry that asks for the key)" ;;
            *)  warn "os-prober is on, but Windows is not on GRUB_OS_PROBER_SKIP_LIST" \
                     "sudo ./update.sh --os-prober (sets it again) or sudo ./update.sh --no-os-prober" ;;
        esac
    elif [ "$winboot" = firmware ]; then
        warn "os-prober is enabled again: GRUB may list a Windows entry that asks for the recovery key" \
             "another file sets GRUB_DISABLE_OS_PROBER; check /etc/default/grub and /etc/default/grub.d/"
    fi
    case "$(grub_setting GRUB_ICON_MENU)" in
        false|0|no) info "menu: plain text menu (sudo ./update.sh --icons for the icons)" ;;
        *)          info "menu: icons" ;;
    esac
    if [ -f "$GIM_THEME_DIR/$GIM_MARKER" ]; then
        res="$(sed -n 's/^RESOLUTION=//p' "$GIM_THEME_DIR/$GIM_MARKER")"
        fg="$(sed -n 's/^FOREGROUND=//p' "$GIM_THEME_DIR/$GIM_MARKER")"
        if [ -f "$GIM_THEME_DIR/background.png" ]; then
            ok "theme $res, background picture, ${fg:-black} icons"
        else
            ok "theme $res, white background, ${fg:-black} icons"
        fi
        if [ -f "$GIM_THEME_DIR/background.png" ] && ! ls "$GIM_BG_STORE".* >/dev/null 2>&1; then
            warn "the kept copy of the background picture is missing ($GIM_BG_STORE.*)" \
                 "update.sh falls back to the installed picture; to replace it: sudo ./update.sh -bg FILE"
        fi
    else
        fail "theme directory $GIM_THEME_DIR is missing" "sudo ./update.sh --rebuild"
    fi
    if [ "$winboot" = firmware ]; then
        if [ -s "$GIM_THEME_DIR/handoff.img" ]; then
            if [ -x "$PROJECT_DIR/scripts/build-handoff.sh" ] && tmp="$(mktemp)" \
               && "$PROJECT_DIR/scripts/build-handoff.sh" --out "$tmp" >/dev/null 2>&1; then
                if cmp -s "$tmp" "$GIM_THEME_DIR/handoff.img"; then ok "handoff.img present and current"
                else warn "handoff.img differs from this folder's version" "sudo ./update.sh"; fi
                rm -f -- "$tmp"
            else
                ok "handoff.img present"
            fi
        else
            fail "handoff.img is missing: the Windows icon cannot work" "sudo ./update.sh --rebuild"
        fi
    fi
fi

# ---------------------------------------------------------------------------
section "Other systems (Kali, Linux Mint, Arch, ...)"
have="$(sed -n 's/^ORDER=//p' "$GIM_THEME_DIR/$GIM_MARKER" 2>/dev/null | tail -n1)"
fwsys="$(GIM_HOOK_LIB=1; . "$PROJECT_DIR/grub.d/99_grub_icon_menu"; gim_firmware_systems 2>/dev/null || true)"
if [ -z "$fwsys" ]; then
    info "no other system with its own UEFI boot entry"
else
    while read -r k n m name; do
        [ -n "$k" ] || continue
        case " $have " in
            *" $k "*) ok "$name: icon, started by the firmware like Windows (Boot$n, ${m})" ;;
            *)       warn "$name found (Boot$n), but it has no icon yet (it is in the ESC menu)" "sudo ./update.sh" ;;
        esac
    done <<<"$fwsys"
fi
if [ "$(grub_setting GRUB_ICON_MENU_OS_PROBER)" = true ]; then
    info "os-prober mode: systems on other partitions (Linux Mint, Zorin, ...) get icons too"
else
    info "Linux Mint, Zorin or elementary share Ubuntu's boot folder: sudo ./update.sh --os-prober finds them"
fi
if [ "$ROOT" = 1 ] && [ -r "$GIM_GRUB_CFG" ] && [ -f "$GIM_HOOK" ]; then
    missing="$("$PROJECT_DIR/detect-os.sh" --cfg "$GIM_GRUB_CFG" 2>/dev/null | sed -n 's/^MISSING_ICONS=//p' | tr -d "'\\")"
    if [ -n "$missing" ]; then
        warn "grub.cfg found systems without an icon: $missing" "sudo ./update.sh (adds up to 6 icons)"
    fi
fi

# ---------------------------------------------------------------------------
section "GRUB menu and kernels"
if [ "$ROOT" = 1 ] && [ -r "$GIM_GRUB_CFG" ]; then
    if grub-script-check "$GIM_GRUB_CFG" >/dev/null 2>&1; then ok "grub.cfg passes grub-script-check"
    else fail "grub.cfg has syntax errors" "sudo update-grub, then run doctor again"; fi
    if grep -qi '^[[:space:]]*chainloader.*bootmgfw\.efi' "$GIM_GRUB_CFG"; then
        warn "grub.cfg contains an entry that chainloads Windows (asks for the BitLocker key)" \
             "do not use it; start Windows with the Windows icon or F9"
    fi
    if [ -f "$GIM_HOOK" ]; then
        hnum="$(sed -n 's/.* gim\.bootnext=\([0-9A-F]\{4\}\) .*/\1/p' "$GIM_GRUB_CFG" | head -n1)"
        hkernel="$(awk '/gim\.bootnext=/ { print $2; exit }' "$GIM_GRUB_CFG" | tr -d "'")"
        if [ -n "$hnum" ]; then
            if [ -n "${win:-}" ] && [ "$hnum" != "$win" ]; then
                warn "grub.cfg hands off to Boot$hnum, the firmware's Windows Boot Manager is Boot$win" \
                     "the Windows icon still finds it at boot; to update grub.cfg: sudo update-grub"
            else
                ok "Windows icon hands off to Boot$hnum"
            fi
            # The newest signed kernel, as the hook picks it.
            want="$(GIM_HOOK_LIB=1; . "$PROJECT_DIR/grub.d/99_grub_icon_menu"; gim_handoff_kernel)"
            if [ -n "$want" ] && [ "${hkernel##*/}" != "${want##*/}" ]; then
                warn "the Windows icon uses ${hkernel##*/}, the newest signed kernel is ${want##*/}" "sudo update-grub"
            elif [ -n "$hkernel" ]; then
                if (GIM_HOOK_LIB=1; . "$PROJECT_DIR/grub.d/99_grub_icon_menu"; gim_kernel_signed "/boot/${hkernel##*/}"); then
                    ok "Windows icon kernel ${hkernel##*/} is signed"
                else
                    warn "Windows icon kernel ${hkernel##*/} has no signature: with Secure Boot on it will not start" \
                         "install a signed Ubuntu kernel (linux-generic), then sudo update-grub"
                fi
            fi
        elif [ "${winboot:-firmware}" = firmware ] && [ -n "${win:-}" ]; then
            fail "grub.cfg has no Windows handoff entry" "sudo ./update.sh (its messages say why)"
        fi
    fi
else
    info "grub.cfg and kernels are root-only: run sudo ./doctor.sh for these checks"
fi
avail="$(df -Pk /boot 2>/dev/null | awk 'NR == 2 { print $4 }')"
if [ -n "$avail" ]; then
    if [ "$avail" -lt 102400 ]; then
        warn "/boot has only $((avail / 1024)) MB free: kernel updates may fail" "sudo apt autoremove --purge (removes old kernels)"
    else
        ok "/boot: $((avail / 1024)) MB free"
    fi
fi

# ---------------------------------------------------------------------------
section "BitLocker risks (checked from Ubuntu)"
if [ "$FWUPD" = 1 ] && command -v fwupdmgr >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
    # JSON lists only devices that have an update.
    upd="$(timeout 30 fwupdmgr get-updates --json --no-unreported-check --no-metadata-check 2>/dev/null || true)"
    names="$(printf '%s' "$upd" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for dev in d.get("Devices", []):
    if dev.get("Releases"):
        print(dev.get("Name", "unknown device"))
' 2>/dev/null || true)"
    boot_fw="$(printf '%s\n' "$names" | grep -iE 'system firmware|uefi|bios|secure boot|dbx|kek|embedded controller|management engine' || true)"
    other_fw="$(printf '%s\n' "$names" | grep -viE 'system firmware|uefi|bios|secure boot|dbx|kek|embedded controller|management engine' | sed '/^$/d' || true)"
    if [ -n "$boot_fw" ]; then
        warn "firmware update offered for: $(printf '%s' "$boot_fw" | paste -sd, - | sed 's/,/, /g')" \
             "BEFORE installing it (fwupd / Ubuntu Software / HP): in Windows, suspend BitLocker" \
             "(Control Panel > BitLocker > Suspend protection), or have the recovery key ready."
    else
        ok "no BIOS/UEFI firmware update pending in fwupd"
    fi
    if [ -n "$other_fw" ]; then
        info "other firmware updates (not part of the boot chain): $(printf '%s' "$other_fw" | paste -sd, - | sed 's/,/, /g')"
    fi
else
    info "firmware update check skipped"
fi
info "BitLocker recovery key: keep it outside this laptop (https://aka.ms/myrecoverykey, or print it)"

echo
printf 'doctor: %d ok, %d warnings, %d problems\n' "$NOK" "$NWARN" "$NFAIL"
[ "$NFAIL" = 0 ]
