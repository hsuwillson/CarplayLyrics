#!/usr/bin/env python3
"""產生 CarLyrics 的 App icon 與啟動畫面圖（自繪幾何圖形，不含任何第三方素材）。

    python3 tools/make_icon.py

輸出到 CarLyrics/Assets.xcassets/。需要 Pillow（pip install pillow）。
"""
import json
import os

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(ROOT, "CarLyrics", "Assets.xcassets")

TOP = (92, 74, 214)       # 品牌靛藍（與 AccentColor 一致）
BOTTOM = (16, 14, 38)     # 深夜藍
GREEN = (52, 199, 89)     # 系統綠（播放中）
WHITE = (255, 255, 255)
# 幾何圖形先畫在 4 倍大再縮小：Pillow 本身不做反鋸齒
SUPERSAMPLE = 4


def gradient(size):
    img = Image.new("RGB", (size, size))
    px = img.load()
    for y in range(size):
        for x in range(size):
            t = (x * 0.35 + y * 0.65) / size
            px[x, y] = tuple(int(TOP[i] * (1 - t) + BOTTOM[i] * t) for i in range(3))
    return img


def draw_mark(draw, s, scale=1.0, ox=0, oy=0):
    """音符 + 三行歌詞：代表「同步歌詞」"""
    def P(x, y):
        return (ox + x * s * scale, oy + y * s * scale)

    # 歌詞行（上面那行最亮、最長，代表目前句）
    lines = [(0.20, 0.60, 0.80, WHITE, 0.060), (0.20, 0.72, 0.66, (200, 200, 230), 0.045),
             (0.20, 0.82, 0.52, (140, 140, 190), 0.045)]
    for x0, y, x1, color, h in lines:
        r = h * s * scale / 2
        a, b = P(x0, y - h / 2), P(x1, y + h / 2)
        draw.rounded_rectangle([a, b], radius=r, fill=color)

    # 音符：符頭 + 符桿 + 符尾
    head_c = P(0.36, 0.43)
    rx, ry = 0.085 * s * scale, 0.065 * s * scale
    draw.ellipse([head_c[0] - rx, head_c[1] - ry, head_c[0] + rx, head_c[1] + ry], fill=GREEN)
    stem_x = head_c[0] + rx - 0.022 * s * scale
    draw.rectangle([stem_x, P(0, 0.16)[1], stem_x + 0.035 * s * scale, head_c[1]], fill=GREEN)
    draw.polygon([(stem_x, P(0, 0.16)[1]), P(0.62, 0.24), P(0.62, 0.32),
                  (stem_x + 0.035 * s * scale, P(0, 0.25)[1])], fill=GREEN)


def app_icon(size=1024):
    big = size * SUPERSAMPLE
    img = gradient(big).convert("RGBA")
    # 左上角一團光暈（跟 App 主畫面的背景同一個語言）
    glow = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse([-big * 0.1, -big * 0.2, big * 0.75, big * 0.55], fill=(150, 130, 255, 90))
    glow = glow.filter(ImageFilter.GaussianBlur(big * 0.10))
    img = Image.alpha_composite(img, glow)
    # 目前句底下一層柔光，讓最亮那一行更「亮」
    halo = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    hd = ImageDraw.Draw(halo)
    hd.rounded_rectangle([big * 0.17, big * 0.55, big * 0.83, big * 0.65], radius=big * 0.05,
                         fill=(255, 255, 255, 60))
    halo = halo.filter(ImageFilter.GaussianBlur(big * 0.03))
    img = Image.alpha_composite(img, halo)
    draw_mark(ImageDraw.Draw(img), big)
    img = img.resize((size, size), Image.LANCZOS)
    return img.convert("RGB")  # App icon 不能有透明


def launch_icon(size=240):
    big = size * SUPERSAMPLE
    img = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    draw_mark(ImageDraw.Draw(img), big)
    return img.resize((size, size), Image.LANCZOS)


def write_json(path, obj):
    with open(path, "w") as f:
        json.dump(obj, f, indent=2)
        f.write("\n")


def color_set(name, rgb, dark_rgb=None):
    d = os.path.join(ASSETS, f"{name}.colorset")
    os.makedirs(d, exist_ok=True)

    def comp(c):
        return {"color-space": "srgb", "components": {
            "red": f"{c[0] / 255:.3f}", "green": f"{c[1] / 255:.3f}", "blue": f"{c[2] / 255:.3f}", "alpha": "1.000"}}

    colors = [{"idiom": "universal", "color": comp(rgb)}]
    if dark_rgb:
        colors.append({"idiom": "universal", "appearances": [{"appearance": "luminosity", "value": "dark"}],
                       "color": comp(dark_rgb)})
    write_json(os.path.join(d, "Contents.json"), {"colors": colors, "info": {"author": "xcode", "version": 1}})


def main():
    os.makedirs(ASSETS, exist_ok=True)
    write_json(os.path.join(ASSETS, "Contents.json"), {"info": {"author": "xcode", "version": 1}})

    icon_dir = os.path.join(ASSETS, "AppIcon.appiconset")
    os.makedirs(icon_dir, exist_ok=True)
    app_icon().save(os.path.join(icon_dir, "AppIcon-1024.png"))
    write_json(os.path.join(icon_dir, "Contents.json"), {
        "images": [{"filename": "AppIcon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
        "info": {"author": "xcode", "version": 1}})

    launch_dir = os.path.join(ASSETS, "LaunchIcon.imageset")
    os.makedirs(launch_dir, exist_ok=True)
    launch_icon(240).save(os.path.join(launch_dir, "LaunchIcon@2x.png"))
    launch_icon(360).save(os.path.join(launch_dir, "LaunchIcon@3x.png"))
    write_json(os.path.join(launch_dir, "Contents.json"), {
        "images": [{"idiom": "universal", "scale": "1x"},
                   {"filename": "LaunchIcon@2x.png", "idiom": "universal", "scale": "2x"},
                   {"filename": "LaunchIcon@3x.png", "idiom": "universal", "scale": "3x"}],
        "info": {"author": "xcode", "version": 1}})

    # AltStore 來源用的小圖示
    altstore = os.path.join(ROOT, "altstore")
    os.makedirs(altstore, exist_ok=True)
    app_icon(180).save(os.path.join(altstore, "icon.png"))

    color_set("AccentColor", (88, 70, 210), (140, 125, 255))
    color_set("LaunchBackground", (16, 14, 38), (16, 14, 38))
    print("已產生", ASSETS)


if __name__ == "__main__":
    main()
