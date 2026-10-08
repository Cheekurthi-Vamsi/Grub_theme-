#!/bin/bash
#
# tests/sandbox.sh - run the real install/update/uninstall/restore scripts,
# the real update-grub/grub-mkconfig and the real Ubuntu /etc/grub.d
# generators against a FAKE system, without root and without any risk.
#
#   tests/sandbox.sh setup DIR        create DIR from read-only copies of this machine
#   tests/sandbox.sh run DIR CMD...   run CMD inside the sandbox (as "root")
#
# The sandbox is a bubblewrap user+mount namespace: everything is the host
# filesystem except these bind mounts, which point into DIR:
#   /etc/default  /etc/grub.d  /boot  /boot/efi  /var/lib
#   /sys/firmware/efi/efivars  (Boot#### of the reference machine; Boot0001 =
#                               Windows Boot Manager unless DIR/no-windows exists;
#                               Boot0003 = Kali if DIR/with-kali exists)
# plus stubs for the commands that touch hardware:
#   grub-probe (disk layout of the reference machine: ESP nvme0n1p1 vfat,
#   /boot nvme0n1p4 ext4, / nvme0n1p5 ext4), os-prober (reports Windows Boot
#   Manager unless DIR/no-windows exists, and Linux Mint on nvme0n1p6 if
#   DIR/with-mint exists), linux-boot-prober, efibootmgr.
# DIR/skip-mismatch: grub-probe reports another ESP UUID to os-prober, so its
# Windows entry is not skipped (tests the safety net of --os-prober).
# Kernels/initrds are empty placeholder files (the real ones are root-only).
# Inside, writes to the real system are impossible: they are either
# redirected into DIR or denied (the real files belong to a foreign uid).

set -Eeuo pipefail
cmd="${1:-}"; SB="${2:-}"
[ -n "$cmd" ] && [ -n "$SB" ] || { sed -n '3,18p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
shift 2

setup() {
    mkdir -p "$SB"
    SB="$(cd "$SB" && pwd)"
    rm -rf -- "${SB:?}"/{etc-default,etc-grub.d,boot,esp,varlib,home,tmp,stubs,efivars}
    mkdir -p "$SB"/{etc-default,etc-grub.d,boot/grub,boot/efi,esp,varlib,home,tmp,stubs,efivars}

    cp -a /etc/default/. "$SB/etc-default/" 2>/dev/null || true
    cp -a /etc/grub.d/. "$SB/etc-grub.d/"
    # The sandbox models the machine before installation.
    rm -f "$SB/etc-default/grub.d/99-grub-icon-menu.cfg" "$SB/etc-grub.d/99_grub_icon_menu"

    # /boot: everything readable from the real one, placeholders for the rest.
    cp -a /boot/grub/fonts /boot/grub/locale /boot/grub/x86_64-efi /boot/grub/unicode.pf2 \
          /boot/grub/grubenv "$SB/boot/grub/" 2>/dev/null || true
    for f in /boot/config-* /boot/mt86+*; do [ -r "$f" ] && cp -a "$f" "$SB/boot/"; done
    for v in 7.0.0-38-generic 7.0.0-34-generic; do
        : >"$SB/boot/vmlinuz-$v"; : >"$SB/boot/initrd.img-$v"; : >"$SB/boot/System.map-$v"
    done
    ln -sfn vmlinuz-7.0.0-38-generic "$SB/boot/vmlinuz"
    ln -sfn initrd.img-7.0.0-38-generic "$SB/boot/initrd.img"
    # The real grub.cfg (root-only) has no os-prober entries: so does this one.
    printf '# placeholder grub.cfg (no os-prober entries yet)\n' >"$SB/boot/grub/grub.cfg"

    # ESP
    mkdir -p "$SB/esp/EFI/ubuntu" "$SB/esp/EFI/Microsoft/Boot" "$SB/esp/EFI/Boot"
    cp -a /boot/efi/EFI/ubuntu/grub.cfg "$SB/esp/EFI/ubuntu/" 2>/dev/null || true
    : >"$SB/esp/EFI/ubuntu/shimx64.efi"; : >"$SB/esp/EFI/ubuntu/grubx64.efi"
    : >"$SB/esp/EFI/Microsoft/Boot/bootmgfw.efi"; : >"$SB/esp/EFI/Microsoft/Boot/FveTcg_0.log"
    : >"$SB/esp/EFI/Boot/bootx64.efi"

    # UEFI boot entries (attributes, description, file path in UTF-16)
    local guid=8be4df61-93ca-11d2-aa0d-00e098032b8c
    u16() { printf '%s' "$1" | iconv -f UTF-8 -t UTF-16LE; }
    bootvar() {
        { printf '\007\000\000\000\001\000\000\000\074\000'; u16 "$2"; printf '\000\000\004\004\100\000'
          [ -n "${3:-}" ] && { u16 "$3"; printf '\000\000'; }; printf '\177\377\004\000'; } >"$SB/efivars/Boot$1-$guid"
    }
    bootvar 0000 Ubuntu '\EFI\ubuntu\shimx64.efi'
    bootvar 0001 "Windows Boot Manager" '\EFI\Microsoft\Boot\bootmgfw.efi'
    bootvar 0002 "Internal Hard Disk"
    mkdir -p "$SB/efivars-windows" "$SB/efivars-kali"
    mv "$SB/efivars/Boot0001-$guid" "$SB/efivars-windows/"
    bootvar 0003 kali '\EFI\kali\shimx64.efi'
    mv "$SB/efivars/Boot0003-$guid" "$SB/efivars-kali/"

    cat >"$SB/stubs/grub-probe" <<'EOF'
#!/bin/bash
# sandbox stub: disk layout of the reference machine
target=""; device_mode=0; args=()
while [ $# -gt 0 ]; do
    case "$1" in
        --target=*) target="${1#--target=}" ;;
        -t|--target) target="$2"; shift ;;
        -d|--device) device_mode=1 ;;
        -*) ;;
        *) args+=("$1") ;;
    esac
    shift
