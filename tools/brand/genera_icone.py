"""Rigenera le icone delle app dal logo di Firmami (logo-firmami.svg).

Uso, dalla radice del repository:
    pip install cairosvg
    python tools/brand/genera_icone.py

Richiede ImageMagick (comando ``convert``) per il file .ico di Windows.
"""
import pathlib
import subprocess
import tempfile

import cairosvg

ROOT = pathlib.Path(__file__).resolve().parents[2]
SVG = (pathlib.Path(__file__).parent / "logo-firmami.svg").read_text(encoding="utf-8")


def png(path: pathlib.Path, size: int, margin: float = 0.0) -> None:
    """Scrive il logo in PNG quadrato di lato ``size``; ``margin`` è la frazione di bordo trasparente."""
    inner = round(size * (1 - 2 * margin))
    data = cairosvg.svg2png(bytestring=SVG.encode(), output_width=inner, output_height=inner)
    path.parent.mkdir(parents=True, exist_ok=True)
    if inner == size:
        path.write_bytes(data)
        return
    with tempfile.NamedTemporaryFile(suffix=".png") as tmp:
        tmp.write(data)
        tmp.flush()
        subprocess.run(["convert", tmp.name, "-background", "none", "-gravity", "center",
                        "-extent", f"{size}x{size}", str(path)], check=True)


# Android (app per telefono): icone classiche per densità.
android = ROOT / "companion/android/app/src/main/res"
for folder, size in {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}.items():
    png(android / f"mipmap-{folder}/ic_launcher.png", size)

# macOS (app desktop): margine come da indicazioni Apple per le icone del Dock.
macos = ROOT / "desktop/macos/Runner/Assets.xcassets/AppIcon.appiconset"
for size in (16, 32, 64, 128, 256, 512, 1024):
    png(macos / f"app_icon_{size}.png", size, margin=0.1)

# Windows (app desktop): un solo .ico con tutte le dimensioni.
with tempfile.TemporaryDirectory() as d:
    parts = []
    for size in (16, 24, 32, 48, 64, 128, 256):
        p = pathlib.Path(d) / f"{size}.png"
        png(p, size)
        parts.append(str(p))
    subprocess.run(["convert", *parts, str(ROOT / "desktop/windows/runner/resources/app_icon.ico")], check=True)

print("Icone rigenerate.")
