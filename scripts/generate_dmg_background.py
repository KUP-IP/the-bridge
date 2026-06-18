#!/usr/bin/env python3

from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter


WIDTH = 640
HEIGHT = 360


def vertical_gradient(top: tuple[int, int, int], bottom: tuple[int, int, int]) -> Image.Image:
    image = Image.new("RGB", (WIDTH, HEIGHT), top)
    draw = ImageDraw.Draw(image)
    for y in range(HEIGHT):
        ratio = y / max(HEIGHT - 1, 1)
        color = tuple(int(top[i] * (1.0 - ratio) + bottom[i] * ratio) for i in range(3))
        draw.line((0, y, WIDTH, y), fill=color)
    return image


def add_glow(base: Image.Image, xy: tuple[int, int], radius: int, color: tuple[int, int, int, int]) -> None:
    glow = Image.new("RGBA", (WIDTH, HEIGHT), (0, 0, 0, 0))
    draw = ImageDraw.Draw(glow)
    x, y = xy
    draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=color)
    glow = glow.filter(ImageFilter.GaussianBlur(radius=48))
    base.alpha_composite(glow)


def add_arrow(base: Image.Image) -> None:
    draw = ImageDraw.Draw(base)
    arrow = [(270, 180), (390, 180)]
    dash = 18
    gap = 12
    x = arrow[0][0]
    while x < arrow[1][0]:
        x2 = min(x + dash, arrow[1][0])
        draw.line((x, 180, x2, 180), fill=(255, 255, 255, 150), width=6)
        x = x2 + gap
    draw.polygon([(390, 180), (360, 160), (360, 200)], fill=(255, 255, 255, 190))


def add_drop_zone(base: Image.Image) -> None:
    overlay = Image.new("RGBA", (WIDTH, HEIGHT), (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    draw.rounded_rectangle((350, 60, 590, 300), radius=28, outline=(255, 255, 255, 72), width=3)
    draw.rounded_rectangle((362, 72, 578, 288), radius=22, fill=(255, 255, 255, 18))
    overlay = overlay.filter(ImageFilter.GaussianBlur(radius=1))
    base.alpha_composite(overlay)


def add_icon(base: Image.Image, icon_path: Path) -> None:
    icon = Image.open(icon_path).convert("RGBA")
    icon.thumbnail((132, 132))
    shadow = Image.new("RGBA", (icon.width + 30, icon.height + 30), (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    shadow_draw.rounded_rectangle((18, 18, shadow.width - 6, shadow.height - 6), radius=28, fill=(0, 0, 0, 110))
    shadow = shadow.filter(ImageFilter.GaussianBlur(radius=18))
    base.alpha_composite(shadow, (118, 108))
    base.alpha_composite(icon, (140, 130))


def add_title(base: Image.Image) -> None:
    draw = ImageDraw.Draw(base)
    draw.text((86, 42), "The Bridge", fill=(255, 255, 255, 235))
    draw.text((86, 72), "Drag the app into Applications to install.", fill=(230, 235, 245, 210))


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: generate_dmg_background.py <output> <icon>", file=sys.stderr)
        return 1

    output_path = Path(sys.argv[1])
    icon_path = Path(sys.argv[2])

    output_path.parent.mkdir(parents=True, exist_ok=True)

    background = vertical_gradient((19, 31, 58), (42, 67, 112)).convert("RGBA")
    add_glow(background, (140, 120), 120, (86, 180, 255, 110))
    add_glow(background, (535, 150), 100, (140, 120, 255, 90))
    add_drop_zone(background)
    add_arrow(background)
    add_icon(background, icon_path)
    add_title(background)
    background.save(output_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
