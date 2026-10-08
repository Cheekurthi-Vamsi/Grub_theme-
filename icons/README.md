# Icon sources

Everything on the boot screen is drawn from the files in this folder, at the exact
pixel size of the screen, so the icons stay sharp at every resolution and on any
background. In black on light backgrounds, in white on dark ones.

![every icon](../docs/os-icons.png)

## Layout

| Path | What |
|---|---|
| `windows.svg` | Windows logo (polygons, drawn directly at the final size) |
| `tux.svg` | Tux, the icon of **this** Ubuntu (rendered to `../theme/tux.png`) |
| `arrow.svg` | Selection arrow, vector trace of `Minimalist Black Navigation Arrow.png` |
| `os/<name>.svg` | Logo of another system (source) |
| `png/<name>.png` | The same logo as a black 1024 px PNG master, used by `scripts/generate-assets.sh` |

`<name>` is the name the GRUB hook gives the system (see *Supported systems*).
`scripts/render-masters.sh` rebuilds `../theme/tux.png` and `png/*.png` from the SVG
files with librsvg. Logos drawn with very thin lines (Kali, CentOS, elementary, KDE
neon, Debian) are made slightly bolder there, so they stay readable at icon size
(about 74 px at 1920x1080).

## Supported systems

A system gets an icon when it is found (see the main README, *Other systems*) and
`icons/png/<name>.png` exists. At most 6 icons are shown.

| Name | System | Simple Icons slug | Licence of the logo file |
|---|---|---|---|
| `kali` | Kali Linux | `kalilinux` | CC0 (Simple Icons) |
| `linuxmint` | Linux Mint | `linuxmint` | CC0 (Simple Icons) |
| `arch` | Arch Linux | `archlinux` | CC0 (Simple Icons) |
| `debian` | Debian | `debian` | CC BY-SA 3.0 |
| `fedora` | Fedora | `fedora` | Fedora brand terms ([docs.fedoraproject.org/en-US/project/brand](https://docs.fedoraproject.org/en-US/project/brand/)) |
| `opensuse` | openSUSE | `opensuse` | CC0 (Simple Icons) |
| `manjaro` | Manjaro | `manjaro` | CC0 (Simple Icons) |
| `ubuntu` | Ubuntu (another Ubuntu, found by os-prober; this one is Tux) | `ubuntu` | CC0 (Simple Icons) |
| `popos` | Pop!_OS | `popos` | CC0 (Simple Icons) |
| `elementary` | elementary OS | `elementary` | CC0 (Simple Icons) |
| `zorin` | Zorin OS | `zorin` | CC0 (Simple Icons) |
| `endeavouros` | EndeavourOS | `endeavouros` | CC0 (Simple Icons) |
| `centos` | CentOS | `centos` | CC0 (Simple Icons) |
| `rocky` | Rocky Linux | `rockylinux` | CC BY-SA 4.0 |
| `almalinux` | AlmaLinux | `almalinux` | CC0 (Simple Icons) |
| `redhat` | Red Hat Enterprise Linux | `redhat` | CC0 (Simple Icons) |
| `gentoo` | Gentoo | `gentoo` | CC BY-SA 2.5 |
| `nixos` | NixOS | `nixos` | CC BY 4.0 |
| `mxlinux` | MX Linux | `mxlinux` | GPL-3.0-only |
| `kubuntu` | Kubuntu | `kubuntu` | CC0 (Simple Icons) |
| `xubuntu` | Xubuntu | `xubuntu` | CC0 (Simple Icons) |
| `lubuntu` | Lubuntu | `lubuntu` | CC0 (Simple Icons) |
| `ubuntumate` | Ubuntu MATE | `ubuntumate` | CC0 (Simple Icons) |
| `garuda` | Garuda Linux | `garudalinux` | GPL-3.0-only |
| `void` | Void Linux | `voidlinux` | CC0 (Simple Icons) |
| `alpine` | Alpine Linux | `alpinelinux` | CC0 (Simple Icons) |
| `slackware` | Slackware | `slackware` | CC0 (Simple Icons) |
| `solus` | Solus | `solus` | CC0 (Simple Icons) |
| `deepin` | deepin | `deepin` | CC0 (Simple Icons) |
| `parrot` | Parrot OS | `parrotsecurity` | CC0 (Simple Icons) |
| `qubes` | Qubes OS | `qubesos` | CC0 (Simple Icons) |
| `freebsd` | FreeBSD | `freebsd` | CC0 (Simple Icons) |
| `kdeneon` | KDE neon | `kdeneon` | CC0 (Simple Icons) |
| `artix` | Artix Linux | `artixlinux` | CC0 (Simple Icons) |
| `cachyos` | CachyOS | `cachyos` | CC0 (Simple Icons) |
| `android` | Android (Android-x86, Bliss OS) | `android` | CC BY 3.0 |
| `generic` | any other Linux found by os-prober (`>_` window) | – | drawn for grub-icon-menu |

## Sources and licences

* **`os/*.svg`** (except `generic.svg`): [Simple Icons](https://simpleicons.org) 16.34.0,
  downloaded from `cdn.jsdelivr.net/npm/simple-icons@16.34.0/icons/<slug>.svg`,
  unchanged. Simple Icons is CC0; the logos marked above carry the licence the
  project records for them (`data/simple-icons.json`). The logos are trademarks of
  their owners and are used only to label the boot entry of that system, as the
  Simple Icons disclaimer asks. Rendered PNGs of the CC BY-SA / GPL logos are under
  the same licence as their SVG.
* **`tux.svg`**: [Tux-icon-mono.svg](https://commons.wikimedia.org/wiki/File:Tux-icon-mono.svg)
  by Cowemoji, Wikimedia Commons, CC0 1.0, unchanged.
* **`windows.svg`**, **`os/generic.svg`**: drawn for grub-icon-menu. The Windows logo is a
  trademark of Microsoft; it only labels the entry that starts Windows.
* **`arrow.svg`**: vector trace of `Minimalist Black Navigation Arrow.png` (supplied by
  the user). Its four edges are straight, so the trace is exact (RMS error under 1 px
  at 1254 px).

## Adding a system

1. Put a one-colour SVG logo in `os/<name>.svg` (`<name>`: lowercase letters/digits).
2. Run `scripts/render-masters.sh` (needs librsvg: `sudo apt install librsvg2-bin`).
3. Teach the hook the name: `gim_os_kind` (words in the boot entry or os-prober title),
   `gim_os_name` (name in the menu) and `GIM_ALL_KINDS` in `grub.d/99_grub_icon_menu`.
4. `tests/run-tests.sh` checks that every known name has both files.
