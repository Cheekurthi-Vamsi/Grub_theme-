#!/bin/bash
#
# scripts/build-handoff.sh - build handoff.img, the initrd of the Windows
# icon (see handoff/init for what it does and why).
#
#   scripts/build-handoff.sh --out FILE [--busybox PATH]
#
# Contents: /init (handoff/init), /bin/busybox (static, from busybox-static)
# and /dev/console (the kernel opens it before /init runs). The archive is
# a gzip'd newc cpio written by Python, so building it needs no root (device
# node) and is reproducible: same inputs -> byte-identical file, which lets
# update.sh tell whether the installed copy is current.

set -Eeuo pipefail
PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$PROJECT_DIR/lib/common.sh"

OUT=""
BUSYBOX=/bin/busybox
while [ $# -gt 0 ]; do
    case "$1" in
        --out)     OUT="${2:-}"; shift 2 ;;
        --busybox) BUSYBOX="${2:-}"; shift 2 ;;
        -h|--help) sed -n '3,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done
[ -n "$OUT" ] || die "usage: $0 --out FILE [--busybox PATH]"
require_cmd python3 gzip file

# The initrd has no libraries: busybox must be the static build.
[ -x "$BUSYBOX" ] || die "$BUSYBOX not found: sudo apt install busybox-static"
case "$(file -bL "$BUSYBOX")" in
    *"statically linked"*) ;;
    *) die "$BUSYBOX is not statically linked: sudo apt install busybox-static" ;;
esac
applets="$("$BUSYBOX" --list)"
for applet in sh mount od tr grep sed dd printf reboot poweroff; do
    grep -qx "$applet" <<<"$applets" || die "$BUSYBOX lacks the '$applet' applet"
done
"$BUSYBOX" sh -n "$PROJECT_DIR/handoff/init" || die "handoff/init has shell syntax errors"

tmp="$(mktemp "$(dirname -- "$OUT")/.handoff.XXXXXX")"
trap 'rm -f -- "$tmp"' EXIT
python3 - "$PROJECT_DIR/handoff/init" "$BUSYBOX" <<'EOF' | gzip -9 -n >"$tmp"
import sys

inodes = iter(range(1, 100))

def entry(name, mode, data=b"", rdev=(0, 0)):
    ino = 0 if name == "TRAILER!!!" else next(inodes)
    name = name.encode() + b"\0"
    hdr = "070701" + "".join("%08X" % v for v in (
        ino, mode, 0, 0, 1, 0, len(data),  # ino mode uid gid nlink mtime size
        0, 0, rdev[0], rdev[1],            # dev major/minor, rdev major/minor
        len(name), 0))                     # namesize, check
    out = hdr.encode() + name
    out += b"\0" * (-len(out) % 4)
    out += data + b"\0" * (-len(data) % 4)
    return out

init = open(sys.argv[1], "rb").read()
busybox = open(sys.argv[2], "rb").read()
parts = [entry(d, 0o040755) for d in ("bin", "dev", "proc", "sys", "tmp")]
parts.append(entry("dev/console", 0o020600, rdev=(5, 1)))
parts.append(entry("bin/busybox", 0o100755, busybox))
parts.append(entry("init", 0o100755, init))
parts.append(entry("TRAILER!!!", 0))
sys.stdout.buffer.write(b"".join(parts))
EOF
chmod 0644 "$tmp"
mv -f -- "$tmp" "$OUT"
trap - EXIT
