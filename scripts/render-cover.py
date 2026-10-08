#!/usr/bin/env python3
"""Render the GitHub cover image of grub-icon-menu.

    python3 scripts/render-cover.py

Writes
    docs/cover.png           2560x1280, the banner at the top of the README
    docs/social-preview.png  1280x640, for GitHub: Settings -> Social preview

Needs only Pillow. The layout is 1280x640; everything is drawn 4x larger and
reduced, so edges are smooth. The two boot screens on the right use the same
icon sources as the real theme (theme/tux.png, icons/png/<name>.png and the
polygons of icons/windows.svg and icons/arrow.svg).
"""
import os
import random

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
W, H = 1280, 640
K = 4                                   # supersampling factor

BG_A = (13, 15, 20)                     # canvas, top left
BG_B = (22, 25, 33)                     # canvas, bottom right
ACCENT = (226, 54, 84)                  # ">_", chip dots, "$"
TEXT = (244, 246, 250)
TEXT_2 = (190, 197, 208)
TEXT_3 = (128, 137, 152)

WINDOWS = [[(0, 138), (432, 80), (432, 480), (0, 480)],
           [(474, 74), (1000, 0), (1000, 480), (474, 480)],
           [(0, 520), (432, 520), (432, 920), (0, 862)],
           [(474, 520), (1000, 520), (1000, 1000), (474, 926)]]
ARROW = [(224.47, 0), (448.94, 389.21), (224.47, 239.36), (0, 389.21)]
ARROW_SIZE = (448.94, 389.21)


def s(v):
    return round(v * K)


