"""三个极简方向：A 墨笺  B 素纸  C 朱印"""
import math, os, sys, random
from PIL import Image, ImageDraw, ImageFilter, ImageChops

S = 4096; k = S / 1024
def sc(v): return int(round(v * k))

def squircle(cx, cy, w, h, n=5.0, steps=900):
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        c, s = math.cos(t), math.sin(t)
        pts.append((cx + w / 2 * math.copysign(abs(c) ** (2 / n), c),
                    cy + h / 2 * math.copysign(abs(s) ** (2 / n), s)))
    return pts

def vgrad(top, bottom):
    g = Image.new("RGB", (1, 256))
    for y in range(256):
        u = y / 255
        g.putpixel((0, y), tuple(int(top[i] + (bottom[i] - top[i]) * u) for i in range(3)))
    return g.resize((S, S), Image.BICUBIC).convert("RGBA")

def radial_light(strength, cy=0.28, radius=0.75):
    m = Image.new("L", (S, S), 0)
    r = sc(1024 * radius / 2)
    ImageDraw.Draw(m).ellipse([S / 2 - r, S * cy - r, S / 2 + r, S * cy + r], fill=strength)
    return m.filter(ImageFilter.GaussianBlur(sc(160)))

def grain(amount):
    random.seed(7)
    small = Image.effect_noise((S // 4, S // 4), 40).resize((S, S), Image.BICUBIC)
    return small.point(lambda v: int(abs(v - 128) / 128 * amount))

def base(top, bottom, light=40, light_color=(255, 255, 255), noise=0):
    canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).polygon(squircle(S / 2, S / 2, sc(824), sc(824)), fill=255)
    sh = Image.new("L", (S, S), 0)
    ImageDraw.Draw(sh).polygon(squircle(S / 2, S / 2 + sc(12), sc(824), sc(824)), fill=95)
    sh = sh.filter(ImageFilter.GaussianBlur(sc(16)))
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 255)); shadow.putalpha(sh)
    canvas = Image.alpha_composite(canvas, shadow)
    bg = vgrad(top, bottom)
    if light:
        bg = Image.composite(Image.new("RGBA", (S, S), light_color + (255,)), bg, radial_light(light))
    if noise:
        bg = Image.composite(Image.new("RGBA", (S, S), (0, 0, 0, 255)), bg, grain(noise))
    bg.putalpha(mask)
    # 极细的内描边，增加质感
    edge = Image.new("L", (S, S), 0)
    ImageDraw.Draw(edge).polygon(squircle(S / 2, S / 2, sc(824), sc(824)), outline=255, width=sc(3))
    edge = ImageChops.multiply(edge, mask).point(lambda v: v * 0.25)
    rim = Image.new("RGBA", (S, S), (255, 255, 255, 255)); rim.putalpha(edge)
    canvas = Image.alpha_composite(canvas, bg)
    canvas = Image.alpha_composite(canvas, rim)
    return canvas, mask

def soft_shadow(shape_mask, mask, offset, blur, opacity, color=(0, 0, 0)):
    s = shape_mask.filter(ImageFilter.GaussianBlur(sc(blur)))
    s = ImageChops.offset(s, 0, sc(offset)).point(lambda v: int(v * opacity))
    layer = Image.new("RGBA", (S, S), color + (255,)); layer.putalpha(ImageChops.multiply(s, mask))
    return layer

def note_shape(x, y, w, h, r, fold):
    """带右上折角的便签外形（返回 mask 与折角三角）"""
    m = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(m)
    X0, Y0, X1, Y1 = sc(x), sc(y), sc(x + w), sc(y + h)
    d.rounded_rectangle([X0, Y0, X1, Y1], radius=sc(r), fill=255)
    F = sc(fold)
    d.polygon([(X1 - F, Y0 - 4), (X1 + 4, Y0 - 4), (X1 + 4, Y0 + F)], fill=0)
    tri = [(X1 - F, Y0), (X1, Y0 + F), (X1 - F, Y0 + F)]
    return m, tri

def variant_a():
    """墨笺：深墨蓝底 + 象牙白便签 + 朱砂小印"""
    c, mask = base((40, 46, 62), (18, 21, 30), light=38, light_color=(120, 130, 160), noise=10)
    nm, tri = note_shape(318, 250, 388, 500, 34, 92)
    c = Image.alpha_composite(c, soft_shadow(nm, mask, 22, 30, 0.55))
    paper = vgrad((250, 246, 238), (236, 229, 216)); paper.putalpha(nm)
    c = Image.alpha_composite(c, paper)
    d = ImageDraw.Draw(c)
    d.polygon(tri, fill=(214, 205, 189, 255))
    # 朱砂印
    sx, sy, ss = 586, 612, 86
    seal = Image.new("L", (S, S), 0)
    ImageDraw.Draw(seal).rounded_rectangle([sc(sx), sc(sy), sc(sx + ss), sc(sy + ss)], radius=sc(14), fill=255)
    red = Image.new("RGBA", (S, S), (196, 58, 40, 255)); red.putalpha(seal)
    c = Image.alpha_composite(c, red)
    ImageDraw.Draw(c).rounded_rectangle([sc(sx + 12), sc(sy + 12), sc(sx + ss - 12), sc(sy + ss - 12)],
                                        radius=sc(6), outline=(250, 240, 230, 230), width=sc(5))
    return c

