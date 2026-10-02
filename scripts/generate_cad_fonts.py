#!/usr/bin/env python3
"""Generate the bundled CAD substitute fonts (requires fontTools).

* assets/fonts/CADViewCadSymbols-Regular.ttf: self-drawn rebar grade
  symbols at U+E130-U+E133 (the codes Chinese structural SHX fonts draw for
  %%130-%%133: HPB300, HRB335, HRB400, RRB400). Apache-2.0, like this project.
* assets/fonts/CADViewNotoSansNarrow-Regular.ttf: Noto Sans Regular condensed
  horizontally, used for narrow engineering SHX fonts (ebgen.shx). A modified
  version of an OFL-1.1 font under a new name; Noto declares no Reserved Font
  Name. Advances, side bearings, glyph outlines and GPOS x values are scaled
  together; TrueType hinting is removed because it no longer matches.

Run from the repository root: python3 scripts/generate_cad_fonts.py
"""

import math
from pathlib import Path

from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib import TTFont

ROOT = Path(__file__).resolve().parent.parent
FONTS = ROOT / "assets" / "fonts"

# Measured from AutoCAD-fitted underlines in an ebgen.shx/hztxt.shx drawing:
# ebgen Latin advances are 0.758 of Noto Sans at the same capital height.
NARROW_SCALE = 0.758


def _rect(pen, x0, y0, x1, y1):
    # Clockwise (TrueType outer contour) in a y-up coordinate system.
    pen.moveTo((x0, y0))
    pen.lineTo((x0, y1))
    pen.lineTo((x1, y1))
    pen.lineTo((x1, y0))
    pen.closePath()


def _polygon(pen, points):
    pen.moveTo(points[0])
    for point in points[1:]:
        pen.lineTo(point)
    pen.closePath()


def _ring(pen, cx, cy, outer, inner, segments=64):
    # Outer clockwise, inner counter-clockwise so the inside is a hole.
    def circle(radius, clockwise):
        points = []
        for index in range(segments):
            angle = 2 * math.pi * index / segments
            angle = -angle if clockwise else angle
            points.append(
                (round(cx + radius * math.cos(angle)), round(cy + radius * math.sin(angle)))
            )
        return points

    _polygon(pen, circle(outer, True))
    _polygon(pen, circle(inner, False))


def _phi(pen):
    _ring(pen, 320, 357, 300, 236)
    _rect(pen, 288, -60, 352, 774)


def _symbol_glyphs():
    glyphs = {}

    pen = TTGlyphPen(None)
    glyphs[".notdef"] = (pen.glyph(), 600)
    pen = TTGlyphPen(None)
    glyphs["space"] = (pen.glyph(), 260)

    # HPB300: a circle with a vertical stroke.
    pen = TTGlyphPen(None)
    _phi(pen)
    glyphs["uniE130"] = (pen.glyph(), 640)

    # HRB335: one horizontal stroke across the vertical.
    pen = TTGlyphPen(None)
    _phi(pen)
    _rect(pen, 170, 325, 470, 389)
    glyphs["uniE131"] = (pen.glyph(), 640)

    # HRB400: two horizontal strokes across the vertical.
    pen = TTGlyphPen(None)
    _phi(pen)
    _rect(pen, 170, 250, 470, 314)
    _rect(pen, 170, 400, 470, 464)
    glyphs["uniE132"] = (pen.glyph(), 640)

    # RRB400: the HPB symbol with a superscript R.
    pen = TTGlyphPen(None)
    _phi(pen)
    _rect(pen, 640, 470, 682, 790)  # stem
    _rect(pen, 640, 748, 760, 790)  # top of bowl
    _rect(pen, 740, 650, 782, 790)  # right of bowl
    _rect(pen, 640, 610, 770, 652)  # middle of bowl
    _polygon(pen, [(700, 630), (742, 630), (812, 470), (770, 470)])  # leg
    glyphs["uniE133"] = (pen.glyph(), 860)
    return glyphs


