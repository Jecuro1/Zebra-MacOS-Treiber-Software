#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Erzeugt die eingebetteten Bitmap-Schriften des Software-Rasterizers (LabelWerkRender).

Aus drei DejaVu-Schriften werden 1-Bit-Mastervorlagen aller unterstützten Zeichen gerendert
und als zlib-komprimierte, Base64-kodierte Swift-Literale in
``Sources/LabelWerkRender/Rasterizer/BitmapFontData.swift`` geschrieben:

* ``sansBold``  – DejaVu Sans Bold: Grundlage der skalierbaren ZPL-Schrift 0
  (CG Triumvirate Bold Condensed wird durch horizontale Stauchung angenähert).
* ``sans``      – DejaVu Sans: Ersatz für geladene TrueType-Schriften (``^A@``), P–V usw.
* ``mono``      – DejaVu Sans Mono: Aussehen der residenten Bitmap-Schriften A–H.

Zeichenvorrat: druckbares ASCII, ISO 8859-1 (A0–FF), die Zusatzzeichen von Windows-1252
(u. a. €, „ “ – — ™) sowie Latin Extended-A (U+0100–U+017F).

Die Mastergröße ist so gewählt, dass die Versalhöhe ca. 32 Pixel beträgt (Schriftgröße
44 px bei 2048 Einheiten/Geviert und Versalhöhe 1493). Jede Glyphe wird mit Kantenglättung
gerendert und bei 50 % Deckung binarisiert, anschließend auf ihre Tinte zugeschnitten.

Binärformat (Little Endian) vor der zlib-Kompression::

    Kopf:   "LWF1" | u8 Geviertgröße | u8 Oberlänge | u8 Unterlänge | u8 Versalhöhe
            | u8 x-Höhe | u16 Glyphenanzahl
    Glyphe: u16 Codepunkt | u16 Vorschub × 16 | u8 Breite | u8 Höhe | i8 linker Versatz
            | i8 Oberkante über der Grundlinie | ceil(Breite × Höhe / 8) Bytes Bitdaten
            (zeilenweise, ohne Zeilenauffüllung, höchstwertiges Bit zuerst, 1 = schwarz)

Aufruf (aus dem Paketverzeichnis)::

    python3 Sources/LabelWerkRender/.fontgen/generate_font.py \\
        [--font-dir /usr/share/fonts/truetype/dejavu] \\
        [--output Sources/LabelWerkRender/Rasterizer/BitmapFontData.swift]

Benötigt Pillow (getestet mit Pillow 13). Die Ausgabe ist deterministisch.

Das Verzeichnis ``.fontgen`` beginnt mit einem Punkt: SwiftPM überspringt versteckte
Verzeichnisse, meldet diese Python-Datei daher nicht als unbehandelte Datei des Ziels
LabelWerkRender (``Package.swift`` bleibt unverändert).
"""

from __future__ import annotations

import argparse
import base64
import os
import struct
import sys
import zlib

from PIL import Image, ImageDraw, ImageFont

# Schriftgröße der Mastervorlagen in Pixeln (Versalhöhe ≈ 32 px).
EM_SIZE = 44
# Binarisierungsschwelle (0…255) für die kantengeglättete Darstellung.
THRESHOLD = 128
# Länge der Base64-Zeilen im erzeugten Swift-Quelltext.
LINE_LENGTH = 100

FONTS = [
    ("sansBold", "DejaVuSans-Bold.ttf",
     "DejaVu Sans Bold – Vorlage für die skalierbare ZPL-Schrift 0."),
    ("sans", "DejaVuSans.ttf",
     "DejaVu Sans – Ersatz für geladene und nicht residente Schriften (^A@, P–V, ^CW)."),
    ("mono", "DejaVuSansMono.ttf",
     "DejaVu Sans Mono – Aussehen der residenten Bitmap-Schriften A–H und der Klarschriftzeilen."),
]

# Lizenzhinweis der DejaVu-Schriften (Bitstream Vera, DejaVu-Änderungen gemeinfrei).
LICENSE_NOTICE = """\
DejaVu fonts – https://dejavu-fonts.github.io/
Fonts are (c) Bitstream (see below). DejaVu changes are in public domain.

