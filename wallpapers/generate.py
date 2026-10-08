#!/usr/bin/env python3
"""Render the neumorphic 1920x1080 wallpapers in this folder.

    python3 wallpapers/generate.py          # all of them
    python3 wallpapers/generate.py 06 08    # only those numbers

Needs only Pillow. Every shape is drawn at 4x and scaled down (smooth edges);
light always comes from the top-left, as neumorphism expects.
"""
import math
import os
import random
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter

W, H = 1920, 1080
SS = 4
OUT = os.path.dirname(os.path.abspath(__file__))


def rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def mix(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def ramp(stops, t):
    t = min(max(t, 0.0), 1.0)
    p = t * (len(stops) - 1)
    i = min(int(p), len(stops) - 2)
    return mix(stops[i], stops[i + 1], p - i)


# ---------------------------------------------------------------- masks

def _box(cx, cy, r, s):
    return [(cx - r) * s, (cy - r) * s, (cx + r) * s, (cy + r) * s]


def mask(draw):
    """Draw with draw(ImageDraw, scale) at SS x and return a smooth W x H mask."""
    m = Image.new("L", (W * SS, H * SS), 0)
    draw(ImageDraw.Draw(m), SS)
    return m.resize((W, H), Image.BOX)


def circle(cx, cy, r):
    return mask(lambda d, s: d.ellipse(_box(cx, cy, r, s), fill=255))


def circles(pts):
    return mask(lambda d, s: [d.ellipse(_box(x, y, r, s), fill=255) for x, y, r in pts])


def ring(cx, cy, ro, ri):
    def f(d, s):
        d.ellipse(_box(cx, cy, ro, s), fill=255)
        d.ellipse(_box(cx, cy, ri, s), fill=0)
    return mask(f)


def rrect(x0, y0, x1, y1, rad):
    return mask(lambda d, s: d.rounded_rectangle([x0 * s, y0 * s, x1 * s, y1 * s],
                                                 radius=rad * s, fill=255))


def pill(x0, y0, x1, y1, w):
    def f(d, s):
        d.line([x0 * s, y0 * s, x1 * s, y1 * s], fill=255, width=round(w * s))
        d.ellipse(_box(x0, y0, w / 2, s), fill=255)
        d.ellipse(_box(x1, y1, w / 2, s), fill=255)
    return mask(f)


def arc(cx, cy, r, w, a0, a1):
    """Round-capped stroke centred on radius r, PIL angles (0 = 3 o'clock, clockwise)."""
    def f(d, s):
        d.arc(_box(cx, cy, r + w / 2, s), a0, a1, fill=255, width=round(w * s))
        for a in (a0, a1):
            a = math.radians(a)
            d.ellipse(_box(cx + r * math.cos(a), cy + r * math.sin(a), w / 2, s), fill=255)
    return mask(f)


def polygon(pts):
    return mask(lambda d, s: d.polygon([(x * s, y * s) for x, y in pts], fill=255))


def union(*ms):
    out = ms[0]
    for m in ms[1:]:
        out = ImageChops.lighter(out, m)
    return out


# ---------------------------------------------------------------- colour fills

def solid(c):
    return Image.new("RGB", (W, H), c)


def _ramp_strip(horizontal):
    g = Image.new("L", (256, 1) if horizontal else (1, 256))
    g.putdata(list(range(256)))
    return g


def grad(bbox, c0, c1, horizontal=True, vertical=True):
    """c0 at the top-left of bbox fading to c1 at the bottom-right (or one axis only)."""
    x0, y0, x1, y1 = (round(v) for v in bbox)
    w, h = max(x1 - x0, 1), max(y1 - y0, 1)
    hg = _ramp_strip(True).resize((w, h), Image.BILINEAR)
    vg = _ramp_strip(False).resize((w, h), Image.BILINEAR)
    if horizontal and vertical:
        t = ImageChops.add(hg, vg, scale=2.0)
    else:
        t = hg if horizontal else vg
    tile = Image.composite(Image.new("RGB", (w, h), c1), Image.new("RGB", (w, h), c0), t)
    out = solid(c0)
    out.paste(tile, (x0, y0))
    return out


def radial(cx, cy, r, c_in, c_out):
    r = round(r)
    g = Image.radial_gradient("L").resize((2 * r, 2 * r), Image.BILINEAR)
    a = Image.new("L", (W, H), 255)
    a.paste(g, (round(cx) - r, round(cy) - r))
    return Image.composite(solid(c_out), solid(c_in), a)


def conic(cx, cy, r, stops, a0=0.0, a1=360.0):
    """Colour follows the angle around (cx, cy), from a0 to a1 (PIL degrees)."""
    x0, y0, n = int(cx - r), int(cy - r), int(2 * r) + 1
    tile = Image.new("RGB", (n, n))
    px = tile.load()
    span = a1 - a0
    for y in range(n):
        dy = y + y0 - cy
        for x in range(n):
            d = (math.degrees(math.atan2(dy, x + x0 - cx)) - a0) % 360
            if d > span:
                d = 0 if 360 - d < d - span else span
            px[x, y] = ramp(stops, d / span)
    out = solid(stops[0])
    out.paste(tile, (x0, y0))
    return out


# ---------------------------------------------------------------- neumorphism

class Theme:
    def __init__(self, bg, dark, light, top_left, bottom_right):
        self.bg, self.dark, self.light = rgb(bg), rgb(dark), rgb(light)
        self.base = grad((0, 0, W, H), rgb(top_left), rgb(bottom_right))


def scale(m, k):
    return m.point(lambda v: min(255, round(v * k)))


def shift(m, dx, dy, fill=0):
    o = Image.new("L", m.size, fill)
    o.paste(m, (round(dx), round(dy)))
    return o


def blur(m, r):
    return m.filter(ImageFilter.GaussianBlur(r))


def paint(img, colour, alpha):
    fill = colour if isinstance(colour, Image.Image) else solid(colour)
    return Image.composite(fill, img, alpha)


def convex(t, bbox, k=1.0):
    """Surface lit at the top-left, a little darker at the bottom-right."""
    return grad(bbox, mix(t.bg, t.light, 0.55 * k), mix(t.bg, t.dark, 0.22 * k))


def concave(t, bbox, k=1.0):
    return grad(bbox, mix(t.bg, t.dark, 0.22 * k), mix(t.bg, t.light, 0.45 * k))


def raised(img, m, t, d, r, surface=None, kd=1.0, kl=1.0):
    """Shape floating above the surface: dark shadow down-right, light one up-left."""
    img = paint(img, t.dark, scale(blur(shift(m, d, d), r), kd))
    img = paint(img, t.light, scale(blur(shift(m, -d, -d), r), kl))
    return paint(img, t.base if surface is None else surface, m)


def inner(img, m, t, d, r, kd=1.0, kl=1.0):
    """Shadows on the inside walls of a pressed shape."""
    inv = ImageChops.invert(m)
    a = ImageChops.multiply(blur(shift(inv, d, d, 255), r), m)
    img = paint(img, t.dark, scale(a, kd))
    a = ImageChops.multiply(blur(shift(inv, -d, -d, 255), r), m)
    return paint(img, t.light, scale(a, kl))


def inset(img, m, t, d, r, surface=None, kd=1.0, kl=1.0):
    """Shape pressed into the surface."""
    img = paint(img, t.base if surface is None else surface, m)
    return inner(img, m, t, d, r, kd, kl)


def engrave(img, m, t, colour):
    """Thin carved line art: a light lip below-right, then the line."""
    img = paint(img, t.light, scale(shift(m, 1, 1), 0.9))
    return paint(img, colour, m)


def glow(img, m, colour, r, k):
    """Additive light (screen blend) for dark themes."""
    fill = colour if isinstance(colour, Image.Image) else solid(colour)
    layer = Image.composite(fill, solid((0, 0, 0)), scale(blur(m, r), k))
    return ImageChops.screen(img, layer)


def tinted_shadow(img, m, colour, dy, r, k):
    """Soft coloured shadow under an accent on light themes."""
    return paint(img, colour, scale(blur(shift(m, 0, dy), r), k))


def finish(img, name, grain=1.6):
    noise = Image.effect_noise((W, H), grain)  # centred on 128; breaks up gradient banding
    img = ImageChops.add(img, Image.merge("RGB", (noise, noise, noise)), 1.0, -128)
    path = os.path.join(OUT, name)
    img.save(path, optimize=True)
    print("wrote", path)


def polar(cx, cy, r, deg):
    a = math.radians(deg)
    return cx + r * math.cos(a), cy + r * math.sin(a)


# ================================================================ 1. white dial

def white_dial():
    t = Theme("#ECEFF4", "#C3CAD6", "#FFFFFF", "#F3F5F9", "#E4E8EE")
    img = t.base.copy()
    blue, violet = rgb("#5B9BFF"), rgb("#7B61FF")
    cx, cy, R = 640, 540, 330

    img = raised(img, circle(cx, cy, R), t, 30, 46)

    a0, a1 = 135, 135 + 270 * 0.72
    ticks = [(*polar(cx, cy, 306, 135 + i * 270 / 30), 3.4 if i % 5 else 5) for i in range(31)]
    img = inset(img, circles(ticks), t, 1, 1.2, surface=mix(t.bg, t.dark, 0.55), kd=0.6)

    img = inset(img, ring(cx, cy, 282, 222), t, 9, 11)
    am = arc(cx, cy, 252, 22, a0, a1)
    img = tinted_shadow(img, am, violet, 6, 12, 0.35)
    img = paint(img, conic(cx, cy, 300, [blue, violet], a0, a1), am)
    img = inner(img, am, t, 3, 3.5, kd=0.55, kl=0.5)
    kx, ky = polar(cx, cy, 252, a1)
    img = raised(img, circle(kx, ky, 16), t, 4, 6, surface=convex(t, (kx - 16, ky - 16, kx + 16, ky + 16)))

    img = raised(img, circle(cx, cy, 172), t, 18, 28, surface=convex(t, (cx - 172, cy - 172, cx + 172, cy + 172)))
    px, py = polar(cx, cy, 132, a1)
    dot = circle(px, py, 9)
    img = tinted_shadow(img, dot, violet, 3, 7, 0.45)
    img = paint(img, violet, dot)
    img = inset(img, circle(cx, cy, 54), t, 7, 8, surface=concave(t, (cx - 54, cy - 54, cx + 54, cy + 54)))

    # quiet companions on the right
    img = raised(img, circle(1530, 300, 92), t, 14, 22, surface=convex(t, (1438, 208, 1622, 392), 0.7))
    img = inset(img, circle(1530, 300, 40), t, 6, 7)
    for i, x in enumerate((1450, 1530, 1610)):
        m = circle(x, 820, 18)
        img = inset(img, m, t, 4, 5) if i == 1 else raised(img, m, t, 6, 9)
    dot = circle(1530, 820, 7)
    img = tinted_shadow(img, dot, violet, 2, 5, 0.4)
    img = paint(img, violet, dot)
    return finish(img, "01-white-dial.png")


# ================================================================ 2. white controls

def white_controls():
    t = Theme("#EFF0F3", "#CBCFD8", "#FFFFFF", "#F5F6F8", "#E7E8EC")
    img = t.base.copy()
    blue, violet = rgb("#6C8CFF"), rgb("#9A6BFF")
    icon = rgb("#A4AABA")

    # balancing shapes on the left
    img = raised(img, circle(170, 1010, 330), t, 28, 46, surface=convex(t, (-160, 680, 500, 1340), 0.8))
    img = inset(img, circle(170, 1010, 210), t, 16, 20)
    img = raised(img, circle(170, 1010, 120), t, 14, 20, surface=convex(t, (50, 890, 290, 1130)))
    img = inset(img, circle(330, 250, 70), t, 9, 12)

    x0, x1 = 1110, 1690

    # toggle, switched on
    tr = (x0, 250, x0 + 330, 390)
    tm = rrect(*tr, 70)
    img = inset(img, tm, t, 9, 12, surface=grad(tr, blue, violet, vertical=False), kd=0.8)
    img = raised(img, circle(tr[2] - 70, 320, 54), t, 9, 13, kl=0.35,
                 surface=convex(t, (tr[2] - 124, 266, tr[2] - 16, 374), 1.4))

    # power button
    bx, by = 1610, 320
    img = raised(img, circle(bx, by, 80), t, 14, 20)
    pw = union(arc(bx, by, 28, 7, 300, 600), pill(bx, by - 42, bx, by - 14, 7))
    img = engrave(img, pw, t, icon)

    # slider
    sy, frac = 520, 0.64
    img = inset(img, rrect(x0, sy - 15, x1, sy + 15, 15), t, 5, 6)
    fx = x0 + (x1 - x0) * frac
    fm = rrect(x0 + 6, sy - 8, fx, sy + 8, 8)
    img = tinted_shadow(img, fm, violet, 3, 6, 0.25)
    img = paint(img, grad((x0, sy, fx, sy + 1), blue, violet, vertical=False), fm)
    img = raised(img, circle(fx, sy, 34), t, 8, 12, surface=convex(t, (fx - 34, sy - 34, fx + 34, sy + 34), 1.2))
    img = paint(img, violet, circle(fx, sy, 7))

    # media keys: previous, play (pressed), next
    size, top = 150, 650
    xs = [x0, (x0 + x1 - size) / 2, x1 - size]
    for i, x in enumerate(xs):
        m = rrect(x, top, x + size, top + size, 42)
        img = inset(img, m, t, 10, 13) if i == 1 else raised(img, m, t, 14, 20)
    cy = top + size / 2
    cx = xs[0] + size / 2
    prev = union(polygon([(cx + 18, cy - 20), (cx + 18, cy + 20), (cx - 10, cy)]),
                 rrect(cx - 22, cy - 20, cx - 15, cy + 20, 3))
    img = engrave(img, prev, t, icon)
    cx = xs[2] + size / 2
    nxt = union(polygon([(cx - 18, cy - 20), (cx - 18, cy + 20), (cx + 10, cy)]),
                rrect(cx + 15, cy - 20, cx + 22, cy + 20, 3))
    img = engrave(img, nxt, t, icon)
    cx = xs[1] + size / 2
    play = polygon([(cx - 14, cy - 24), (cx - 14, cy + 24), (cx + 26, cy)])
    img = tinted_shadow(img, play, violet, 3, 6, 0.35)
    img = paint(img, grad((cx - 14, cy - 24, cx + 26, cy + 24), blue, violet), play)
    return finish(img, "02-white-controls.png")


# ================================================================ 3. white layers

def white_layers():
    t = Theme("#F3F0EB", "#D2CABE", "#FFFFFF", "#F7F5F1", "#ECE8E1")
    img = t.base.copy()

    for r in (1010, 890, 770, 650, 530, 410, 290):
        img = raised(img, circle(2010, 1190, r), t, 15, 28)
    for r in (600, 480, 360, 240):
        img = raised(img, circle(-70, -90, r), t, 15, 28)

    # one small pearl resting between the two stacks
    px, py, pr = 760, 700, 38
    peach = radial(px - 12, py - 14, pr * 1.35, rgb("#FFE6D6"), rgb("#E9A27E"))
    img = raised(img, circle(px, py, pr), t, 8, 14, surface=peach)
    return finish(img, "03-white-layers.png", grain=1.4)


# ================================================================ 4. midnight orbit

def midnight_orbit():
    t = Theme("#23262C", "#16181C", "#30343C", "#282B32", "#1C1E23")
    img = t.base.copy()
    teal, violet, pink = rgb("#22D3EE"), rgb("#8B5CF6"), rgb("#F472B6")
    cx, cy = 1250, 540

    img = glow(img, circle(cx, cy, 260), violet, 160, 0.16)

    for r in (330, 430, 520):
        img = inset(img, ring(cx, cy, r + 4, r - 4), t, 2, 2.5, kd=1.0, kl=0.8)

    img = inset(img, circle(cx, cy, 250), t, 18, 24, kd=1.0, kl=0.9)
    colours = conic(cx, cy, 320, [teal, violet, pink, teal])
    rm = ring(cx, cy, 222, 216)
    img = glow(img, rm, colours, 40, 1.0)
    img = glow(img, rm, colours, 14, 1.0)
    img = glow(img, rm, colours, 4, 1.0)
    img = paint(img, colours, rm)
    img = raised(img, circle(cx, cy, 190), t, 20, 34,
                 surface=grad((cx - 190, cy - 190, cx + 190, cy + 190), rgb("#2F333B"), rgb("#1D1F24")),
                 kd=1.0, kl=0.9)
    img = inset(img, circle(cx, cy, 70), t, 8, 10)

    planets = [(330, 205, 22, None), (430, 318, 15, teal), (520, 158, 30, None),
               (520, 20, 11, pink), (430, 112, 9, None)]
    for orbit, deg, pr, accent in planets:
        x, y = polar(cx, cy, orbit, deg)
        m = circle(x, y, pr)
        if accent:
            img = glow(img, m, accent, pr * 1.4, 0.8)
            img = paint(img, radial(x - pr * 0.35, y - pr * 0.35, pr * 1.3, mix(accent, (255, 255, 255), 0.45), accent), m)
        else:
            img = raised(img, m, t, max(3, pr // 4), pr / 2.2,
                         surface=grad((x - pr, y - pr, x + pr, y + pr), rgb("#343842"), rgb("#1E2025")))
    return finish(img, "04-midnight-orbit.png", grain=1.8)


# ================================================================ 5. lavender capsules

def lavender_capsules():
    t = Theme("#DEE0F3", "#B6BADB", "#FAFBFF", "#E5E7F7", "#D5D8EE")
    img = t.base.copy()
    a, b = rgb("#8B7CF6"), rgb("#E98BC6")
    ang = math.radians(-32)
    u = (math.cos(ang), math.sin(ang))
    n = (-u[1], u[0])
    ox, oy = W / 2, H / 2
    thick, gap = 84, 148

    # (lane, start along lane, length, kind) - kind: r raised, i inset, a accent
    caps = [
        (-5, -560, 380, "r"), (-5, -60, 220, "i"),
        (-4, -880, 300, "i"), (-4, -460, 460, "r"),
        (-3, -1040, 420, "r"), (-3, -500, 180, "a"),
        (-2, -1100, 340, "i"), (-2, -640, 240, "r"),
        (-1, -1150, 260, "r"),
        (0, 760, 300, "r"),
        (1, 560, 220, "i"), (1, 880, 360, "r"),
        (2, 360, 420, "r"), (2, 880, 200, "i"),
        (3, 220, 160, "a"), (3, 480, 380, "i"),
        (4, 120, 300, "r"), (4, 520, 220, "r"),
        (5, -60, 260, "i"), (5, 300, 340, "r"),
    ]
    for lane, s0, length, kind in caps:
        bx, by = ox + n[0] * lane * gap, oy + n[1] * lane * gap
        x0, y0 = bx + u[0] * s0, by + u[1] * s0
        x1, y1 = bx + u[0] * (s0 + length), by + u[1] * (s0 + length)
        m = pill(x0, y0, x1, y1, thick)
        bbox = (min(x0, x1) - thick, min(y0, y1) - thick, max(x0, x1) + thick, max(y0, y1) + thick)
        if kind == "i":
            img = inset(img, m, t, 10, 13)
        elif kind == "a":
            img = raised(img, m, t, 14, 22, surface=grad(bbox, a, b), kd=0.9)
        else:
            img = raised(img, m, t, 14, 22, surface=convex(t, bbox, 0.8))
    return finish(img, "05-lavender-capsules.png")


# ================================================================ edge-border series (white)

def _outside(x, y, rx, ry):
    """True when (x, y) lies outside the clear ellipse in the middle of the screen."""
    return ((x - W / 2) / rx) ** 2 + ((y - H / 2) / ry) ** 2 > 1


def white_capsules():
    t = Theme("#ECEFF5", "#B6BECE", "#FFFFFF", "#F2F4F8", "#E3E7EE")
    img = t.base.copy()
    a, b = rgb("#5B8CFF"), rgb("#4FD1E8")
    rng = random.Random(11)
    ang = math.radians(30)
    u = (math.cos(ang), math.sin(ang))
    n = (-u[1], u[0])
    thick, gap = 84, 150

    def fits(bx, by, s0, s1):
        pts = [(bx + u[0] * (s0 + (s1 - s0) * k / 4), by + u[1] * (s0 + (s1 - s0) * k / 4)) for k in range(5)]
        return (all(_outside(x, y, 440, 760) for x, y in pts)
                and any(-thick < x < W + thick and -thick < y < H + thick for x, y in pts))

    pills = []
    for lane in range(-12, 13):
        bx, by = W / 2 + n[0] * lane * gap, H / 2 + n[1] * lane * gap
        s = -1500 + rng.uniform(0, 300)
        while s < 1500:
            length = rng.choice((140, 200, 260, 340, 420))
            # capsules that reach into the clear middle get shortened from that end
            for cut in range(0, length - 100, 40):
                seg = next(((s0, s1) for s0, s1 in ((s + cut, s + length), (s, s + length - cut))
                            if fits(bx, by, s0, s1)), None)
                if seg:
                    pills.append(tuple((bx + u[0] * v, by + u[1] * v) for v in seg))
                    break
            s += length + thick + rng.uniform(40, 200)

    def visible(p):
        return all(thick / 2 < x < W - thick / 2 and thick / 2 < y < H - thick / 2 for x, y in p)

    def short(p):
        return visible(p) and math.dist(*p) <= 300

    def off_mid(p):
        return 0.6 * abs((p[0][1] + p[1][1]) / 2 - H / 2)

    left = max((p for p in pills if short(p) and p[0][0] < W / 2), key=lambda p: p[1][0] - off_mid(p))
    right = min((p for p in pills if short(p) and p[0][0] > W / 2), key=lambda p: p[0][0] + off_mid(p))
    for p in pills:
        (x0, y0), (x1, y1) = p
        m = pill(x0, y0, x1, y1, thick)
        bbox = (min(x0, x1) - thick, min(y0, y1) - thick, max(x0, x1) + thick, max(y0, y1) + thick)
        if p in (left, right):
            img = raised(img, m, t, 14, 22, surface=grad(bbox, a, b), kd=0.9)
        elif rng.random() < 0.33:
            img = inset(img, m, t, 10, 13)
        else:
            img = raised(img, m, t, 14, 22, surface=convex(t, bbox, 0.8))
    return finish(img, "06-white-capsules.png")


def white_bubbles():
    t = Theme("#EFF0F4", "#BDC1CC", "#FFFFFF", "#F5F6F9", "#E6E7EC")
    img = t.base.copy()
    a, b = rgb("#8B7CF6"), rgb("#E98BC6")
    rng = random.Random(5)

    placed = []
    for r in sorted((26 + 150 * rng.random() ** 1.8 for _ in range(500)), reverse=True):
        for _ in range(400):
            x, y = rng.uniform(-0.5 * r, W + 0.5 * r), rng.uniform(-0.5 * r, H + 0.5 * r)
            if not _outside(x, y, 1060 + r, 290 + r):
                continue
            if any(math.hypot(x - px, y - py) < r + pr + 30 for px, py, pr in placed):
                continue
            placed.append((x, y, r))
            break
        if len(placed) >= 56:
            break

    # the three small bubbles closest to the clear middle become the accents
    small = [c for c in placed if 30 < c[2] < 64 and 0 < c[0] < W and 0 < c[1] < H]
    accents = sorted(small, key=lambda c: ((c[0] - W / 2) / 1060) ** 2 + ((c[1] - H / 2) / 290) ** 2)[:3]
    for x, y, r in placed:
        m = circle(x, y, r)
        d, bl = max(4, r * 0.12), r * 0.22 + 3
        box = (x - r, y - r, x + r, y + r)
        if (x, y, r) in accents:
            img = raised(img, m, t, d, bl, kd=0.9,
                         surface=radial(x - r * 0.35, y - r * 0.35, r * 1.4, mix(a, (255, 255, 255), 0.35), b))
        elif rng.random() < 0.35:
            img = inset(img, m, t, d * 0.8, bl * 0.8)
            if r > 80:
                ri = r * 0.55
                img = raised(img, circle(x, y, ri), t, ri * 0.12, ri * 0.22 + 2,
                             surface=convex(t, (x - ri, y - ri, x + ri, y + ri)))
        else:
            img = raised(img, m, t, d, bl, surface=convex(t, box, 0.8))
    return finish(img, "07-white-bubbles.png")


def white_tiles():
    t = Theme("#F2F1EE", "#C6C0B5", "#FFFFFF", "#F7F6F3", "#E9E7E2")
    img = t.base.copy()
    a, b = rgb("#FFB48A"), rgb("#FF7A85")
    rng = random.Random(3)
    step, big, reach = 132, 104, 980

    tiles = []
    for j in range(-5, 6):
        for i in range(-8, 9):
            x, y = W / 2 + i * step, H / 2 + j * step
            f = 1 - min(math.hypot(x, y), math.hypot(W - x, H - y)) / reach
            size = big * max(f, 0) ** 0.75
            if size >= 20:
                tiles.append((x, y, size))

    mid = [c for c in tiles if 48 < c[2] < 80 and c[2] < c[0] < W - c[2] and c[2] < c[1] < H - c[2]]
    accents = rng.sample(mid, 3)
    for x, y, size in tiles:
        h = size / 2
        m = rrect(x - h, y - h, x + h, y + h, size * 0.3)
        d, bl = max(3, size * 0.12), size * 0.2 + 2
        box = (x - h, y - h, x + h, y + h)
        if (x, y, size) in accents:
            img = raised(img, m, t, d, bl, surface=grad(box, a, b), kd=0.9)
        elif size > 40 and rng.random() < 0.22:
            img = inset(img, m, t, d * 0.8, bl * 0.8)
        else:
            img = raised(img, m, t, d, bl, surface=convex(t, box, 0.8))
    return finish(img, "08-white-tiles.png")


ALL = {
    "01": white_dial,
    "02": white_controls,
    "03": white_layers,
    "04": midnight_orbit,
    "05": lavender_capsules,
    "06": white_capsules,
    "07": white_bubbles,
    "08": white_tiles,
}

if __name__ == "__main__":
    for key in sys.argv[1:] or ALL:
        ALL[key]()
