#!/usr/bin/env python3
"""Apply BStream's small Fredoka font customizations.

Usage:
  py tool/build_fredoka_heart_font.py source.ttf assets/fonts/Fredoka-Variable.ttf

The source is the OFL-licensed variable font from:
  https://github.com/google/fonts/tree/main/ofl/fredoka
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path

from fontTools.ttLib import TTFont, newTable
from fontTools.ttLib.tables._g_l_y_f import GlyphCoordinates


# Fredoka's lowercase i has two contours: stem (points 0..17) and dot (18..33).
# Reuse the same point count and on/off-curve pattern so the variable-font data
# remains valid. The outline is enlarged below so it stays recognizable at
# normal phone text sizes.
HEART_DOT = [
    (107, 667),  # top notch
    (124, 684),
    (141, 687),
    (145, 676),
    (145, 664),
    (145, 650),
    (126, 634),
    (116, 624),
    (107, 610),  # lower tip
    (98, 624),
    (78, 634),
    (69, 650),
    (69, 664),
    (69, 676),
    (73, 687),
    (90, 684),
]
HEART_CENTER = (107.0, 648.5)
HEART_SCALE_X = 2.3
HEART_SCALE_Y = 2.5

DOT_POINTS = range(18, 34)


def customize(source: Path, destination: Path) -> None:
    font = TTFont(source)

    glyf = font["glyf"]
    glyph = glyf["i"]
    coordinates, ends, flags = glyph.getCoordinates(glyf)
    if len(coordinates) != 34 or list(ends) != [17, 33]:
        raise ValueError("Unexpected Fredoka lowercase-i outline; refusing to alter it.")

    for index, point in zip(DOT_POINTS, HEART_DOT, strict=True):
        expanded = (
            round(HEART_CENTER[0] + (point[0] - HEART_CENTER[0]) * HEART_SCALE_X),
            round(HEART_CENTER[1] + (point[1] - HEART_CENTER[1]) * HEART_SCALE_Y),
        )
        coordinates[index] = expanded
    glyph.coordinates = GlyphCoordinates(coordinates)
    glyph.recalcBounds(glyf)
    advance, _ = font["hmtx"]["i"]
    # Reserve a little more breathing room after the enlarged heart. max()
    # keeps the generator idempotent when run against its own output.
    font["hmtx"]["i"] = (max(advance, 235), glyph.xMin)

    # Keep the heart's silhouette stable as the rest of the variable font gets
    # heavier. Width-only deltas remain intact.
    for variation in font["gvar"].variations["i"]:
        if "wght" not in variation.axes or variation.coordinates is None:
            continue
        for index in DOT_POINTS:
            variation.coordinates[index] = (0, 0)

    # Gently cap the heaviest end of Fredoka's 300–700 weight axis at the
    # equivalent of 660. Normal and medium weights remain unchanged.
    if "avar" in font:
        # The checked-in output can be enlarged again without changing the
        # weight mapping a second time.
        if font["avar"].segments.get("wght", {}).get(1.0, 1.0) >= 1.0:
            raise ValueError("Unexpected existing Fredoka weight-axis mapping.")
    else:
        axes = {axis.axisTag: axis for axis in font["fvar"].axes}
        weight_axis = axes["wght"]
        lightest = weight_axis.defaultValue
        heaviest = weight_axis.maxValue
        cap_weight = min(660.0, heaviest)
        cap_coordinate = (cap_weight - lightest) / (heaviest - lightest)

        avar = newTable("avar")
        avar.majorVersion = 1
        avar.minorVersion = 0
        avar.segments = {}
        for axis in font["fvar"].axes:
            if axis.axisTag == "wght":
                avar.segments[axis.axisTag] = {
                    -1.0: -1.0,
                    0.0: 0.0,
                    cap_coordinate: cap_coordinate,
                    1.0: cap_coordinate,
                }
            else:
                avar.segments[axis.axisTag] = {-1.0: -1.0, 0.0: 0.0, 1.0: 1.0}
        font["avar"] = avar

    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(destination.name + ".tmp")
    try:
        font.save(temporary)
        # Validate that the produced file can be reopened and the axis map and
        # two-contour glyph survived serialization.
        check = TTFont(temporary)
        check_coordinates, check_ends, _ = check["glyf"]["i"].getCoordinates(
            check["glyf"]
        )
        if len(check_coordinates) != 34 or list(check_ends) != [17, 33]:
            raise ValueError("Generated font failed lowercase-i outline validation.")
        if check["avar"].segments["wght"][1.0] >= 1.0:
            raise ValueError("Generated font failed the Fredoka weight adjustment.")
        check.close()
        font.close()
        os.replace(temporary, destination)
    finally:
        if temporary.exists():
            temporary.unlink()
        font.close()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="Original Fredoka variable TTF")
    parser.add_argument("destination", type=Path, help="Output TTF path")
    args = parser.parse_args()
    customize(args.source, args.destination)


if __name__ == "__main__":
    main()