def mix(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


# ---------------------------------------------------------------- fonts

SANS = ["/usr/share/fonts/truetype/ubuntu/UbuntuSans[wdth,wght].ttf",
        "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"]
SANS_BOLD = ["/usr/share/fonts/truetype/noto/NotoSans-Bold.ttf",
             "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"]
MONO = ["/usr/share/fonts/opentype/urw-base35/NimbusMonoPS-Regular.otf",     # GRUB title
        "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"]
CODE = ["/usr/share/fonts/truetype/ubuntu/UbuntuSansMono[wght].ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"]


def _first(paths):
    for p in paths:
        if os.path.exists(p):
            return p
    raise SystemExit("no usable font found (tried %s)" % ", ".join(paths))


def sans(size, weight=400):
    path = _first(SANS)
    f = ImageFont.truetype(path, s(size))
    try:
        f.set_variation_by_axes([100, weight])      # Ubuntu Sans: width, weight
    except (OSError, ValueError):
        if weight >= 600:
            f = ImageFont.truetype(_first(SANS_BOLD), s(size))
    return f


def mono(size):
    return ImageFont.truetype(_first(MONO), s(size))


def code(size, weight=500):
    f = ImageFont.truetype(_first(CODE), s(size))
    try:
        f.set_variation_by_axes([weight])
    except (OSError, ValueError):
        pass
    return f


# ---------------------------------------------------------------- helpers

def gradient(w, h, a, b):
    """Diagonal gradient, computed small and enlarged (it is smooth anyway)."""
    g = Image.new("RGB", (64, 32))
    for y in range(32):
        for x in range(64):
            g.putpixel((x, y), mix(a, b, x / 63 * 0.65 + y / 31 * 0.35))
    return g.resize((w, h), Image.BICUBIC)


def glow(canvas, cx, cy, rx, ry, color, strength):
    """Soft radial light, added on top of the canvas."""
    small = Image.new("L", (W // 4, H // 4), 0)
    ImageDraw.Draw(small).ellipse(
        [(cx - rx) / 4, (cy - ry) / 4, (cx + rx) / 4, (cy + ry) / 4], fill=255)
    small = small.filter(ImageFilter.GaussianBlur(min(rx, ry) / 4 * 0.6))
    mask = small.resize(canvas.size, Image.BICUBIC).point(lambda v: round(v * strength))
    canvas.paste(Image.new("RGB", canvas.size, color), (0, 0), mask)


def rounded_mask(w, h, r):
    m = Image.new("L", (w, h), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, w - 1, h - 1], radius=r, fill=255)
    return m


def shadow(canvas, box, radius, offset, blur, opacity):
    x0, y0, x1, y1 = box
    pad = s(blur * 3)
    m = Image.new("L", (x1 - x0 + 2 * pad, y1 - y0 + 2 * pad), 0)
    ImageDraw.Draw(m).rounded_rectangle([pad, pad, pad + x1 - x0, pad + y1 - y0],
                                        radius=radius, fill=round(255 * opacity))
    m = m.filter(ImageFilter.GaussianBlur(s(blur)))
    canvas.paste((0, 0, 0), (x0 - pad, y0 - pad + s(offset)), m)


def polygon_icon(polys, src_size, height, color):
    """A polygon logo drawn directly at its final (supersampled) size."""
    sw, sh = src_size
    k = height / sh
    img = Image.new("RGBA", (round(sw * k) + 2, round(height) + 2), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    for poly in polys:
        d.polygon([(1 + x * k, 1 + y * k) for x, y in poly], fill=color + (255,))
    return img


def master_icon(path, box, color=None):
    """Icon master fitted into a box x box square; recoloured unless color is None."""
    im = Image.open(path).convert("RGBA")
    k = min(box / im.width, box / im.height)
    im = im.resize((max(1, round(im.width * k)), max(1, round(im.height * k))), Image.LANCZOS)
    if color is not None:
        solid = Image.new("RGBA", im.size, color + (255,))
        solid.putalpha(im.getchannel("A"))
        im = solid
    return im


def outlined(im, width, color):
    """Thin outline around an icon (the Tux on dark pictures)."""
    pad = width + 2
    big = Image.new("RGBA", (im.width + 2 * pad, im.height + 2 * pad), (0, 0, 0, 0))
    big.paste(im, (pad, pad))
    ring = big.getchannel("A").filter(ImageFilter.MaxFilter(2 * width + 1))
    out = Image.new("RGBA", big.size, color + (0,))
    out.putalpha(ring)
    out.alpha_composite(big)
    return out


def soft_shadow(layer, blur, opacity):
    a = layer.getchannel("A").filter(ImageFilter.GaussianBlur(blur))
    a = a.point(lambda v: round(v * opacity))
    sh = Image.new("RGBA", layer.size, (0, 0, 0, 0))
    sh.putalpha(a)
    return sh


def text_center(d, cx, y, txt, font, fill):
    l, t, r, b = d.textbbox((0, 0), txt, font=font)
    d.text((cx - (r - l) / 2 - l, y), txt, font=font, fill=fill)


# ---------------------------------------------------------------- pictures

def bokeh(w, h, seed=11):
    """A dark, out-of-focus 'photo' (crimson leaves at night)."""
    rnd = random.Random(seed)
    sw, sh = w // 2, h // 2
    img = gradient(sw, sh, (34, 10, 22), (12, 8, 18))
    layer = Image.new("RGBA", (sw, sh), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    palette = [(176, 28, 58), (214, 52, 72), (120, 18, 48), (232, 120, 70), (90, 30, 80)]
    for _ in range(46):
        r = rnd.uniform(0.05, 0.22) * sh
        x, y = rnd.uniform(-0.1, 1.1) * sw, rnd.uniform(-0.1, 1.1) * sh
        c = rnd.choice(palette)
        d.ellipse([x - r, y - r, x + r, y + r], fill=c + (rnd.randint(40, 120),))
    img.paste(layer.filter(ImageFilter.GaussianBlur(sh * 0.07)), (0, 0),
              layer.filter(ImageFilter.GaussianBlur(sh * 0.07)))
    small = Image.new("RGBA", (sw, sh), (0, 0, 0, 0))
    d = ImageDraw.Draw(small)
    for _ in range(14):
        r = rnd.uniform(0.01, 0.03) * sh
        x, y = rnd.uniform(0, 1) * sw, rnd.uniform(0, 1) * sh
        d.ellipse([x - r, y - r, x + r, y + r], fill=(255, 196, 150, rnd.randint(30, 80)))
    small = small.filter(ImageFilter.GaussianBlur(sh * 0.006))
    img.paste(small, (0, 0), small)
    # vignette: darker edges, calm middle where the icons are
    v = Image.new("L", (sw, sh), 0)
    ImageDraw.Draw(v).ellipse([-sw * 0.15, -sh * 0.2, sw * 1.15, sh * 1.2], fill=255)
    v = v.filter(ImageFilter.GaussianBlur(sh * 0.18))
    img = Image.composite(img, Image.new("RGB", (sw, sh), (6, 4, 8)), v)
    return img.resize((w, h), Image.BICUBIC)


def boot_screen(w, h, dark, icons, selected):
    """One grub-icon-menu screen, w x h in layout pixels."""
    W2, H2 = s(w), s(h)
    fg = (255, 255, 255) if dark else (0, 0, 0)
    scr = (bokeh(W2, H2) if dark else Image.new("RGB", (W2, H2), (255, 255, 255))).convert("RGBA")
    d = ImageDraw.Draw(scr)

    # thin frame with rounded corners
    inset = s(w * 0.012)
    d.rounded_rectangle([inset, inset, W2 - 1 - inset, H2 - 1 - inset],
                        radius=s(w * 0.008), outline=fg + (235,), width=max(2, s(0.9)))

    # title
    tf = mono(w * 0.028)
    top = s(h * 0.06)
    lay = Image.new("RGBA", scr.size, (0, 0, 0, 0))
    ld = ImageDraw.Draw(lay)
    text_center(ld, W2 / 2, top, ">_GRUB", tf, fg + (255,))
    text_center(ld, W2 / 2, top + s(w * 0.031), "BOOTMENU", tf, fg + (255,))

    # icon row, the arrow under the selected one
    ic = w * 0.078
    pitch = ic * 2
    cy = h * 0.5
    x0 = w / 2 - pitch * (len(icons) - 1) / 2
    for i, name in enumerate(icons):
        cx = x0 + i * pitch
        if name == "windows":
            im = polygon_icon(WINDOWS, (1000, 1000), s(ic * 0.9), fg)
        elif name == "tux":
            im = master_icon(os.path.join(ROOT, "theme", "tux.png"), s(ic))
            if dark:
                im = outlined(im, s(0.7), (235, 235, 235))
        else:
            im = master_icon(os.path.join(ROOT, "icons", "png", name + ".png"), s(ic), fg)
        lay.alpha_composite(im, (round(s(cx) - im.width / 2), round(s(cy) - im.height / 2)))
        if i == selected:
            ar = polygon_icon([ARROW], ARROW_SIZE, s(ic * 0.27), fg)
            lay.alpha_composite(ar, (round(s(cx) - ar.width / 2), round(s(cy + ic * 0.88))))

    if dark:                                  # soft shadow, as the real theme does
        scr.alpha_composite(soft_shadow(lay, s(2.2), 0.55))
    scr.alpha_composite(lay)
    return scr


def display(canvas, x, y, w, dark, icons, selected):
    """A boot screen in a slim bezel, with a drop shadow."""
    bezel = 7
    sw = w - 2 * bezel
    sh = round(sw * 9 / 16)
    h = sh + 2 * bezel
    box = (s(x), s(y), s(x + w), s(y + h))
    shadow(canvas, box, s(14), 22, 26, 0.65)

    body = Image.new("RGBA", (s(w), s(h)), (0, 0, 0, 0))
    bd = ImageDraw.Draw(body)
    bd.rounded_rectangle([0, 0, s(w) - 1, s(h) - 1], radius=s(14), fill=(9, 10, 14, 255),
                         outline=(255, 255, 255, 30), width=s(1))
    scr = boot_screen(sw, sh, dark, icons, selected)
    body.paste(scr, (s(bezel), s(bezel)), rounded_mask(scr.width, scr.height, s(5)))
    canvas.paste(body, (s(x), s(y)), body)


def chip(d, x, y, label, font):
    l, t, r, b = d.textbbox((0, 0), label, font=font)
    h = 34
    w = (r - l) / K + 44
    d.rounded_rectangle([s(x), s(y), s(x + w), s(y + h)], radius=s(h / 2),
                        fill=(255, 255, 255, 10), outline=(255, 255, 255, 40), width=s(1))
    d.ellipse([s(x + 15), s(y + h / 2 - 3.5), s(x + 22), s(y + h / 2 + 3.5)], fill=ACCENT + (255,))
    d.text((s(x + 31) - l, s(y + h / 2) - (t + b) / 2), label, font=font, fill=(222, 227, 235, 255))
    return w


# ---------------------------------------------------------------- cover

def cover():
    canvas = gradient(s(W), s(H), BG_A, BG_B)
    glow(canvas, 1010, 330, 430, 300, (150, 22, 52), 0.30)
    glow(canvas, 140, 80, 420, 260, (40, 56, 92), 0.22)

    # faint dot grid, fading towards the bottom right
    dots = Image.new("L", canvas.size, 0)
    dd = ImageDraw.Draw(dots)
    for gy in range(12, H, 24):
        for gx in range(12, W, 24):
            fade = max(0.0, 1 - (gx / W * 0.8 + gy / H * 0.6))
            if fade > 0:
                dd.ellipse([s(gx - 1), s(gy - 1), s(gx + 1), s(gy + 1)], fill=round(46 * fade))
    canvas.paste((255, 255, 255), (0, 0), dots)

    canvas = canvas.convert("RGBA")
    display(canvas, 790, 70, 430, True, ["windows", "tux", "fedora", "arch"], 2)
    display(canvas, 652, 268, 510, False, ["windows", "tux", "kali", "linuxmint"], 1)

    over = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(over)
    left = 76

    eyebrow = code(17, 600)
    d.text((s(left), s(134)), ">_", font=eyebrow, fill=ACCENT + (255,))
    l, t, r, b = d.textbbox((0, 0), ">_ ", font=eyebrow)
    d.text((s(left) + r, s(134)), "GRUB / BOOTMENU", font=eyebrow, fill=TEXT_3 + (255,))

    d.text((s(left - 3), s(160)), "grub-icon-menu", font=sans(64, 700), fill=TEXT + (255,))

    tag = sans(23, 400)
    d.text((s(left), s(258)), "An icon-only GRUB boot menu for Ubuntu.", font=tag, fill=TEXT_2 + (255,))
    d.text((s(left), s(292)), "Windows starts without the BitLocker key.", font=tag, fill=TEXT_2 + (255,))

    cf = sans(15.5, 500)
    x = left
    for label in ("37 OS logos", "Background pictures"):
        x += chip(d, x, 360, label, cf) + 10
    x = left
    for label in ("Secure Boot friendly", "Backup & rollback"):
        x += chip(d, x, 404, label, cf) + 10

    cmd = code(16.5, 500)
    line = "sudo ./install.sh -bg wallpaper.jpg"
    l, t, r, b = d.textbbox((0, 0), line, font=cmd)
    y, h = 474, 46
    d.rounded_rectangle([s(left), s(y), s(left + 50) + r, s(y + h)], radius=s(10),
                        fill=(0, 0, 0, 90), outline=(255, 255, 255, 34), width=s(1))
    ty = s(y + h / 2) - (t + b) / 2
    d.text((s(left + 18), ty), "$", font=cmd, fill=ACCENT + (255,))
    d.text((s(left + 36), ty), line, font=cmd, fill=(214, 220, 230, 255))

    canvas.alpha_composite(over)
    return canvas.convert("RGB")


def main():
    img = cover()
    docs = os.path.join(ROOT, "docs")
    big = img.resize((W * 2, H * 2), Image.LANCZOS)
    big.save(os.path.join(docs, "cover.png"), optimize=True)
    small = img.resize((W, H), Image.LANCZOS)
    small.save(os.path.join(docs, "social-preview.png"), optimize=True)
    for name in ("cover.png", "social-preview.png"):
        p = os.path.join(docs, name)
        print("%-40s %d KB" % (os.path.relpath(p, ROOT), os.path.getsize(p) // 1024))


if __name__ == "__main__":
    main()
