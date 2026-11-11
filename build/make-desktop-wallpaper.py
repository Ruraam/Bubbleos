#!/usr/bin/env python3
"""Render the bubbleOS cyber-punk desktop wallpaper.

This is an authoring helper, not part of the reproducible image build: the
rendered PNG is committed under rootfs/overlay.  It only needs Pillow and the
Orbitron font vendored in the same overlay tree.

Usage: python3 build/make-desktop-wallpaper.py
"""

from __future__ import annotations

import math
import random
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

REPO = Path(__file__).resolve().parent.parent
FONT = REPO / "rootfs/overlay/usr/share/fonts/truetype/orbitron/Orbitron-VariableFont_wght.ttf"
OUTPUT = REPO / "rootfs/overlay/usr/share/backgrounds/bubbleos/bubbleos-wallpaper.png"

W, H = 2560, 1440
CYAN = (34, 211, 238)
SKY = (56, 189, 248)
BLUE = (96, 165, 250)
INDIGO = (129, 140, 248)
PALE = (224, 242, 254)


def lerp(a: tuple[int, ...], b: tuple[int, ...], t: float) -> tuple[int, ...]:
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def vertical_gradient(size: tuple[int, int], top: tuple[int, int, int], bottom: tuple[int, int, int]) -> Image.Image:
    column = Image.new("RGB", (1, size[1]))
    pixels = column.load()
    for y in range(size[1]):
        pixels[0, y] = lerp(top, bottom, y / max(1, size[1] - 1))
    return column.resize(size, Image.Resampling.BILINEAR)