def variant_b():
    """素纸：暖象牙白底 + 一笔墨线 + 朱砂一点"""
    c, mask = base((248, 244, 236), (232, 225, 212), light=30, noise=8)
    d = ImageDraw.Draw(c)
    ink = (28, 30, 36, 255)
    # 两行“字”：一长一短，粗圆头
    d.rounded_rectangle([sc(262), sc(452), sc(762), sc(452 + 64)], radius=sc(32), fill=ink)
    d.rounded_rectangle([sc(262), sc(560), sc(560), sc(560 + 64)], radius=sc(32), fill=ink)
    # 朱砂点（光标 / 印）
    d.ellipse([sc(612), sc(560), sc(612 + 64), sc(560 + 64)], fill=(205, 62, 42, 255))
    return c

def variant_c():
    """朱印：朱砂红底 + 白色折角便签线框"""
    c, mask = base((214, 78, 56), (172, 46, 32), light=34, light_color=(255, 170, 140), noise=10)
    nm, tri = note_shape(312, 238, 400, 548, 40, 104)
    outline = Image.new("L", (S, S), 0)
    inner, _ = note_shape(312 + 26, 238 + 26, 400 - 52, 548 - 52, 22, 104 - 18)
    outline = ImageChops.subtract(nm, inner)
    white = Image.new("RGBA", (S, S), (255, 248, 240, 255)); white.putalpha(outline)
    c = Image.alpha_composite(c, white)
    X1, Y0, F = sc(712), sc(238), sc(104)
    ImageDraw.Draw(c).polygon([(X1 - F, Y0), (X1, Y0 + F), (X1 - F, Y0 + F)], fill=(255, 248, 240, 255))
    d = ImageDraw.Draw(c)
    d.rounded_rectangle([sc(392), sc(520), sc(632), sc(520 + 30)], radius=sc(15), fill=(255, 248, 240, 255))
    d.rounded_rectangle([sc(392), sc(600), sc(552), sc(600 + 30)], radius=sc(15), fill=(255, 248, 240, 255))
    return c

out = sys.argv[1]; os.makedirs(out, exist_ok=True)
imgs = {"A": variant_a(), "B": variant_b(), "C": variant_c()}
for name, im in imgs.items():
    im.resize((1024, 1024), Image.LANCZOS).save(os.path.join(out, f"icon_{name}.png"))
# 对比图：大图 + 小尺寸（Dock 64px、访达 32px）
W = 1500; sheet = Image.new("RGB", (W, 640), (236, 236, 238))
for i, (name, im) in enumerate(imgs.items()):
    x = 40 + i * 490
    sheet.paste(im.resize((420, 420), Image.LANCZOS), (x, 30), im.resize((420, 420), Image.LANCZOS))
    sm = im.resize((128, 128), Image.LANCZOS); sheet.paste(sm, (x + 60, 480), sm)
    t = im.resize((64, 64), Image.LANCZOS); sheet.paste(t, (x + 220, 512), t)
    t2 = im.resize((32, 32), Image.LANCZOS); sheet.paste(t2, (x + 320, 528), t2)
dk = Image.new("RGB", (W, 640), (30, 30, 32))
for i, (name, im) in enumerate(imgs.items()):
    x = 40 + i * 490
    dk.paste(im.resize((420, 420), Image.LANCZOS), (x, 30), im.resize((420, 420), Image.LANCZOS))
    sm = im.resize((128, 128), Image.LANCZOS); dk.paste(sm, (x + 60, 480), sm)
    t = im.resize((64, 64), Image.LANCZOS); dk.paste(t, (x + 220, 512), t)
    t2 = im.resize((32, 32), Image.LANCZOS); dk.paste(t2, (x + 320, 528), t2)
both = Image.new("RGB", (W, 1280)); both.paste(sheet, (0, 0)); both.paste(dk, (0, 640))
both.save(os.path.join(out, "compare.png"))
print("ok")

# 用选定方案生成 .iconset
if len(sys.argv) > 3:
    chosen = imgs[sys.argv[2]]
    iconset = sys.argv[3]; os.makedirs(iconset, exist_ok=True)
    for base_px, scale in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]:
        px = base_px * scale
        chosen.resize((px, px), Image.LANCZOS).save(os.path.join(iconset, f"icon_{base_px}x{base_px}{'@2x' if scale == 2 else ''}.png"))
    print("iconset", sys.argv[2])
