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

TOP = (58, 44, 140)       # 靛藍
BOTTOM = (18, 16, 40)     # 深夜藍
GREEN = (30, 215, 96)
WHITE = (255, 255, 255)


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
    img = gradient(size)
    glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse([size * 0.1, size * 0.05, size * 0.8, size * 0.6], fill=(120, 90, 255, 70))
    glow = glow.filter(ImageFilter.GaussianBlur(size * 0.08))
    img = Image.alpha_composite(img.convert("RGBA"), glow)
    draw_mark(ImageDraw.Draw(img), size)
    return img.convert("RGB")  # App icon 不能有透明


def launch_icon(size=240):
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw_mark(ImageDraw.Draw(img), size)
    return img


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

    color_set("AccentColor", (88, 70, 210), (140, 125, 255))
    color_set("LaunchBackground", (18, 16, 40), (18, 16, 40))
    print("已產生", ASSETS)


if __name__ == "__main__":
    main()