def radial_glow(size: tuple[int, int], center: tuple[int, int], radius: int, color: tuple[int, int, int], alpha: int) -> Image.Image:
    layer = Image.new("RGBA", size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    steps = 18
    for step in range(steps, 0, -1):
        r = int(radius * step / steps)
        a = int(alpha * (1 - step / steps) ** 2)
        draw.ellipse((center[0] - r, center[1] - r, center[0] + r, center[1] + r), fill=(*color, a))
    return layer.filter(ImageFilter.GaussianBlur(radius // 5))


def text_width(font: ImageFont.FreeTypeFont, text: str, spacing: int = 0) -> int:
    return sum(font.getlength(ch) for ch in text) + spacing * max(0, len(text) - 1)


def draw_tracked(draw: ImageDraw.ImageDraw, xy: tuple[float, float], text: str, font: ImageFont.FreeTypeFont, fill, spacing: int = 0) -> None:
    x, y = xy
    for ch in text:
        draw.text((x, y), ch, font=font, fill=fill, anchor="ls")
        x += font.getlength(ch) + spacing


def gradient_text(text: str, font: ImageFont.FreeTypeFont, spacing: int = 0) -> Image.Image:
    width = int(text_width(font, text, spacing)) + 8
    bbox = font.getbbox(text)
    height = bbox[3] - bbox[1] + 12
    mask = Image.new("L", (width, height), 0)
    draw = ImageDraw.Draw(mask)
    draw_tracked(draw, (4, height - 8), text, font, 255, spacing)
    gradient = Image.new("RGBA", (width, height))
    gp = gradient.load()
    for x in range(width):
        t = x / max(1, width - 1)
        if t < 0.34:
            color = lerp(CYAN, SKY, t / 0.34)
        elif t < 0.67:
            color = lerp(SKY, BLUE, (t - 0.34) / 0.33)
        else:
            color = lerp(BLUE, INDIGO, (t - 0.67) / 0.33)
        for y in range(height):
            gp[x, y] = (*color, 255)
    result = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    result.paste(gradient, (0, 0), mask)
    return result


def iso_cube(center: tuple[int, int], size: int) -> tuple[list[tuple[int, int]], list[tuple[int, int]], list[tuple[int, int]]]:
    cx, cy = center
    top = (cx, cy - size)
    upper_left = (cx - size * 0.87, cy - size * 0.5)
    upper_right = (cx + size * 0.87, cy - size * 0.5)
    middle = (cx, cy)
    lower_left = (cx - size * 0.87, cy + size * 0.5)
    lower_right = (cx + size * 0.87, cy + size * 0.5)
    bottom = (cx, cy + size)
    return (
        [top, upper_right, middle, upper_left],
        [upper_left, middle, bottom, lower_left],
        [middle, upper_right, lower_right, bottom],
    )


def main() -> None:
    random.seed(20261106)
    canvas = vertical_gradient((W, H), (2, 6, 23), (12, 35, 64)).convert("RGBA")

    # Deep colour fields behind the composition.
    canvas.alpha_composite(radial_glow((W, H), (1950, 590), 720, INDIGO, 42))
    canvas.alpha_composite(radial_glow((W, H), (1780, 660), 500, CYAN, 34))
    canvas.alpha_composite(radial_glow((W, H), (350, 1260), 620, BLUE, 26))

    # Perspective grid.
    grid = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    gd = ImageDraw.Draw(grid)
    horizon = 810
    vanish = (1280, horizon)
    for x in range(-500, W + 501, 110):
        gd.line((vanish, (x, H)), fill=(*CYAN, 26), width=2)
    step = 7
    for i in range(1, 40):
        t = i / 40
        y = horizon + int((H - horizon) * (t ** 2.15))
        gd.line(((0, y), (W, y)), fill=(*SKY, 22), width=2)
    glow = grid.filter(ImageFilter.GaussianBlur(5))
    canvas.alpha_composite(glow)
    canvas.alpha_composite(grid)

    # Circuit traces and nodes.
    circuits = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    cd = ImageDraw.Draw(circuits)
    traces = [
        [(0, 310), (180, 310), (240, 250), (430, 250)],
        [(0, 350), (150, 350), (210, 410), (390, 410)],
        [(0, 1110), (230, 1110), (300, 1180), (520, 1180)],
        [(0, 1150), (200, 1150), (260, 1090), (470, 1090)],
        [(W, 210), (2260, 210), (2200, 270), (2050, 270)],
        [(W, 1190), (2290, 1190), (2210, 1270), (1990, 1270)],
    ]
    for points in traces:
        cd.line(points, fill=(*SKY, 70), width=2, joint="curve")
        for point in (points[1], points[-1]):
            cd.ellipse((point[0] - 5, point[1] - 5, point[0] + 5, point[1] + 5), outline=(*CYAN, 150), width=2)
            cd.ellipse((point[0] - 2, point[1] - 2, point[0] + 2, point[1] + 2), fill=(*PALE, 200))
    canvas.alpha_composite(circuits.filter(ImageFilter.GaussianBlur(4)))
    canvas.alpha_composite(circuits)

    # Glass bubble ring.
    ring_center = (1940, 590)
    ring_radius = 330
    ring = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    rd = ImageDraw.Draw(ring)
    for start in range(0, 360, 6):
        t = start / 360
        color = lerp(CYAN, INDIGO, (math.sin(t * math.pi * 2) + 1) / 2)
        bbox = (ring_center[0] - ring_radius, ring_center[1] - ring_radius,
                ring_center[0] + ring_radius, ring_center[1] + ring_radius)
        rd.arc(bbox, start=start, end=start + 7, fill=(*color, 210), width=6)
    rd.arc((ring_center[0] - ring_radius + 22, ring_center[1] - ring_radius + 22,
            ring_center[0] + ring_radius - 22, ring_center[1] + ring_radius - 22),
           start=200, end=340, fill=(255, 255, 255, 120), width=3)
    rd.arc((ring_center[0] - ring_radius + 22, ring_center[1] - ring_radius + 22,
            ring_center[0] + ring_radius - 22, ring_center[1] + ring_radius - 22),
           start=20, end=90, fill=(*SKY, 70), width=2)
    canvas.alpha_composite(ring.filter(ImageFilter.GaussianBlur(16)))
    canvas.alpha_composite(ring)

    # Package cube inside the ring.
    cube = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    kd = ImageDraw.Draw(cube)
    faces = iso_cube((1940, 600), 190)
    kd.polygon(faces[0], fill=(30, 64, 110, 120), outline=(*CYAN, 220))
    kd.polygon(faces[1], fill=(12, 35, 64, 150), outline=(*SKY, 200))
    kd.polygon(faces[2], fill=(15, 23, 42, 165), outline=(*INDIGO, 200))
    for face in faces:
        kd.line(face + [face[0]], fill=(*PALE, 190), width=3, joint="curve")
    # Package seams.
    kd.line((1940, 410, 1940, 790), fill=(*PALE, 80), width=2)
    kd.line((1775, 505, 2105, 695), fill=(*PALE, 65), width=2)
    kd.line((1775, 695, 2105, 505), fill=(*PALE, 65), width=2)
    canvas.alpha_composite(cube.filter(ImageFilter.GaussianBlur(18)))
    canvas.alpha_composite(cube)

    # Wordmark.
    display = ImageFont.truetype(str(FONT), 156)
    word = gradient_text("bubbleOS", display, spacing=2)
    word = word.resize((int(word.width * 0.86), int(word.height * 0.86)), Image.Resampling.LANCZOS)
    mask = word.getchannel("A")
    halo = Image.new("RGBA", word.size, (0, 0, 0, 0))
    halo.paste((*CYAN, 110), (0, 0), mask)
    halo = halo.filter(ImageFilter.GaussianBlur(28))
    canvas.alpha_composite(halo, (210, 495))
    canvas.alpha_composite(word, (210, 495))

    label = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf", 34)
    small = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf", 22)
    draw = ImageDraw.Draw(canvas)
    draw_tracked(draw, (224, 750), "CYBERPUNK LINUX", label, (*PALE, 225), spacing=12)
    draw.line((224, 790, 900, 790), fill=(*CYAN, 120), width=2)
    draw_tracked(draw, (224, 840), "IMMUTABLE  /  ATOMIC  /  YOURS", small, (*SKY, 190), spacing=4)

    # Small technical annotations.
    draw_tracked(draw, (224, 180), "BUBBLEOS // DESKTOP", small, (*SKY, 160), spacing=5)
    draw_tracked(draw, (2100, 1300), "WAYFIRE  ·  GENERATION 01", small, (*SKY, 150), spacing=4)
    draw.line((224, 220, 720, 220), fill=(*CYAN, 90), width=2)

    # Sparse particles.
    particles = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    pd = ImageDraw.Draw(particles)
    for _ in range(220):
        x = random.randrange(W)
        y = random.randrange(H)
        r = random.choice((1, 1, 1, 2))
        color = random.choice((CYAN, SKY, PALE, INDIGO))
        pd.ellipse((x - r, y - r, x + r, y + r), fill=(*color, random.randrange(35, 150)))
    canvas.alpha_composite(particles)

    # Vignette and gentle noise to avoid gradient banding.
    vignette = Image.new("L", (W, H), 0)
    vd = ImageDraw.Draw(vignette)
    vd.ellipse((-W * 0.25, -H * 0.35, W * 1.25, H * 1.35), fill=255)
    vignette = vignette.filter(ImageFilter.GaussianBlur(260))
    shade = Image.new("RGBA", (W, H), (2, 6, 23, 255))
    canvas = Image.composite(canvas, Image.alpha_composite(canvas, shade), vignette)
    noise = Image.effect_noise((W, H), 10).convert("L").point(lambda v: int(v * 0.08))
    noise_layer = Image.new("RGBA", (W, H), (255, 255, 255, 0))
    noise_layer.putalpha(noise)
    canvas = Image.alpha_composite(canvas, noise_layer)

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    canvas.convert("RGB").save(OUTPUT, "PNG", optimize=True)
    print(f"wrote {OUTPUT.relative_to(REPO)} ({OUTPUT.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
