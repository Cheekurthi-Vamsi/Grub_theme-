#!/bin/bash
#
# generate-menu.sh - dry run: print the GRUB script that update-grub would
# append to grub.cfg, without installing or changing anything.
#
#   sudo ./generate-menu.sh                       # for /boot/grub/grub.cfg
#   ./generate-menu.sh --cfg FILE --theme DIR     # any grub.cfg, no root
#
# --theme defaults to the installed theme directory. Without root (or with
# --no-device) the disk lookup lines are omitted from the output.

set -Eeuo pipefail
PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$PROJECT_DIR/lib/common.sh"

CFG="$GIM_GRUB_CFG"
THEME="$GIM_THEME_DIR"
NO_DEVICE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --cfg)       CFG="${2:-}"; shift 2 ;;
        --theme)     THEME="${2:-}"; shift 2 ;;
        --no-device) NO_DEVICE=1; shift ;;
        -h|--help)   sed -n '3,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done
[ -r "$CFG" ] || die "cannot read $CFG (run with sudo?)"
[ "$(id -u)" -eq 0 ] || NO_DEVICE=1

# The hook reads GRUB_ICON_MENU_* from /etc/default; point it at a private
# copy so --theme can be overridden without touching the system.
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/default/grub.d"
[ -f /etc/default/grub ] && cp /etc/default/grub "$tmp/default/grub"
for f in /etc/default/grub.d/*.cfg; do
    [ -e "$f" ] && cp "$f" "$tmp/default/grub.d/"
done
printf 'GRUB_ICON_MENU_THEME_DIR=%q\n' "$THEME" >"$tmp/default/grub.d/zz-generate-menu.cfg"

env_args=(GIM_INPUT_CFG="$CFG" GIM_SYSCONFDIR="$tmp")
if [ "$NO_DEVICE" = 1 ]; then
    # Path as GRUB sees it: relative to the root of the partition holding it.
    rel="$THEME"
    if mountpoint -q /boot 2>/dev/null; then rel="${THEME#/boot}"; fi
    env_args+=(GIM_TEST_DEVICE_PREP="" GIM_TEST_THEME_REL="$rel")
fi
env "${env_args[@]}" "$PROJECT_DIR/grub.d/99_grub_icon_menu"
