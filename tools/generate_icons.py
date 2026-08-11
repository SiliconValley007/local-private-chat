"""Generate Android launcher and notification icons from the brand logo.

Run after changing ``flutter_app/assets/branding/chat.png``:

    python tools/generate_icons.py

Notification icons cannot reuse the colourful logo: Android draws the small icon
as a mask, so anything with colour comes out as a white blob. A silhouette is
built here instead, with the speech-bubble dots punched back out so the shape
stays recognisable at 24dp.
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "flutter_app" / "assets" / "branding" / "chat.png"
RES = ROOT / "flutter_app" / "android" / "app" / "src" / "main" / "res"

# Density buckets as multipliers of the mdpi baseline.
DENSITIES = {
    "mdpi": 1.0,
    "hdpi": 1.5,
    "xhdpi": 2.0,
    "xxhdpi": 3.0,
    "xxxhdpi": 4.0,
}

LEGACY_DP = 48  # classic launcher icon
ADAPTIVE_DP = 108  # adaptive icon canvas
NOTIFICATION_DP = 24  # status bar small icon

# Adaptive icons only guarantee the middle 66dp of the 108dp canvas is visible.
ADAPTIVE_LOGO_RATIO = 66 / ADAPTIVE_DP * 0.95
LEGACY_LOGO_RATIO = 0.78
NOTIFICATION_LOGO_RATIO = 0.92

BACKGROUND = (255, 255, 255, 255)
LEGACY_CORNER_RATIO = 0.22


def load_logo() -> Image.Image:
    if not SOURCE.is_file():
        raise SystemExit(f"Brand logo not found: {SOURCE}")
    return Image.open(SOURCE).convert("RGBA")


def rounded_square(size: int, radius: int, color: tuple[int, int, int, int]) -> Image.Image:
    """Solid rounded square, drawn oversized then downscaled for smooth edges."""
    scale = 4
    big = Image.new("RGBA", (size * scale, size * scale), (0, 0, 0, 0))
    draw = ImageDraw.Draw(big)
    draw.rounded_rectangle(
        (0, 0, size * scale - 1, size * scale - 1),
        radius=radius * scale,
        fill=color,
    )
    return big.resize((size, size), Image.LANCZOS)


def centered(canvas: Image.Image, logo: Image.Image, ratio: float) -> Image.Image:
    """Paste the logo, scaled to ``ratio`` of the canvas, in the middle."""
    target = max(1, round(canvas.width * ratio))
    scaled = logo.resize((target, target), Image.LANCZOS)
    offset = ((canvas.width - target) // 2, (canvas.height - target) // 2)
    out = canvas.copy()
    out.alpha_composite(scaled, offset)
    return out


def silhouette(logo: Image.Image) -> Image.Image:
    """White mask of the logo with its white dots turned into holes."""
    width, height = logo.size
    mask = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    src = logo.load()
    dst = mask.load()
    for y in range(height):
        for x in range(width):
            red, green, blue, alpha = src[x, y]
            if alpha < 96:
                continue
            lightest = max(red, green, blue)
            darkest = min(red, green, blue)
            # Near-white and unsaturated means this is a dot, not the bubble.
            if darkest >= 225 and lightest - darkest <= 30:
                continue
            dst[x, y] = (255, 255, 255, alpha)
    return mask


def write(image: Image.Image, folder: str, name: str) -> None:
    out_dir = RES / folder
    out_dir.mkdir(parents=True, exist_ok=True)
    image.save(out_dir / name, "PNG")


def px(dp: int, factor: float) -> int:
    return max(1, round(dp * factor))


def generate() -> None:
    logo = load_logo()
    mono = silhouette(logo)

    for bucket, factor in DENSITIES.items():
        legacy_size = px(LEGACY_DP, factor)
        base = rounded_square(
            legacy_size,
            round(legacy_size * LEGACY_CORNER_RATIO),
            BACKGROUND,
        )
        write(centered(base, logo, LEGACY_LOGO_RATIO), f"mipmap-{bucket}", "ic_launcher.png")

        adaptive_size = px(ADAPTIVE_DP, factor)
        transparent = Image.new("RGBA", (adaptive_size, adaptive_size), (0, 0, 0, 0))
        write(
            centered(transparent, logo, ADAPTIVE_LOGO_RATIO),
            f"mipmap-{bucket}",
            "ic_launcher_foreground.png",
        )
        write(
            centered(transparent, mono, ADAPTIVE_LOGO_RATIO),
            f"mipmap-{bucket}",
            "ic_launcher_monochrome.png",
        )

        notif_size = px(NOTIFICATION_DP, factor)
        notif_canvas = Image.new("RGBA", (notif_size, notif_size), (0, 0, 0, 0))
        write(
            centered(notif_canvas, mono, NOTIFICATION_LOGO_RATIO),
            f"drawable-{bucket}",
            "ic_stat_notification.png",
        )

    # Full-size icon kept next to the source art, for docs or a store listing.
    full = rounded_square(512, round(512 * LEGACY_CORNER_RATIO), BACKGROUND)
    centered(full, logo, LEGACY_LOGO_RATIO).save(SOURCE.with_name("app_icon_512.png"), "PNG")
    print(f"Icons written under {RES}")


if __name__ == "__main__":
    generate()
