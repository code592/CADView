#!/usr/bin/env python3
"""Generate CADView Android/iOS icons from one reproducible vector-like design.

Requires Pillow. The Codex workspace runtime provides it; any Pillow 10+
installation can run this script as well.
"""

from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter


ROOT = Path(__file__).resolve().parents[1]
SIZE = 1024
SCALE = 4
CANVAS = SIZE * SCALE


def scaled(points):
    return [(round(x * SCALE), round(y * SCALE)) for x, y in points]


def rounded_line(draw, points, fill, width):
    points = scaled(points)
    width *= SCALE
    radius = width // 2
    draw.line(points, fill=fill, width=width, joint="curve")
    for x, y in points:
        draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=fill)


def background(rounded):
    image = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    gradient = Image.new("RGBA", image.size)
    pixels = gradient.load()
    for y in range(CANVAS):
        t = y / (CANVAS - 1)
        for x in range(CANVAS):
            radial = max(0.0, 1.0 - (((x / SCALE - 512) / 700) ** 2 + ((y / SCALE - 430) / 700) ** 2))
            pixels[x, y] = (
                round(6 + 5 * radial),
                round(16 + 14 * radial),
                round(27 + 22 * radial + 4 * t),
                255,
            )
    if not rounded:
        return gradient
    mask = Image.new("L", image.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (24 * SCALE, 24 * SCALE, 1000 * SCALE, 1000 * SCALE),
        radius=224 * SCALE,
        fill=255,
    )
    image.paste(gradient, mask=mask)
    return image


def symbol_layer():
    layer = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    glow_mask = Image.new("L", layer.size, 0)
    glow = ImageDraw.Draw(glow_mask)
    cyan = 255

    cube = [
        [(512, 300), (316, 412), (512, 526), (708, 412), (512, 300)],
        [(316, 412), (316, 638), (512, 752), (512, 526)],
        [(708, 412), (708, 638), (512, 752)],
    ]
    for path in cube:
        rounded_line(glow, path, cyan, 34)

    # Two opposing viewfinder corners communicate viewing/cropping without
    # making the glyph itself another rigid square.
    rounded_line(glow, [(260, 342), (260, 250), (352, 250)], cyan, 28)
    rounded_line(glow, [(672, 774), (764, 774), (764, 682)], cyan, 28)
    glow.ellipse(
        (744 * SCALE, 240 * SCALE, 780 * SCALE, 276 * SCALE), fill=cyan
    )

    blurred = glow_mask.filter(ImageFilter.GaussianBlur(18 * SCALE))
    glow_color = Image.new("RGBA", layer.size, (38, 205, 255, 0))
    glow_color.putalpha(blurred.point(lambda value: value * 70 // 255))
    layer.alpha_composite(glow_color)

    ink = Image.new("RGBA", layer.size)
    ink_pixels = ink.load()
    for y in range(CANVAS):
        t = y / (CANVAS - 1)
        color = (round(94 - 28 * t), round(229 - 18 * t), 255, 255)
        for x in range(CANVAS):
            ink_pixels[x, y] = color
    ink.putalpha(glow_mask)
    layer.alpha_composite(ink)
    return layer


def render(rounded):
    image = background(rounded)
    image.alpha_composite(symbol_layer())
    return image.resize((SIZE, SIZE), Image.Resampling.LANCZOS)


def save_resized(source, path, size, rgb=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    image = source.resize((size, size), Image.Resampling.LANCZOS)
    if rgb:
        image = image.convert("RGB")
    image.save(path, optimize=True)


def main():
    rounded_icon = render(rounded=True)
    ios_icon = render(rounded=False).convert("RGB")
    foreground = symbol_layer().resize((SIZE, SIZE), Image.Resampling.LANCZOS)

    branding = ROOT / "assets" / "branding"
    rounded_icon.save(branding / "cadview-app-icon.png", optimize=True)
    foreground.save(branding / "cadview-app-icon-foreground.png", optimize=True)
    ios_icon.save(branding / "cadview-app-icon-ios.png", optimize=True)

    android_sizes = {
        "mdpi": (48, 108),
        "hdpi": (72, 162),
        "xhdpi": (96, 216),
        "xxhdpi": (144, 324),
        "xxxhdpi": (192, 432),
    }
    for density, (legacy_size, foreground_size) in android_sizes.items():
        folder = ROOT / "android" / "app" / "src" / "main" / "res" / f"mipmap-{density}"
        save_resized(rounded_icon, folder / "ic_launcher.png", legacy_size)
        save_resized(foreground, folder / "ic_launcher_foreground.png", foreground_size)

    ios_folder = ROOT / "ios" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
    for path in ios_folder.glob("*.png"):
        if "1024x1024" in path.name:
            target_size = 1024
        else:
            with Image.open(path) as current:
                target_size = current.width
        save_resized(ios_icon, path, target_size, rgb=True)


if __name__ == "__main__":
    main()