Bitstream Vera Fonts Copyright
Copyright (c) 2003 by Bitstream, Inc. All Rights Reserved. Bitstream Vera is
a trademark of Bitstream, Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of the fonts accompanying this license ("Fonts") and associated
documentation files (the "Font Software"), to reproduce and distribute the
Font Software, including without limitation the rights to use, copy, merge,
publish, distribute, and/or sell copies of the Font Software, and to permit
persons to whom the Font Software is furnished to do so, subject to the
following conditions:

The above copyright and trademark notices and this permission notice shall
be included in all copies of one or more of the Font Software typefaces.

The Font Software may be modified, altered, or added to, and in particular
the designs of glyphs or characters in the Fonts may be modified and
additional glyphs or characters may be added to the Fonts, only if the fonts
are renamed to names not containing either the words "Bitstream" or the word
"Vera".

This License becomes null and void to the extent applicable to Fonts or Font
Software that has been modified and is distributed under the "Bitstream
Vera" names.

The Font Software may be sold as part of a larger software package but no
copy of one or more of the Font Software typefaces may be sold by itself.

THE FONT SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
OR IMPLIED, INCLUDING BUT NOT LIMITED TO ANY WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF COPYRIGHT, PATENT,
TRADEMARK, OR OTHER RIGHT. IN NO EVENT SHALL BITSTREAM OR THE GNOME
FOUNDATION BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, INCLUDING
ANY GENERAL, SPECIAL, INDIRECT, INCIDENTAL, OR CONSEQUENTIAL DAMAGES,
WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF
THE USE OR INABILITY TO USE THE FONT SOFTWARE OR FROM OTHER DEALINGS IN THE
FONT SOFTWARE.

