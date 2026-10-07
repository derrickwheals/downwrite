#!/usr/bin/env python3
"""Generates the Downwrite app icon artwork (light + dark) with Pillow.

Outputs:
  Packaging/AppIcon-{light,dark}-1024.png   full-bleed squircle artwork
  Packaging/AppIcon.icns                    Finder icon (light artwork)
  Packaging/AppIcon.icon/                   Icon Composer bundle (system picks light/dark/tinted variants)
  Sources/Downwrite/Resources/AppIcon-{light,dark}.png   runtime Dock icons (swapped with the system appearance)
"""
import json, math, os, shutil
from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
S = 4            # supersampling
N = 1024 * S

def lerp(a, b, t): return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))

def gradient(top, bottom, size=N):
    img = Image.new("RGB", (size, size))
    px = img.load()
    for y in range(size):
        c = lerp(top, bottom, y / (size - 1))
        for x in range(size): px[x, y] = c
    return img

def squircle_mask(box, n=5.0):
    """Superellipse approximating Apple's continuous-corner icon shape."""
    l, t, r, b = box
    cx, cy, rx, ry = (l + r) / 2, (t + b) / 2, (r - l) / 2, (b - t) / 2
    pts = []
    for i in range(720):
        a = 2 * math.pi * i / 720
        c, s = math.cos(a), math.sin(a)
        pts.append((cx + rx * math.copysign(abs(c) ** (2 / n), c), cy + ry * math.copysign(abs(s) ** (2 / n), s)))
    m = Image.new("L", (N, N), 0)
    ImageDraw.Draw(m).polygon(pts, fill=255)
    return m

def glyph_layer(ink, caret, glow):
    """The 'd' and the caret on a transparent canvas."""
    layer = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    k = S
    ox = 18   # optical centring
    # bowl (ring)
    cx, cy, ro, ri = 430 + ox, 580, 196, 104
    d.ellipse([(cx - ro) * k, (cy - ro) * k, (cx + ro) * k, (cy + ro) * k], fill=ink)
    d.ellipse([(cx - ri) * k, (cy - ri) * k, (cx + ri) * k, (cy + ri) * k], fill=(0, 0, 0, 0))
    # stem
    d.rounded_rectangle([(534 + ox) * k, 236 * k, (626 + ox) * k, 776 * k], radius=46 * k, fill=ink, corners=(True, True, True, False))
    # re-cut the bowl hole where the stem overlapped it
    hole = Image.new("L", (N, N), 0)
    ImageDraw.Draw(hole).ellipse([(cx - ri) * k, (cy - ri) * k, (cx + ri) * k, (cy + ri) * k], fill=255)
    a = layer.getchannel("A")
    layer.putalpha(ImageChops.subtract(a, hole))
    # caret with a soft glow
    caret_box = [(700 + ox) * k, 420 * k, (742 + ox) * k, 776 * k]
    gm = Image.new("L", (N, N), 0)
    ImageDraw.Draw(gm).rounded_rectangle([caret_box[0] - 10 * k, caret_box[1] - 10 * k, caret_box[2] + 10 * k, caret_box[3] + 10 * k],
                                         radius=30 * k, fill=glow[3])
    gm = gm.filter(ImageFilter.GaussianBlur(26 * k))
    glow_img = Image.new("RGBA", (N, N), glow[:3] + (0,))
    glow_img.putalpha(gm)
    layer = Image.alpha_composite(glow_img, layer)
    ImageDraw.Draw(layer).rounded_rectangle(caret_box, radius=21 * k, fill=caret)
    return layer

def render(variant):
    if variant == "light":
        top, bottom = (252, 251, 255), (214, 220, 255)
        ink, caret, glow = (36, 38, 66, 255), (64, 84, 214, 255), (64, 84, 214, 70)
        edge = (255, 255, 255, 160)
    else:
        top, bottom = (58, 62, 128), (16, 17, 38)
        ink, caret, glow = (244, 243, 255, 255), (149, 164, 255, 255), (149, 164, 255, 150)
        edge = (255, 255, 255, 46)
    margin = 100 * S
    box = (margin, margin, N - margin, N - margin)
    mask = squircle_mask(box)
    bg = gradient(top, bottom).convert("RGBA")
    # soft top light
    lm = Image.new("L", (N, N), 0)
    ImageDraw.Draw(lm).ellipse([N * 0.1, -N * 0.45, N * 0.9, N * 0.45], fill=(70 if variant == "light" else 34))
    lm = lm.filter(ImageFilter.GaussianBlur(60 * S))
    light = Image.new("RGBA", (N, N), (255, 255, 255, 0))
    light.putalpha(lm)
    bg = Image.alpha_composite(bg, light)
    art = Image.alpha_composite(bg, glyph_layer(ink, caret, glow))
    # thin inner edge highlight
    ring = ImageChops.subtract(mask, mask.filter(ImageFilter.MinFilter(4 * S + 1)))
    edge_img = Image.new("RGBA", (N, N), edge)
    art = Image.composite(Image.alpha_composite(art, Image.composite(edge_img, Image.new("RGBA", (N, N), (0, 0, 0, 0)), ring)), art, mask)
    out = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    out.paste(art, (0, 0), mask)
    # drop shadow
    sm = Image.new("L", (N, N), 0)
    sm.paste(90, (0, 14 * S), mask)
    sm = sm.filter(ImageFilter.GaussianBlur(18 * S))
    shadow = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    shadow.putalpha(sm)
    final = Image.alpha_composite(shadow, out)
    return final.resize((1024, 1024), Image.LANCZOS), glyph_layer(ink, caret, glow).resize((1024, 1024), Image.LANCZOS), mask

def main():
    pk = os.path.join(ROOT, "Packaging"); os.makedirs(pk, exist_ok=True)
    res = os.path.join(ROOT, "Sources", "Downwrite", "Resources")
    arts = {}
    for v in ("light", "dark"):
        art, glyph, _ = render(v)
        arts[v] = (art, glyph)
        art.save(os.path.join(pk, f"AppIcon-{v}-1024.png"))
        art.resize((512, 512), Image.LANCZOS).save(os.path.join(res, f"AppIcon-{v}.png"), optimize=True)
    # Finder icon
    arts["light"][0].save(os.path.join(pk, "AppIcon.icns"), sizes=[(16, 16), (32, 32), (64, 64), (128, 128), (256, 256), (512, 512), (1024, 1024)])
    # Icon Composer bundle: flat background fill + glyph layer, with dark specialisation.
    icon = os.path.join(pk, "AppIcon.icon"); shutil.rmtree(icon, ignore_errors=True)
    os.makedirs(os.path.join(icon, "Assets"))
    arts["light"][1].save(os.path.join(icon, "Assets", "glyph.png"))
    arts["dark"][1].save(os.path.join(icon, "Assets", "glyph-dark.png"))
    spec = {
        "fill": {"automatic-gradient": "display-p3:0.93000,0.94000,1.00000,1.00000"},
        "fill-specializations": [
            {"appearance": "dark", "value": {"automatic-gradient": "display-p3:0.16000,0.17000,0.36000,1.00000"}},
        ],
        "groups": [{
            "layers": [{
                "image-name": "glyph.png", "name": "glyph", "glass": True,
                "image-name-specializations": [{"appearance": "dark", "value": "glyph-dark.png"}],
            }],
            "shadow": {"kind": "neutral", "opacity": 0.5},
            "translucency": {"enabled": True, "value": 0.4},
        }],
        "supported-platforms": {"squares": "shared"},
    }
    with open(os.path.join(icon, "icon.json"), "w") as f: json.dump(spec, f, indent=2)
    print("icons written")

main()
