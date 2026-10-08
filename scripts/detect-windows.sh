#!/bin/bash
#
# scripts/detect-windows.sh - firmware/filesystem evidence of Windows.
#
# Read-only. Complements detect-os.sh (which looks at GRUB menu entries) with
# independent indicators, so install.sh can explain e.g. "Windows is on the
# ESP but GRUB has no entry for it -> os-prober must be enabled".
#
# Output (KEY=VALUE):
#   WINDOWS_EFI_LOADER   path of bootmgfw.efi on a mounted ESP, or empty
#   WINDOWS_FIRMWARE     1 if the UEFI boot manager has a Windows entry
#   WINDOWS_BITLOCKER    1 if BitLocker/Device Encryption logs are on the ESP

set -Eeuo pipefail
PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$PROJECT_DIR/lib/common.sh"

loader=""
bitlocker=0
esp="$(find_esp || true)"
if [ -n "$esp" ] && [ -d "$esp/EFI" ]; then
    # FAT is case-insensitive but the stored case varies: search without case.
    loader="$(find "$esp/EFI" -maxdepth 3 -ipath '*/microsoft/boot/bootmgfw.efi' -type f 2>/dev/null | head -n1)"
    if find "$esp/EFI" -maxdepth 3 -ipath '*/microsoft/boot/fvetcg*.log' 2>/dev/null | grep -q .; then
        bitlocker=1
    fi
fi

firmware=0
if command -v efibootmgr >/dev/null 2>&1 && [ -d /sys/firmware/efi ]; then
    # (no "efibootmgr | grep -q": under pipefail an early grep exit can fail it)
    entries="$(efibootmgr 2>/dev/null || true)"
    if grep -qi 'windows boot manager\|bootmgfw\.efi' <<<"$entries"; then
        firmware=1
    fi
fi

printf 'WINDOWS_EFI_LOADER=%q\n' "$loader"
printf 'WINDOWS_FIRMWARE=%s\n' "$firmware"
printf 'WINDOWS_BITLOCKER=%s\n' "$bitlocker"
