#!/bin/bash
#
# scripts/detect-ubuntu.sh - evidence of the running Ubuntu installation.
#
# Read-only. Output (KEY=VALUE):
#   UBUNTU               1 if /etc/os-release says Ubuntu (or ID_LIKE ubuntu)
#   UBUNTU_VERSION       VERSION_ID, e.g. 26.04
#   UBUNTU_KERNELS       number of /boot/vmlinuz-* kernels (what 10_linux uses)
#   UBUNTU_EFI_LOADER    shimx64.efi/grubx64.efi of the ubuntu ESP directory

set -Eeuo pipefail
PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$PROJECT_DIR/lib/common.sh"

ubuntu=0
version=""
if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    os_ids="$(. /etc/os-release && printf '%s %s' "${ID:-}" "${ID_LIKE:-}")"
    version="$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")"
    case " $os_ids " in *" ubuntu "*) ubuntu=1 ;; esac
fi

kernels=0
for k in /boot/vmlinuz-*; do
    [ -e "$k" ] && kernels=$((kernels + 1))
done

loader=""
esp="$(find_esp || true)"
if [ -n "$esp" ]; then
    loader="$(find "$esp/EFI" -maxdepth 2 \( -ipath '*/ubuntu/shimx64.efi' -o -ipath '*/ubuntu/grubx64.efi' \) -type f 2>/dev/null | sort | tail -n1)"
fi

printf 'UBUNTU=%s\n' "$ubuntu"
printf 'UBUNTU_VERSION=%q\n' "$version"
printf 'UBUNTU_KERNELS=%s\n' "$kernels"
printf 'UBUNTU_EFI_LOADER=%q\n' "$loader"