done
arg="${args[0]:-}"
if [ "$device_mode" = 0 ]; then
    [ -e "$arg" ] || { echo "grub-probe: error: failed to get canonical path of \`$arg'." >&2; exit 1; }
    case "$arg" in
        /boot/efi|/boot/efi/*) dev=/dev/nvme0n1p1 ;;
        /boot|/boot/*)         dev=/dev/nvme0n1p4 ;;
        *)                     dev=/dev/nvme0n1p5 ;;
    esac
else
    dev="$arg"
fi
case "$dev" in
    /dev/nvme0n1p1) fs=fat;  uuid=63A4-7C42; p=1 ;;
    /dev/nvme0n1p4) fs=ext2; uuid=1f97a033-564c-48d9-87a0-0b664bc2adad; p=4 ;;
    /dev/nvme0n1p5) fs=ext2; uuid=8c6f1b2e-3d4a-4f5b-9c6d-7e8f9a0b1c2d; p=5 ;;
    /dev/nvme0n1p6) fs=ext2; uuid=6666aaaa-bbbb-4ccc-8ddd-eeeeffff0006; p=6 ;;
    *) echo "grub-probe: error: unknown device $dev" >&2; exit 1 ;;
esac
if [ "$device_mode" = 1 ] && [ "$dev" = /dev/nvme0n1p1 ] && [ -e "SBDIR/skip-mismatch" ]; then uuid=DEAD-BEEF; fi
case "$target" in
    device) echo "$dev" ;;
    fs) echo "$fs" ;;
    fs_uuid) echo "$uuid" ;;
    partuuid) echo "00000000-0000-0000-0000-00000000000$p" ;;
    partmap) echo gpt ;;
    abstraction) ;;
    compatibility_hint) echo "hd0,gpt$p" ;;
    hints_string) echo "--hint-bios=hd0,gpt$p --hint-efi=hd0,gpt$p --hint-baremetal=ahci0,gpt$p" ;;
    drive) echo "(hd0,gpt$p)" ;;
    disk) echo /dev/nvme0n1 ;;
    *) echo "grub-probe stub: unsupported target '$target'" >&2; exit 1 ;;
esac
EOF
    sed -i "s|SBDIR|$SB|" "$SB/stubs/grub-probe"
    cat >"$SB/stubs/os-prober" <<EOF
#!/bin/sh
# sandbox stub: what os-prober reports on the reference machine
[ -e "$SB/no-windows" ] || echo "/dev/nvme0n1p1@/EFI/Microsoft/Boot/bootmgfw.efi:Windows Boot Manager:Windows:efi"
[ -e "$SB/with-mint" ] && echo "/dev/nvme0n1p6:Linux Mint 22.1 Xia (22.1):LinuxMint:linux"
exit 0
EOF
    cat >"$SB/stubs/linux-boot-prober" <<EOF
#!/bin/sh
# sandbox stub: the kernel of Linux Mint on nvme0n1p6
[ -e "$SB/with-mint" ] && [ "\$1" = /dev/nvme0n1p6 ] && \
    echo "/dev/nvme0n1p6:/dev/nvme0n1p6:Linux Mint 22.1 Xia (22.1):/boot/vmlinuz-6.8.0-50-generic:/boot/initrd.img-6.8.0-50-generic:root=UUID=6666aaaa-bbbb-4ccc-8ddd-eeeeffff0006 ro quiet splash"
exit 0
EOF
    cat >"$SB/stubs/efibootmgr" <<EOF
#!/bin/sh
# sandbox stub (read-only listing)
cat <<'X'
BootCurrent: 0000
Timeout: 0 seconds
BootOrder: 0000,0001,0002,9999
Boot0000* Ubuntu	HD(1,GPT,63a47c42-055f-4216-aada-1738b91c6a72,0x800,0x82000)/\EFI\ubuntu\shimx64.efi
X
[ -e "$SB/no-windows" ] || echo 'Boot0001* Windows Boot Manager	HD(1,GPT,63a47c42-055f-4216-aada-1738b91c6a72,0x800,0x82000)/\EFI\Microsoft\Boot\bootmgfw.efi'
cat <<'X'
Boot0002* Internal Hard Disk
Boot9999* USB Drive (UEFI)
X
EOF
    chmod +x "$SB/stubs/"*
    echo "sandbox ready: $SB"
}

run_in() {
    SB="$(cd "$SB" && pwd)"
    local extra=() guid=8be4df61-93ca-11d2-aa0d-00e098032b8c
    # Windows Boot Manager in the UEFI boot entries unless DIR/no-windows exists.
    if [ -e "$SB/no-windows" ]; then
        rm -f "$SB/efivars/Boot0001-$guid"
    else
        cp -f "$SB/efivars-windows/Boot0001-$guid" "$SB/efivars/"
    fi
    # Kali's own UEFI boot entry if DIR/with-kali exists.
    if [ -e "$SB/with-kali" ]; then
        cp -f "$SB/efivars-kali/Boot0003-$guid" "$SB/efivars/"
    else
        rm -f "$SB/efivars/Boot0003-$guid"
    fi
    # Optional failure injection: DIR/fail-script-check holds a glob; checking a
    # file whose path matches it fails (empty file: every check fails).
    if [ -e "$SB/fail-script-check" ]; then
        cat >"$SB/stubs/grub-script-check" <<EOF
#!/bin/bash
pat="\$(cat "$SB/fail-script-check")"
for a in "\$@"; do
    case "\$a" in -*) continue ;; esac
    if [ -z "\$pat" ] || [[ "\$a" == \$pat ]]; then
        echo "grub-script-check: injected failure for \$a" >&2; exit 1
    fi
done
exec "$SB/stubs/grub-script-check.real" "\$@"
EOF
        chmod +x "$SB/stubs/grub-script-check"
        cp -f /usr/bin/grub-script-check "$SB/stubs/grub-script-check.real"
        extra+=(--bind "$SB/stubs/grub-script-check" /usr/bin/grub-script-check)
    fi
    bwrap --dev-bind / / \
        --bind "$SB/etc-default" /etc/default \
        --bind "$SB/etc-grub.d" /etc/grub.d \
        --bind "$SB/boot" /boot \
        --bind "$SB/esp" /boot/efi \
        --bind "$SB/varlib" /var/lib \
        --ro-bind "$SB/efivars" /sys/firmware/efi/efivars \
        --bind "$SB/stubs/grub-probe" /usr/sbin/grub-probe \
        --bind "$SB/stubs/os-prober" /usr/bin/os-prober \
        --bind "$SB/stubs/linux-boot-prober" /usr/bin/linux-boot-prober \
        --bind "$SB/stubs/efibootmgr" /usr/bin/efibootmgr \
        "${extra[@]}" \
        --unshare-user --uid 0 --gid 0 \
        --setenv HOME "$SB/home" --setenv TMPDIR "$SB/tmp" --unsetenv SUDO_USER \
        -- "$@"
}

case "$cmd" in
    setup) setup ;;
    run)   run_in "$@" ;;
    *)     echo "unknown command $cmd" >&2; exit 2 ;;
esac
