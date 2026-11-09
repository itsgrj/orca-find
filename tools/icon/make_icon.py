#!/usr/bin/env python3
"""Builds every Orca Find icon asset from tools/icon/orca-paths.json.

Outputs
  Resources/Icon/AppIcon.svg            full-bleed 1024 tile (master artwork, for web/marketing)
  Resources/Icon/AppIcon-1024.png       the same, rendered
  Resources/Icon/AppIcon-macOS.svg/png  1024 canvas on Apple's macOS grid (824 body + shadow)
  Resources/AppIcon.icns                built from the macOS-grid PNG
  Resources/MenuBarIcon.png / @2x       18pt template glyph for the menu bar

Needs Google Chrome (headless SVG rendering), Pillow and iconutil.
Usage: python3 tools/icon/make_icon.py
"""
import json, pathlib, shutil, subprocess, tempfile
from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parents[2]
HERE = ROOT / "tools" / "icon"
RES = ROOT / "Resources"
ICON = RES / "Icon"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

P = json.loads((HERE / "orca-paths.json").read_text())
x0, y0, x1, y1 = P["frame"]          # the tile's bounds in the traced reference image
FIT = f"scale({1024/(x1-x0):.5f} {1024/(y1-y0):.5f}) translate({-x0} {-y0})"
BODY = "".join(f'<path d="{d}"/>' for d in P["body"])
BODY_FIT = "".join(f'<path transform="{FIT}" d="{d}"/>' for d in P["body"])  # clipPath can't hold <g>
WHITES = "".join(f'<path d="{d}"/>' for d in P["patch"] + P["chin"])

# Ocean blue, picked by the user (2026-11-09).
C = dict(hi="#d6e6ff", a="#8fb6ff", b="#3f7bff", c="#2a58e0", d="#1f3ea8", rim="#e4efff")


def tile():
    """The icon tile in a 0..1024 box (rounded square, gradient, orca, rim light)."""
    return f'''
  <defs>
    <clipPath id="sq"><rect width="1024" height="1024" rx="228" ry="228"/></clipPath>
    <linearGradient id="bg" x1="0" y1="0.15" x2="1" y2="0.55">
      <stop offset="0" stop-color="{C['a']}"/><stop offset="0.42" stop-color="{C['b']}"/>
      <stop offset="0.75" stop-color="{C['c']}"/><stop offset="1" stop-color="{C['d']}"/>
    </linearGradient>
    <radialGradient id="hi" cx="0.08" cy="0.04" r="0.55">
      <stop offset="0" stop-color="{C['hi']}" stop-opacity="0.95"/>
      <stop offset="1" stop-color="{C['hi']}" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="rim" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="{C['rim']}" stop-opacity="0.95"/>
      <stop offset="0.45" stop-color="{C['rim']}" stop-opacity="0.35"/>
      <stop offset="1" stop-color="{C['rim']}" stop-opacity="0.55"/>
    </linearGradient>
    <linearGradient id="shade" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0.7" stop-color="#000" stop-opacity="0"/><stop offset="1" stop-color="#000" stop-opacity="0.18"/>
    </linearGradient>
    <filter id="soft" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="10"/></filter>
    <clipPath id="bodyU">{BODY_FIT}</clipPath>
  </defs>
  <g clip-path="url(#sq)">
    <rect width="1024" height="1024" fill="url(#bg)"/>
    <rect width="1024" height="1024" fill="url(#hi)"/>
    <rect width="1024" height="1024" fill="url(#shade)"/>
    <g transform="translate(14 10)" opacity="0.35" filter="url(#soft)"><g transform="{FIT}" fill="#0a1640">{BODY}</g></g>
    <g transform="{FIT}" fill="#000">{BODY}</g>
    <g clip-path="url(#bodyU)"><g transform="{FIT}" fill="#fff" stroke="#fff" stroke-width="5" stroke-linejoin="round">{WHITES}</g></g>
  </g>
  <rect x="3" y="3" width="1018" height="1018" rx="226" ry="226" fill="none" stroke="url(#rim)" stroke-width="6"/>'''


def svg(w, h, inner, view=None):
    vb = view or f"0 0 {w} {h}"
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="{vb}">{inner}</svg>\n'


def render(svg_path, png_path, w, h):
    subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
                    "--default-background-color=00000000", f"--window-size={w},{h+200}",
                    f"--screenshot={png_path}", svg_path.as_uri()],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    Image.open(png_path).crop((0, 0, w, h)).save(png_path)


def main():
    ICON.mkdir(parents=True, exist_ok=True)

    # 1. Master artwork, full bleed.
    master = ICON / "AppIcon.svg"
    master.write_text(svg(1024, 1024, tile()))
    render(master, ICON / "AppIcon-1024.png", 1024, 1024)

    # 2. macOS grid: 824x824 body centred on a 1024 canvas, soft drop shadow.
    s = 824 / 1024
    mac = f'''
  <defs><filter id="drop" x="-10%" y="-10%" width="120%" height="130%">
    <feGaussianBlur in="SourceAlpha" stdDeviation="14"/><feOffset dy="12"/>
    <feComponentTransfer><feFuncA type="linear" slope="0.32"/></feComponentTransfer>
    <feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge></filter></defs>
  <g filter="url(#drop)"><g transform="translate(100 100) scale({s})">{tile()}</g></g>'''
    mac_svg = ICON / "AppIcon-macOS.svg"
    mac_svg.write_text(svg(1024, 1024, mac))
    mac_png = ICON / "AppIcon-macOS-1024.png"
    render(mac_svg, mac_png, 1024, 1024)

    # 3. .icns
    big = Image.open(mac_png).convert("RGBA")
    with tempfile.TemporaryDirectory() as tmp:
        iconset = pathlib.Path(tmp) / "AppIcon.iconset"
        iconset.mkdir()
        for n in (16, 32, 128, 256, 512):
            big.resize((n, n), Image.LANCZOS).save(iconset / f"icon_{n}x{n}.png")
            big.resize((n*2, n*2), Image.LANCZOS).save(iconset / f"icon_{n}x{n}@2x.png")
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(RES / "AppIcon.icns")], check=True)

    # 4. Menu bar template glyph: black orca, patch and chin knocked out, on transparent.
    glyph = f'''
  <defs><mask id="m"><rect x="-200" y="-200" width="1400" height="1400" fill="#fff"/>
    <g transform="{FIT}" fill="#000" stroke="#000" stroke-width="6">{WHITES}</g></mask></defs>
  <g mask="url(#m)"><g transform="{FIT}" fill="#000">{BODY}</g></g>'''
    g_svg = pathlib.Path(tempfile.gettempdir()) / "orca-menubar.svg"
    g_svg.write_text(svg(576, 576, glyph, view="110 120 880 880"))
    g_png = pathlib.Path(tempfile.gettempdir()) / "orca-menubar.png"
    render(g_svg, g_png, 576, 576)
    g = Image.open(g_png).convert("RGBA")
    g.resize((18, 18), Image.LANCZOS).save(RES / "MenuBarIcon.png")
    g.resize((36, 36), Image.LANCZOS).save(RES / "MenuBarIcon@2x.png")
    print("Icon assets written to", ICON, "and", RES)


if __name__ == "__main__":
    main()