def build_symbol_font(path):
    glyphs = _symbol_glyphs()
    order = list(glyphs)
    builder = FontBuilder(1000, isTTF=True)
    builder.setupGlyphOrder(order)
    builder.setupCharacterMap(
        {0x20: "space", 0xE130: "uniE130", 0xE131: "uniE131", 0xE132: "uniE132", 0xE133: "uniE133"}
    )
    builder.setupGlyf({name: glyph for name, (glyph, _) in glyphs.items()})
    metrics = {}
    glyf = builder.font["glyf"]
    for name, (_, advance) in glyphs.items():
        glyph = glyf[name]
        glyph.recalcBounds(glyf)
        metrics[name] = (advance, getattr(glyph, "xMin", 0))
    builder.setupHorizontalMetrics(metrics)
    builder.setupHorizontalHeader(ascent=1069, descent=-293)
    builder.setupNameTable(
        {
            "familyName": "CADView CAD Symbols",
            "styleName": "Regular",
            "uniqueFontIdentifier": "CADView CAD Symbols Regular",
            "fullName": "CADView CAD Symbols Regular",
            "psName": "CADViewCADSymbols-Regular",
            "version": "Version 1.000",
            "licenseDescription": "Apache License 2.0",
        }
    )
    builder.setupOS2(
        sTypoAscender=1069,
        sTypoDescender=-293,
        sTypoLineGap=0,
        usWinAscent=1069,
        usWinDescent=293,
        sxHeight=536,
        sCapHeight=714,
        version=4,
    )
    builder.setupPost()
    builder.save(str(path))


def _scale_gpos(value, scale):
    """Scale every x placement/advance/anchor in a GPOS subtree."""
    if isinstance(value, list):
        for item in value:
            _scale_gpos(item, scale)
        return
    if not hasattr(value, "__dict__"):
        return
    for key, item in list(vars(value).items()):
        if key in ("XPlacement", "XAdvance", "XCoordinate") and isinstance(item, int):
            setattr(value, key, round(item * scale))
        elif key in ("XPlaDevice", "XAdvDevice", "XDeviceTable"):
            setattr(value, key, None)
        elif not isinstance(item, (int, float, str, bytes)) and item is not None:
            _scale_gpos(item, scale)


def build_narrow_font(source, path, scale=NARROW_SCALE):
    font = TTFont(str(source))
    glyf = font["glyf"]
    for name in font.getGlyphOrder():
        glyph = glyf[name]
        if glyph.isComposite():
            for component in glyph.components:
                component.x = round(component.x * scale)
        elif glyph.numberOfContours > 0:
            coordinates = glyph.coordinates
            for index in range(len(coordinates)):
                x, y = coordinates[index]
                coordinates[index] = (round(x * scale), y)
        if hasattr(glyph, "program"):
            glyph.program.fromBytecode(b"")
    for name in font.getGlyphOrder():
        glyf[name].recalcBounds(glyf)
    hmtx = font["hmtx"]
    for name, (advance, _) in list(hmtx.metrics.items()):
        hmtx.metrics[name] = (round(advance * scale), getattr(glyf[name], "xMin", 0))
    if "GPOS" in font:
        _scale_gpos(font["GPOS"].table, scale)
    for table in ("fpgm", "prep", "cvt ", "gasp", "hdmx", "LTSH", "VDMX", "DSIG"):
        if table in font:
            del font[table]
    os2 = font["OS/2"]
    os2.xAvgCharWidth = round(os2.xAvgCharWidth * scale)
    os2.usWidthClass = 3  # Condensed
    font["head"].flags &= ~(1 << 3 | 1 << 4)
    family = "CADView Noto Sans Narrow"
    names = {
        1: family,
        2: "Regular",
        3: f"{family} Regular (modified from Noto Sans)",
        4: f"{family} Regular",
        6: "CADViewNotoSansNarrow-Regular",
        16: family,
        17: "Regular",
    }
    name_table = font["name"]
    name_table.names = [record for record in name_table.names if record.nameID not in (*names, 21, 22)]
    for name_id, value in names.items():
        name_table.setName(value, name_id, 3, 1, 0x409)
        name_table.setName(value, name_id, 1, 0, 0)
    font.save(str(path))


if __name__ == "__main__":
    build_symbol_font(FONTS / "CADViewCadSymbols-Regular.ttf")
    build_narrow_font(FONTS / "NotoSans-Regular.ttf", FONTS / "CADViewNotoSansNarrow-Regular.ttf")
    print("generated CAD substitute fonts")