Except as contained in this notice, the names of Gnome, the Gnome
Foundation, and Bitstream Inc., shall not be used in advertising or
otherwise to promote the sale, use or other dealings in this Font Software
without prior written authorization from the Gnome Foundation or Bitstream
Inc., respectively. For further information, contact: fonts at gnome dot
org."""


def character_set() -> list[int]:
    """Alle Codepunkte, für die Glyphen erzeugt werden (aufsteigend sortiert)."""
    points = set(range(0x20, 0x7F))                 # druckbares ASCII
    points.update(range(0xA0, 0x100))               # ISO 8859-1
    cp1252 = bytes(range(0x80, 0xA0)).decode("cp1252", errors="ignore")
    points.update(ord(ch) for ch in cp1252)         # €, „, “, –, —, ™ …
    points.update(range(0x100, 0x180))              # Latin Extended-A
    points.discard(0xAD)                            # weiches Trennzeichen: unsichtbar
    return sorted(points)


def render_glyph(font: ImageFont.FreeTypeFont, codepoint: int):
    """Rendert eine Glyphe und liefert (Vorschub×16, Breite, Höhe, links, oben, Bits)."""
    ch = chr(codepoint)
    advance16 = int(round(font.getlength(ch) * 16))
    x0, y0, x1, y1 = font.getbbox(ch, anchor="ls")
    if x1 <= x0 or y1 <= y0:
        return advance16, 0, 0, 0, 0, b""
    pad = 2
    image = Image.new("L", (x1 - x0 + 2 * pad, y1 - y0 + 2 * pad), 0)
    ImageDraw.Draw(image).text((pad - x0, pad - y0), ch, font=font, anchor="ls", fill=255)
    binary = image.point(lambda v: 255 if v >= THRESHOLD else 0)
    ink = binary.getbbox()
    if ink is None:
        return advance16, 0, 0, 0, 0, b""
    left = ink[0] - pad + x0
    top = -(ink[1] - pad + y0)
    cropped = binary.crop(ink)
    width, height = cropped.size
    if width > 255 or height > 255 or not (-128 <= left <= 127) or not (-128 <= top <= 127):
        raise ValueError(f"Glyphe U+{codepoint:04X} passt nicht in das Binärformat")
    pixels = cropped.load()
    bits = bytearray((width * height + 7) // 8)
    index = 0
    for y in range(height):
        for x in range(width):
            if pixels[x, y]:
                bits[index >> 3] |= 0x80 >> (index & 7)
            index += 1
    return advance16, width, height, left, top, bytes(bits)


def ink_height(font: ImageFont.FreeTypeFont, ch: str) -> int:
    """Höhe der Tinte eines Zeichens über der Grundlinie (für Versal- und x-Höhe)."""
    _, _, _, _, top, _ = render_glyph(font, ord(ch))
    return top


def build_blob(path: str) -> bytes:
    """Rendert alle Glyphen einer Schrift in das Binärformat (unkomprimiert)."""
    font = ImageFont.truetype(path, EM_SIZE)
    ascent, descent = font.getmetrics()
    points = character_set()
    out = bytearray(b"LWF1")
    out += struct.pack("<BBBBBH", EM_SIZE, ascent, descent, ink_height(font, "H"),
                       ink_height(font, "x"), len(points))
    for codepoint in points:
        advance16, width, height, left, top, bits = render_glyph(font, codepoint)
        out += struct.pack("<HHBBbb", codepoint, advance16, width, height, left, top)
        out += bits
    return bytes(out)


def swift_literal(name: str, comment: str, blob: bytes) -> str:
    """Formatiert einen komprimierten Blob als Swift-Array aus Base64-Zeilen."""
    encoded = base64.b64encode(zlib.compress(blob, 9)).decode("ascii")
    lines = [encoded[i:i + LINE_LENGTH] for i in range(0, len(encoded), LINE_LENGTH)]
    body = "\n".join(f'        "{line}",' for line in lines)
    return (f"    /// {comment}\n"
            f"    /// {len(blob)} Bytes unkomprimiert.\n"
            f"    static let {name}: [String] = [\n{body}\n    ]\n")


def main() -> int:
    here = os.path.dirname(os.path.abspath(__file__))
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--font-dir", default="/usr/share/fonts/truetype/dejavu",
                        help="Verzeichnis mit den DejaVu-TTF-Dateien")
    parser.add_argument("--output", default=os.path.join(here, "..", "Rasterizer", "BitmapFontData.swift"),
                        help="Zieldatei (Swift)")
    args = parser.parse_args()

    sections = []
    for name, filename, comment in FONTS:
        path = os.path.join(args.font_dir, filename)
        if not os.path.exists(path):
            print(f"Schrift nicht gefunden: {path}", file=sys.stderr)
            return 1
        sections.append(swift_literal(name, comment, build_blob(path)))

    notice = "\n".join(("// " + line).rstrip() for line in LICENSE_NOTICE.splitlines())
    source = (
        "// Automatisch erzeugt von Sources/LabelWerkRender/.fontgen/generate_font.py –\n"
        "// nicht von Hand bearbeiten.\n"
        "//\n"
        "// Die Bitmap-Glyphen wurden aus den DejaVu-Schriften (Sans, Sans Bold, Sans Mono) gerendert.\n"
        "// Lizenzhinweis der Vorlagen:\n"
        "//\n"
        f"{notice}\n"
        "\n"
        "/// Eingebettete 1-Bit-Mastervorlagen der Rasterizer-Schriften (zlib + Base64, siehe\n"
        "/// `generate_font.py` für das Binärformat). Dekodiert wird einmalig in `BitmapFont`.\n"
        "enum BitmapFontData {\n"
        + "\n".join(sections)
        + "}\n"
    )
    output = os.path.abspath(args.output)
    with open(output, "w", encoding="utf-8") as handle:
        handle.write(source)
    print(f"{output}: {len(source)} Zeichen geschrieben")
    return 0


if __name__ == "__main__":
    sys.exit(main())
