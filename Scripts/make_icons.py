#!/usr/bin/env python3
"""Erzeugt die Symbole von LabelWerk prozedural (nur Pillow, keine Vorlagen-Grafiken).

Ausgaben (alle unter ``Installer/``):

* ``Resources/AppIcon.icns`` – App-Symbol im Stil von macOS 11+ (Squircle mit Verlauf
  Indigo → Violett → Petrol, dezentes Zebramuster, Drucker mit leuchtendem Schlitz und
  herausfahrendem Etikett mit Barcode, weiche Schatten und Lichtkante).
* ``Resources/LabelWerk.icns`` – Druckersymbol für die CUPS-Warteschlange (freigestellter
  Drucker mit Etikett, Lichtleiste und Bodenschatten; wird über ``*APPrinterIconPath`` angezeigt).
* ``Resources/icon-preview/*.png`` – Vorschauen in allen Größen und eine Übersichtstafel.
* ``pkg/Resources/background.png`` und ``background-dark.png`` – Hintergrund des Installers.

Kleine Größen (16–32 px) und mittlere Größen (64–128 px) werden mit vereinfachten Details neu
gezeichnet statt nur verkleinert, damit sie scharf und lesbar bleiben. Die icns-Datei wird
direkt geschrieben (Container „icns“ mit PNG-Einträgen ic07–ic14 sowie ARGB-Einträgen ic04/ic05
und klassischen is32/s8mk- bzw. il32/l8mk-Einträgen für 16 und 32 px), ``iconutil`` wird nicht
benötigt. Die Ausgabe ist deterministisch.

Aufruf::

    python3 Scripts/make_icons.py               # alles erzeugen
    python3 Scripts/make_icons.py --check       # vorhandene icns-Dateien prüfen (Struktur, Größen)
    python3 Scripts/make_icons.py --output DIR  # in ein anderes Verzeichnis schreiben (Tests)
"""

from __future__ import annotations

import argparse
import io
import math
import struct
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Dict, Iterable, List, Optional, Sequence, Tuple

try:
    from PIL import Image, ImageChops, ImageDraw, ImageFilter
except ImportError:  # pragma: no cover - Hinweis für Entwickler ohne Pillow
    sys.stderr.write("Fehler: Pillow fehlt – bitte mit „python3 -m pip install pillow“ installieren.\n")
    raise SystemExit(2)

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUTPUT = REPO_ROOT / "Installer"

RGB = Tuple[int, int, int]
Box = Tuple[float, float, float, float]

# --------------------------------------------------------------------------------------------
# Farben
# --------------------------------------------------------------------------------------------

INDIGO_DEEP: RGB = (26, 22, 84)
INDIGO: RGB = (49, 39, 140)
VIOLET: RGB = (124, 58, 237)
VIOLET_BRIGHT: RGB = (150, 92, 255)
TEAL: RGB = (20, 184, 166)
TEAL_BRIGHT: RGB = (94, 234, 212)
GRAPHITE_TOP: RGB = (64, 68, 104)
GRAPHITE_MID: RGB = (36, 38, 64)
GRAPHITE_BOTTOM: RGB = (16, 17, 32)
INK: RGB = (22, 18, 58)
PAPER: RGB = (252, 252, 255)
PAPER_SHADE: RGB = (226, 228, 242)

# --------------------------------------------------------------------------------------------
# Grundlagen: Leinwand in 1024er-Einheiten
# --------------------------------------------------------------------------------------------


def lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * t


def lerp_color(a: Sequence[float], b: Sequence[float], t: float) -> RGB:
    return tuple(int(round(lerp(x, y, t))) for x, y in zip(a, b))  # type: ignore[return-value]


def smoothstep(t: float) -> float:
    t = min(1.0, max(0.0, t))
    return t * t * (3.0 - 2.0 * t)


def sample_stops(stops: Sequence[Tuple[float, RGB]], t: float) -> RGB:
    """Farbe eines Mehrfarbverlaufs an Position t (0…1), weich interpoliert."""
    t = min(1.0, max(0.0, t))
    for (p0, c0), (p1, c1) in zip(stops, stops[1:]):
        if t <= p1:
            local = 0.0 if p1 == p0 else (t - p0) / (p1 - p0)
            return lerp_color(c0, c1, smoothstep(local) * 0.35 + local * 0.65)
    return stops[-1][1]


class Canvas:
    """RGBA-Bild, dessen Zeichenbefehle in Einheiten eines 1024er-Rasters angegeben werden."""

    def __init__(self, pixels: int) -> None:
        self.px = pixels
        self.s = pixels / 1024.0
        self.image = Image.new("RGBA", (pixels, pixels), (0, 0, 0, 0))

    # Umrechnung ---------------------------------------------------------------------------

    def u(self, value: float) -> float:
        return value * self.s

    def box(self, box: Box) -> Tuple[float, float, float, float]:
        return tuple(v * self.s for v in box)  # type: ignore[return-value]

    # Masken -------------------------------------------------------------------------------

    def new_mask(self) -> Image.Image:
        return Image.new("L", (self.px, self.px), 0)

    def rounded_rect_mask(self, box: Box, radius: float, value: int = 255) -> Image.Image:
        mask = self.new_mask()
        ImageDraw.Draw(mask).rounded_rectangle(self.box(box), radius=self.u(radius), fill=value)
        return mask

    def polygon_mask(self, points: Iterable[Tuple[float, float]], value: int = 255) -> Image.Image:
        mask = self.new_mask()
        ImageDraw.Draw(mask).polygon([(x * self.s, y * self.s) for x, y in points], fill=value)
        return mask

    def ellipse_mask(self, box: Box, value: int = 255) -> Image.Image:
        mask = self.new_mask()
        ImageDraw.Draw(mask).ellipse(self.box(box), fill=value)
        return mask

    def blur(self, mask: Image.Image, radius: float) -> Image.Image:
        if radius <= 0:
            return mask
        return mask.filter(ImageFilter.GaussianBlur(self.u(radius)))

    # Komposition --------------------------------------------------------------------------

    def fill(self, color: Sequence[int], mask: Image.Image, opacity: float = 1.0) -> None:
        """Deckende Farbe durch eine Maske auftragen (normales Überblenden)."""
        layer = Image.new("RGBA", self.image.size, tuple(color[:3]) + (255,))
        layer.putalpha(scale_mask(mask, opacity))
        self.image = Image.alpha_composite(self.image, layer)

    def paint(self, source: Image.Image, mask: Image.Image, opacity: float = 1.0) -> None:
        """Ein RGB-Bild (z. B. einen Verlauf) durch eine Maske auftragen."""
        layer = source.convert("RGBA")
        layer.putalpha(scale_mask(mask, opacity))
        self.image = Image.alpha_composite(self.image, layer)

    def add_light(self, color: Sequence[int], mask: Image.Image, strength: float = 1.0) -> None:
        """Additives Licht (Leuchten): Farbe × Maske wird auf die RGB-Kanäle addiert."""
        light = Image.new("RGB", self.image.size, (0, 0, 0))
        tint = Image.new("RGB", self.image.size, tuple(color[:3]))
        light = Image.composite(tint, light, scale_mask(mask, strength))
        r, g, b, a = self.image.split()
        rgb = ImageChops.add(Image.merge("RGB", (r, g, b)), light)
        self.image = Image.merge("RGBA", (*rgb.split(), a))

    # Verläufe -----------------------------------------------------------------------------

    def linear_gradient(self, stops: Sequence[Tuple[float, RGB]], start: Tuple[float, float],
                        end: Tuple[float, float]) -> Image.Image:
        """RGB-Verlauf von `start` nach `end` (1024er-Einheiten) über die ganze Leinwand."""
        size = self.px
        x0, y0 = start[0] * self.s, start[1] * self.s
        x1, y1 = end[0] * self.s, end[1] * self.s
        dx, dy = x1 - x0, y1 - y0
        length = math.hypot(dx, dy) or 1.0
        ux, uy = dx / length, dy / length
        side = int(math.ceil(math.hypot(size, size))) + 4
        center = size / 2.0
        p_start = (x0 - center) * ux + (y0 - center) * uy
        strip = Image.new("RGB", (side, 1))
        pixels = []
        for i in range(side):
            p = i + 0.5 - side / 2.0
            pixels.append(sample_stops(stops, (p - p_start) / length))
        strip.putdata(pixels)
        square = strip.resize((side, side), Image.Resampling.NEAREST)
        angle = math.degrees(math.atan2(uy, ux))
        rotated = square.rotate(-angle, resample=Image.Resampling.BICUBIC, expand=False)
        offset = (side - size) // 2
        return rotated.crop((offset, offset, offset + size, offset + size))

    def radial_mask(self, box: Box, falloff: Callable[[float], float], peak: int = 255) -> Image.Image:
        """Maske mit radialem Verlauf in der Ellipse `box`; falloff(d) für d = 0 (Mitte) … 1 (Rand)."""
        base = Image.new("L", (256, 256), 0)
        values = []
        for y in range(256):
            for x in range(256):
                d = math.hypot((x + 0.5 - 128) / 128.0, (y + 0.5 - 128) / 128.0)
                values.append(int(round(peak * max(0.0, min(1.0, falloff(d))))) if d <= 1.0 else 0)
        base.putdata(values)
        left, top, right, bottom = self.box(box)
        width = max(1, int(round(right - left)))
        height = max(1, int(round(bottom - top)))
        scaled = base.resize((width, height), Image.Resampling.BICUBIC)
        mask = self.new_mask()
        mask.paste(scaled, (int(round(left)), int(round(top))))
        return mask

    def vertical_ramp(self, top: float, bottom: float, value_top: float, value_bottom: float) -> Image.Image:
        """Maske, die zwischen `top` und `bottom` (1024er-Einheiten) linear von value_top nach value_bottom verläuft."""
        column = Image.new("L", (1, self.px))
        data = []
        for y in range(self.px):
            t = ((y + 0.5) / self.s - top) / max(1e-6, bottom - top)
            t = min(1.0, max(0.0, t))
            data.append(int(round(255 * lerp(value_top, value_bottom, t))))
        column.putdata(data)
        return column.resize((self.px, self.px), Image.Resampling.NEAREST)


def scale_mask(mask: Image.Image, factor: float) -> Image.Image:
    if factor >= 0.999:
        return mask
    lut = [int(round(v * max(0.0, factor))) for v in range(256)]
    return mask.point(lut)


def multiply_masks(a: Image.Image, b: Image.Image) -> Image.Image:
    return ImageChops.multiply(a, b)


def subtract_mask(a: Image.Image, b: Image.Image) -> Image.Image:
    return ImageChops.subtract(a, b)


def shifted(mask: Image.Image, dx: float, dy: float) -> Image.Image:
    return ImageChops.offset(mask, int(round(dx)), int(round(dy)))


def superellipse(cx: float, cy: float, rx: float, ry: float, exponent: float = 5.0,
                 count: int = 1440) -> List[Tuple[float, float]]:
    """Punkte einer Superellipse |x|^n + |y|^n = 1 (für Leuchtflecken und Tests)."""
    points = []
    for i in range(count):
        angle = 2.0 * math.pi * i / count
        c, s = math.cos(angle), math.sin(angle)
        x = cx + rx * math.copysign(abs(c) ** (2.0 / exponent), c)
        y = cy + ry * math.copysign(abs(s) ** (2.0 / exponent), s)
        points.append((x, y))
    return points


def continuous_rounded_rect(box: Box, extent: float, exponent: float = 4.5,
                            count: int = 240) -> List[Tuple[float, float]]:
    """Rechteck mit „kontinuierlichen“ Ecken wie die macOS-Symbolform (Squircle).

    Jede Ecke ist ein Viertel einer Superellipse mit Ausdehnung `extent`; dazwischen verlaufen
    gerade Kanten. Bei 824er-Kantenlänge entspricht extent ≈ 270 (≈ 1,46 × Eckradius 185) der
    Apple-Vorlage.
    """
    x0, y0, x1, y1 = box
    corners = [(x1 - extent, y0 + extent, -90.0), (x1 - extent, y1 - extent, 0.0),
               (x0 + extent, y1 - extent, 90.0), (x0 + extent, y0 + extent, 180.0)]
    points: List[Tuple[float, float]] = []
    for cx, cy, start in corners:
        for i in range(count + 1):
            angle = math.radians(start + 90.0 * i / count)
            c, s = math.cos(angle), math.sin(angle)
            points.append((cx + extent * math.copysign(abs(c) ** (2.0 / exponent), c),
                           cy + extent * math.copysign(abs(s) ** (2.0 / exponent), s)))
    return points


ICON_TILE: Box = (100, 100, 924, 924)
ICON_CORNER = 270.0


# --------------------------------------------------------------------------------------------
# Motiv
# --------------------------------------------------------------------------------------------


@dataclass(frozen=True)
class Detail:
    """Detailstufe je Ausgabegröße."""

    name: str
    stripes: bool
    label_text: bool
    barcode_bars: int
    printer_details: bool
    glow: float

    @staticmethod
    def for_size(pixels: int) -> "Detail":
        if pixels <= 16:
            return Detail("winzig", stripes=False, label_text=False, barcode_bars=3, printer_details=False, glow=0.6)
        if pixels <= 32:
            return Detail("klein", stripes=False, label_text=False, barcode_bars=5, printer_details=False, glow=0.7)
        if pixels <= 64:
            return Detail("mittel", stripes=True, label_text=True, barcode_bars=9, printer_details=False, glow=0.9)
        if pixels <= 128:
            return Detail("mittel", stripes=True, label_text=True, barcode_bars=13, printer_details=False, glow=0.9)
        return Detail("voll", stripes=True, label_text=True, barcode_bars=0, printer_details=True, glow=1.0)


# Barcode-Muster (Breiten in Moduleinheiten, beginnend mit einem Strich) – angelehnt an Code 128.
BARCODE_FULL = [2, 1, 1, 2, 3, 1, 1, 3, 1, 1, 2, 2, 1, 1, 3, 1, 2, 1, 1, 2, 1, 1, 3, 2, 1, 1, 2, 1, 3, 1,
                1, 2, 2, 1, 1, 3, 1, 2, 1, 1, 2, 2, 3, 1, 1, 1, 2, 3, 1, 2, 1, 1, 2, 1, 1, 3, 2, 1, 2]
BARCODE_MEDIUM = [3, 2, 2, 2, 4, 2, 2, 3, 2, 2, 3, 2, 4, 2, 2, 2, 3, 2, 2, 2, 3, 2, 4, 2, 3]
BARCODE_SMALL = [4, 3, 3, 3, 5, 3, 3, 3, 4]
BARCODE_TINY = [3, 2, 3, 2, 3]


@dataclass(frozen=True)
class Scene:
    """Lage von Drucker und Etikett in 1024er-Einheiten."""

    body: Box            # Druckergehäuse
    body_radius: float
    lid_bottom: float    # Unterkante der hellen Oberseite
    slot_y: float        # Mittellinie des Ausgabeschlitzes
    slot_inset: float    # Abstand des Schlitzes vom Gehäuserand
    label_x: Tuple[float, float]
    label_top: float
    label_radius: float
    light_bar: bool      # Lichtleiste in der Front (Druckersymbol)


APP_SCENE = Scene(body=(204, 566, 820, 834), body_radius=70, lid_bottom=664, slot_y=612, slot_inset=86,
                  label_x=(330, 694), label_top=196, label_radius=26, light_bar=False)
APP_SCENE_SMALL = Scene(body=(188, 580, 836, 850), body_radius=80, lid_bottom=680, slot_y=626, slot_inset=70,
                        label_x=(300, 724), label_top=176, label_radius=34, light_bar=False)
PRINTER_SCENE = Scene(body=(96, 470, 928, 892), body_radius=112, lid_bottom=618, slot_y=540, slot_inset=120,
                      label_x=(270, 754), label_top=86, label_radius=34, light_bar=True)


def draw_printer_and_label(c: Canvas, scene: Scene, detail: Detail, cast_on: Optional[Image.Image] = None) -> None:
    """Zeichnet Drucker, Schlitzleuchten und Etikett (inkl. Schatten) auf die Leinwand."""
    x0, y0, x1, y1 = scene.body
    lx0, lx1 = scene.label_x

    # Schatten des Druckers (Kontakt + weich).
    body_mask = c.rounded_rect_mask(scene.body, scene.body_radius)
    soft = c.blur(shifted(body_mask, 0, c.u(26)), 30)
    contact = c.blur(shifted(body_mask, 0, c.u(8)), 8)
    if cast_on is not None:
        soft = multiply_masks(soft, cast_on)
        contact = multiply_masks(contact, cast_on)
    c.fill((8, 6, 30), soft, 0.55)
    c.fill((8, 6, 30), contact, 0.35)

    # Gehäuse: Front mit Verlauf.
    front = c.linear_gradient([(0.0, GRAPHITE_MID), (1.0, GRAPHITE_BOTTOM)], (512, scene.lid_bottom), (512, y1))
    c.paint(front, body_mask)

    # Oberseite (heller, leicht violett getönt) – obere Gehäusepartie bis lid_bottom.
    lid_mask = multiply_masks(body_mask, c.rounded_rect_mask((x0, y0, x1, scene.lid_bottom + scene.body_radius),
                                                              scene.body_radius))
    lid_clip = c.new_mask()
    ImageDraw.Draw(lid_clip).rectangle(c.box((x0, y0, x1, scene.lid_bottom)), fill=255)
    lid_mask = multiply_masks(lid_mask, lid_clip)
    lid = c.linear_gradient([(0.0, (92, 96, 146)), (0.55, GRAPHITE_TOP), (1.0, (46, 49, 80))], (512, y0),
                            (512, scene.lid_bottom))
    c.paint(lid, lid_mask)

    # Kante zwischen Oberseite und Front: dunkle Fuge + Lichtkante darunter.
    seam = c.new_mask()
    ImageDraw.Draw(seam).rectangle(c.box((x0, scene.lid_bottom - 2, x1, scene.lid_bottom + 2)), fill=255)
    c.fill((10, 10, 22), multiply_masks(seam, body_mask), 0.85)
    edge = c.new_mask()
    ImageDraw.Draw(edge).rectangle(c.box((x0, scene.lid_bottom + 3, x1, scene.lid_bottom + 6)), fill=255)
    c.fill((255, 255, 255), multiply_masks(edge, body_mask), 0.10)

    # Lichtkante oben am Gehäuse.
    rim = subtract_mask(body_mask, shifted(body_mask, 0, c.u(4)))
    c.fill((255, 255, 255), multiply_masks(rim, c.vertical_ramp(y0, y0 + 40, 1.0, 0.0)), 0.55)

    # Lichtleiste in der Front (Druckersymbol): Verlauf Violett → Petrol mit Leuchten.
    if scene.light_bar:
        bar_box = (x0 + 70, y1 - 128, x1 - 70, y1 - 112)
        bar_mask = c.rounded_rect_mask(bar_box, 8)
        bar = c.linear_gradient([(0.0, VIOLET_BRIGHT), (0.5, (168, 120, 255)), (1.0, TEAL_BRIGHT)],
                                (bar_box[0], 0), (bar_box[2], 0))
        c.add_light((110, 80, 255), c.blur(bar_mask, 26), 0.55 * detail.glow)
        c.paint(bar, bar_mask)
        c.fill((255, 255, 255), c.rounded_rect_mask((bar_box[0] + 10, bar_box[1] + 3, bar_box[2] - 10,
                                                     bar_box[1] + 7), 2), 0.35)

    # Bedienelemente.
    if detail.printer_details:
        if scene.light_bar:
            led_center = (x1 - 128, y1 - 196)
            display = (x0 + 110, y1 - 204, x0 + 300, y1 - 188)
        else:
            led_center = (x1 - 86, y1 - 82)
            display = (x0 + 70, y1 - 90, x0 + 230, y1 - 74)
        c.fill((120, 128, 182), c.rounded_rect_mask(display, 8), 0.55)
        led = (led_center[0] - 13, led_center[1] - 13, led_center[0] + 13, led_center[1] + 13)
        c.add_light(TEAL, c.blur(c.ellipse_mask(led), 22), 0.9 * detail.glow)
        c.fill(TEAL_BRIGHT, c.ellipse_mask(led))
        c.fill((255, 255, 255), c.ellipse_mask((led[0] + 7, led[1] + 5, led[0] + 15, led[1] + 12)), 0.7)
    elif detail.name == "mittel":
        led = (x1 - 110, y1 - 104, x1 - 70, y1 - 64) if not scene.light_bar else (x1 - 150, y1 - 210, x1 - 110,
                                                                                    y1 - 170)
        c.add_light(TEAL, c.blur(c.ellipse_mask(led), 18), 0.8 * detail.glow)
        c.fill(TEAL_BRIGHT, c.ellipse_mask(led))

    # Ausgabeschlitz.
    slot_box = (x0 + scene.slot_inset, scene.slot_y - 13, x1 - scene.slot_inset, scene.slot_y + 13)
    slot_mask = c.rounded_rect_mask(slot_box, 13)
    c.fill((6, 6, 14), slot_mask)

    # Leuchten aus dem Schlitz (unter dem Etikett, strahlt auf Oberseite und Papier).
    glow_box = (slot_box[0] - 10, scene.slot_y - 40, slot_box[2] + 10, scene.slot_y + 22)
    c.add_light(TEAL, c.blur(c.rounded_rect_mask(glow_box, 30), 34), 0.85 * detail.glow)

    # Etikett: Schatten, Papier, Inhalt.
    label_box = (lx0, scene.label_top, lx1, scene.slot_y)
    label_mask = c.rounded_rect_mask((lx0, scene.label_top, lx1, scene.slot_y + 60), scene.label_radius)
    clip = c.new_mask()
    ImageDraw.Draw(clip).rectangle(c.box((0, 0, 1024, scene.slot_y)), fill=255)
    label_mask = multiply_masks(label_mask, clip)
    shadow = c.blur(shifted(label_mask, 0, c.u(14)), 24)
    c.fill((10, 6, 40), shadow, 0.42)
    c.fill((10, 6, 40), c.blur(label_mask, 5), 0.25)
    paper = c.linear_gradient([(0.0, PAPER_SHADE), (0.10, PAPER), (0.86, PAPER), (1.0, (214, 246, 240))],
                              (512, scene.label_top), (512, scene.slot_y))
    c.paint(paper, label_mask)
    # Seitliche Schattierung (leichte Wölbung des Papiers).
    side = c.linear_gradient([(0.0, (0, 0, 0)), (0.12, (255, 255, 255)), (0.88, (255, 255, 255)),
                              (1.0, (0, 0, 0))], (lx0, 0), (lx1, 0)).convert("L")
    c.fill((150, 150, 190), multiply_masks(label_mask, ImageChops.invert(side)), 0.12)
    # Petrolfarbenes Licht vom Schlitz auf dem unteren Papierrand.
    c.add_light(TEAL, multiply_masks(label_mask, c.vertical_ramp(scene.slot_y - 70, scene.slot_y, 0.0, 1.0)),
                0.30 * detail.glow)

    draw_label_content(c, scene, detail, label_box)

    # Vorderkante des Schlitzes (liegt vor dem Etikett).
    lip = (slot_box[0], scene.slot_y, slot_box[2], scene.slot_y + 13)
    lip_mask = multiply_masks(c.rounded_rect_mask(slot_box, 13), c.rounded_rect_mask(lip, 0))
    c.fill((8, 8, 18), lip_mask)
    c.fill((255, 255, 255), c.rounded_rect_mask((slot_box[0] + 14, scene.slot_y + 13, slot_box[2] - 14,
                                                 scene.slot_y + 16), 1.5), 0.22)


def draw_label_content(c: Canvas, scene: Scene, detail: Detail, label_box: Box) -> None:
    lx0, ly0, lx1, ly1 = label_box
    width = lx1 - lx0
    pad = width * 0.095
    inner_x0, inner_x1 = lx0 + pad, lx1 - pad
    y = ly0 + pad * 0.95

    if detail.label_text:
        # Kopfzeile: Markenzeichen (Verlauf) + zwei Textzeilen.
        mark = (inner_x0, y, inner_x0 + width * 0.13, y + width * 0.13)
        mark_mask = c.rounded_rect_mask(mark, width * 0.035)
        gradient = c.linear_gradient([(0.0, VIOLET), (1.0, TEAL)], (mark[0], mark[1]), (mark[2], mark[3]))
        c.paint(gradient, mark_mask)
        # Zebrastreifen im Markenzeichen.
        stripes = c.new_mask()
        draw = ImageDraw.Draw(stripes)
        step = (mark[2] - mark[0]) / 3.2
        for i in range(-2, 5):
            sx = mark[0] + i * step
            draw.polygon([(c.u(sx), c.u(mark[3])), (c.u(sx + step * 0.45), c.u(mark[3])),
                          (c.u(sx + step * 1.45), c.u(mark[1])), (c.u(sx + step), c.u(mark[1]))], fill=255)
        c.fill((255, 255, 255), multiply_masks(stripes, mark_mask), 0.85)
        text_x = mark[2] + width * 0.05
        line_h = width * 0.034
        c.fill(INK, c.rounded_rect_mask((text_x, mark[1] + line_h * 0.35, inner_x1 - width * 0.08,
                                         mark[1] + line_h * 1.35), line_h / 2), 0.88)
        c.fill((140, 140, 172), c.rounded_rect_mask((text_x, mark[1] + line_h * 2.15, inner_x1 - width * 0.30,
                                                     mark[1] + line_h * 2.95), line_h / 2), 0.9)
        y = mark[3] + width * 0.07
        # Trennlinie.
        c.fill((206, 208, 226), c.rounded_rect_mask((inner_x0, y, inner_x1, y + 3), 1.5))
        y += width * 0.07

    # Barcode.
    if detail.barcode_bars == 0:
        pattern = BARCODE_FULL
    elif detail.barcode_bars > 9:
        pattern = BARCODE_MEDIUM
    elif detail.barcode_bars > 3:
        pattern = BARCODE_SMALL
    else:
        pattern = BARCODE_TINY
    total_modules = sum(pattern)
    bars_bottom = ly1 - (width * 0.26 if detail.label_text else width * 0.22)
    if not detail.label_text:
        y = ly0 + width * 0.16
    module = (inner_x1 - inner_x0) / total_modules
    bars = c.new_mask()
    draw = ImageDraw.Draw(bars)
    x = inner_x0
    for index, modules in enumerate(pattern):
        w = modules * module
        if index % 2 == 0:
            draw.rectangle((c.u(x), c.u(y), c.u(x + w) - 0.5, c.u(bars_bottom)), fill=255)
        x += w
    c.fill(INK, bars)

    # Klarschrift unter dem Barcode als feine Zeichenblöcke.
    if detail.label_text:
        glyph_y0 = bars_bottom + width * 0.045
        glyph_h = width * 0.04
        glyphs = 12 if detail.printer_details else 8
        span = (inner_x1 - inner_x0) * 0.86
        start = inner_x0 + (inner_x1 - inner_x0 - span) / 2
        gw = span / glyphs
        for i in range(glyphs):
            gx = start + i * gw
            c.fill((96, 98, 132), c.rounded_rect_mask((gx + gw * 0.18, glyph_y0, gx + gw * 0.82, glyph_y0 + glyph_h),
                                                      gw * 0.2), 0.85)


def draw_zebra_stripes(c: Canvas, clip: Image.Image, opacity: float) -> None:
    """Dezente, organisch geschwungene Zebrastreifen im Hintergrund."""
    mask = c.new_mask()
    draw = ImageDraw.Draw(mask)
    # Breite, an den Enden spitz zulaufende Bänder quer zum Farbverlauf: (Versatz, Breite, Phase).
    bands = [(-420, 54, 0.0), (-270, 66, 1.3), (-120, 58, 2.6), (30, 70, 0.9), (180, 60, 2.1),
             (330, 66, 3.0), (480, 52, 1.6)]
    direction = (math.cos(math.radians(-34)), math.sin(math.radians(-34)))
    normal = (-direction[1], direction[0])
    for offset, width, phase in bands:
        left: List[Tuple[float, float]] = []
        right: List[Tuple[float, float]] = []
        samples = 120
        for i in range(samples + 1):
            t = i / samples
            along = lerp(-780, 780, t)
            wave = 46 * math.sin(t * math.pi * 1.8 + phase) + 10 * math.sin(t * math.pi * 4.2 + phase * 1.7)
            cx = 512 + direction[0] * along + normal[0] * (offset + wave)
            cy = 512 + direction[1] * along + normal[1] * (offset + wave)
            taper = math.sin(math.pi * t) ** 0.8
            half = 0.5 * width * (0.75 + 0.25 * math.sin(t * math.pi * 1.6 + phase)) * taper
            left.append((c.u(cx + normal[0] * half), c.u(cy + normal[1] * half)))
            right.append((c.u(cx - normal[0] * half), c.u(cy - normal[1] * half)))
        draw.polygon(left + right[::-1], fill=255)
    mask = c.blur(mask, 3.5)
    # Nach unten rechts ausblenden, damit der Petrol-Bereich ruhig bleibt.
    fade = c.linear_gradient([(0.0, (255, 255, 255)), (0.55, (200, 200, 200)), (1.0, (40, 40, 40))],
                             (180, 140), (860, 900)).convert("L")
    c.fill((10, 4, 46), multiply_masks(multiply_masks(mask, clip), fade), opacity)


def render_app_icon(pixels: int, detail: Detail) -> Image.Image:
    """App-Symbol: Squircle mit Verlauf, Zebramuster, Drucker und Etikett."""
    c = Canvas(pixels)
    squircle = c.polygon_mask(continuous_rounded_rect(ICON_TILE, ICON_CORNER))

    # Schlagschatten der Grundform (Apple-Raster: 824er-Form, Versatz nach unten).
    c.fill((0, 0, 0), c.blur(shifted(squircle, 0, c.u(12)), 14), 0.32)
    c.fill((0, 0, 0), c.blur(shifted(squircle, 0, c.u(4)), 3), 0.18)

    background = c.linear_gradient([(0.0, INDIGO_DEEP), (0.30, INDIGO), (0.62, VIOLET), (1.0, TEAL)],
                                   (250, 120), (800, 940))
    c.paint(background, squircle)

    # Licht von oben, sanfte Abdunklung unten.
    c.fill((255, 255, 255), multiply_masks(squircle, c.radial_mask((90, -330, 934, 520),
                                                                     lambda d: (1 - d) ** 1.6)), 0.26)
    c.fill((10, 4, 40), multiply_masks(squircle, c.vertical_ramp(640, 930, 0.0, 1.0)), 0.30)
    # Petrolfarbener Lichtschein rechts unten.
    c.add_light(TEAL, multiply_masks(squircle, c.radial_mask((560, 620, 1080, 1140), lambda d: (1 - d) ** 2)), 0.30)

    if detail.stripes:
        draw_zebra_stripes(c, squircle, 0.30 if detail.name == "voll" else 0.15)

    scene = APP_SCENE_SMALL if detail.name in ("klein", "winzig") else APP_SCENE
    draw_printer_and_label(c, scene, detail, cast_on=squircle)

    # Innere Lichtkante: oben hell, unten dunkel – gibt der Form Tiefe.
    inner = c.polygon_mask(continuous_rounded_rect((103, 103, 921, 921), ICON_CORNER - 3))
    rim = subtract_mask(squircle, inner)
    c.fill((255, 255, 255), multiply_masks(rim, c.vertical_ramp(100, 520, 1.0, 0.0)), 0.55)
    c.fill((0, 0, 0), multiply_masks(rim, c.vertical_ramp(560, 924, 0.0, 1.0)), 0.35)

    # Alles außerhalb der Grundform (außer dem Schatten) ist bereits transparent; Elemente, die über
    # den Rand ragen könnten, werden auf Form + Schatten begrenzt.
    return c.image


def render_printer_icon(pixels: int, detail: Detail) -> Image.Image:
    """Druckersymbol für die Warteschlange: freigestellter Drucker mit Etikett."""
    c = Canvas(pixels)
    scene = PRINTER_SCENE
    # Bodenschatten.
    c.fill((0, 0, 0), c.blur(c.ellipse_mask((130, 860, 894, 940)), 26), 0.45)
    draw_printer_and_label(c, scene, Detail(detail.name, False, detail.label_text, detail.barcode_bars,
                                            detail.printer_details, detail.glow))
    return c.image


def render(kind: str, size: int) -> Image.Image:
    """Rendert ein Symbol in Zielgröße `size` (mit Überabtastung und größenabhängigem Detail)."""
    detail = Detail.for_size(size)
    oversample = 2 if size >= 512 else max(2, min(16, 1024 // size))
    canvas_px = min(2048, size * oversample)
    painter = render_app_icon if kind == "app" else render_printer_icon
    image = painter(canvas_px, detail)
    if canvas_px != size:
        image = image.resize((size, size), Image.Resampling.LANCZOS)
    if size <= 64:
        image = sharpen(image, 0.6 if size <= 32 else 0.35)
    return image


def sharpen(image: Image.Image, amount: float) -> Image.Image:
    rgb = image.convert("RGB").filter(ImageFilter.UnsharpMask(radius=1.0, percent=int(amount * 100), threshold=1))
    out = rgb.convert("RGBA")
    out.putalpha(image.getchannel("A"))
    return out


# --------------------------------------------------------------------------------------------
# Installer-Hintergrund
# --------------------------------------------------------------------------------------------


def render_installer_background(dark: bool) -> Image.Image:
    """Hintergrund für den Installer (620 × 418 pt als @2x-PNG mit 144 dpi, unten links verankert).

    Ein dezent ausgeblendetes Druckersymbol mit violettem Lichtschein sitzt unten in der
    Seitenleiste des Installers, unterhalb der Schrittliste.
    """
    width, height = 1240, 836
    canvas = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    art_px = 360
    art = render_printer_icon(art_px * 2, Detail.for_size(512)).resize((art_px, art_px), Image.Resampling.LANCZOS)
    glow_px = 560
    glow = Canvas(glow_px).radial_mask((0, 0, 1024, 1024), lambda d: (1 - d) ** 2.4)
    glow_layer = Image.new("RGBA", (glow_px, glow_px), VIOLET + (255,))
    glow_layer.putalpha(scale_mask(glow, 0.34 if dark else 0.22))
    faded = art.copy()
    faded.putalpha(scale_mask(art.getchannel("A"), 0.55 if dark else 0.45))
    left, top = 24, height - art_px - 24
    canvas.alpha_composite(glow_layer, (left + (art_px - glow_px) // 2, top + (art_px - glow_px) // 2 + 30))
    canvas.alpha_composite(faded, (left, top))
    return canvas


# --------------------------------------------------------------------------------------------
# icns-Container
# --------------------------------------------------------------------------------------------

# Einträge mit PNG-Inhalt: Typ → Kantenlänge in Pixeln.
ICNS_PNG_TYPES: List[Tuple[bytes, int]] = [
    (b"ic11", 32),    # 16 pt @2x
    (b"ic12", 64),    # 32 pt @2x
    (b"ic07", 128),
    (b"ic13", 256),   # 128 pt @2x
    (b"ic08", 256),
    (b"ic14", 512),   # 256 pt @2x
    (b"ic09", 512),
    (b"ic10", 1024),  # 512 pt @2x
]
# Einträge mit ARGB-Inhalt (RLE) für 16/32 pt @1x.
ICNS_ARGB_TYPES: List[Tuple[bytes, int]] = [(b"ic04", 16), (b"ic05", 32)]
# Klassische Einträge (RGB-RLE + 8-Bit-Maske) für ältere Leser.
ICNS_LEGACY_TYPES: List[Tuple[bytes, bytes, int]] = [(b"is32", b"s8mk", 16), (b"il32", b"l8mk", 32)]
ICNS_SIZES = sorted({size for _, size in ICNS_PNG_TYPES} | {size for _, size in ICNS_ARGB_TYPES})


def packbits_icns(channel: bytes) -> bytes:
    """RLE der icns-Bitmaps: 0x00–0x7F = (n+1) Literale, 0x80–0xFF = (n−0x80+3) Wiederholungen."""
    out = bytearray()
    i = 0
    n = len(channel)
    literal = bytearray()

    def flush() -> None:
        while literal:
            chunk = literal[:128]
            out.append(len(chunk) - 1)
            out.extend(chunk)
            del literal[:128]

    while i < n:
        run = 1
        while i + run < n and channel[i + run] == channel[i] and run < 130:
            run += 1
        if run >= 3:
            flush()
            out.append(0x80 + run - 3)
            out.append(channel[i])
            i += run
        else:
            literal.extend(channel[i:i + run])
            i += run
            if len(literal) >= 128:
                flush()
    flush()
    return bytes(out)


def unpackbits_icns(data: bytes, expected: int) -> Tuple[bytes, int]:
    """Gegenstück zu packbits_icns; liefert (Bytes, verbrauchte Länge)."""
    out = bytearray()
    i = 0
    while len(out) < expected:
        if i >= len(data):
            raise ValueError("RLE-Daten zu kurz")
        code = data[i]
        i += 1
        if code < 0x80:
            count = code + 1
            out.extend(data[i:i + count])
            i += count
        else:
            count = code - 0x80 + 3
            out.extend(bytes([data[i]]) * count)
            i += 1
    if len(out) != expected:
        raise ValueError("RLE-Daten passen nicht zur Bildgröße")
    return bytes(out), i


def png_bytes(image: Image.Image) -> bytes:
    buffer = io.BytesIO()
    image.save(buffer, format="PNG", optimize=True)
    return buffer.getvalue()


def argb_entry(image: Image.Image) -> bytes:
    rgba = image.convert("RGBA")
    r, g, b, a = (channel.tobytes() for channel in rgba.split())
    return b"ARGB" + b"".join(packbits_icns(ch) for ch in (a, r, g, b))


def legacy_entries(image: Image.Image) -> Tuple[bytes, bytes]:
    rgba = image.convert("RGBA")
    r, g, b, a = (channel.tobytes() for channel in rgba.split())
    return b"".join(packbits_icns(ch) for ch in (r, g, b)), a


def build_icns(images: Dict[int, Image.Image]) -> bytes:
    """Baut eine icns-Datei aus Bildern je Kantenlänge (16, 32, 64, 128, 256, 512, 1024)."""
    entries: List[Tuple[bytes, bytes]] = []
    for ostype, size in ICNS_ARGB_TYPES:
        entries.append((ostype, argb_entry(images[size])))
    for rgb_type, mask_type, size in ICNS_LEGACY_TYPES:
        rgb, mask = legacy_entries(images[size])
        entries.append((rgb_type, rgb))
        entries.append((mask_type, mask))
    for ostype, size in ICNS_PNG_TYPES:
        entries.append((ostype, png_bytes(images[size])))
    toc = b"".join(ostype + struct.pack(">I", len(data) + 8) for ostype, data in entries)
    body = b"TOC " + struct.pack(">I", len(toc) + 8) + toc
    body += b"".join(ostype + struct.pack(">I", len(data) + 8) + data for ostype, data in entries)
    return b"icns" + struct.pack(">I", len(body) + 8) + body


def read_icns(data: bytes) -> Dict[bytes, bytes]:
    """Liest die Einträge einer icns-Datei (prüft Längen)."""
    if data[:4] != b"icns":
        raise ValueError("keine icns-Datei (Magic fehlt)")
    total = struct.unpack(">I", data[4:8])[0]
    if total != len(data):
        raise ValueError(f"Gesamtlänge {total} ≠ Dateigröße {len(data)}")
    entries: Dict[bytes, bytes] = {}
    pos = 8
    while pos < len(data):
        if pos + 8 > len(data):
            raise ValueError("abgeschnittener Eintragskopf")
        ostype = data[pos:pos + 4]
        length = struct.unpack(">I", data[pos + 4:pos + 8])[0]
        if length < 8 or pos + length > len(data):
            raise ValueError(f"ungültige Länge für {ostype!r}")
        if ostype in entries:
            raise ValueError(f"Eintrag {ostype!r} doppelt")
        entries[ostype] = data[pos + 8:pos + length]
        pos += length
    return entries


def decode_icns_entry(ostype: bytes, payload: bytes, entries: Dict[bytes, bytes]) -> Image.Image:
    """Dekodiert einen Eintrag zu einem RGBA-Bild (für Prüfungen und Tests)."""
    for png_type, _ in ICNS_PNG_TYPES:
        if ostype == png_type:
            image = Image.open(io.BytesIO(payload))
            image.load()
            return image.convert("RGBA")
    for argb_type, size in ICNS_ARGB_TYPES:
        if ostype == argb_type:
            if payload[:4] != b"ARGB":
                raise ValueError(f"{ostype!r}: ARGB-Kennung fehlt")
            data = payload[4:]
            channels = []
            for _ in range(4):
                channel, used = unpackbits_icns(data, size * size)
                channels.append(Image.frombytes("L", (size, size), channel))
                data = data[used:]
            if data:
                raise ValueError(f"{ostype!r}: überzählige Daten")
            a, r, g, b = channels
            return Image.merge("RGBA", (r, g, b, a))
    for rgb_type, mask_type, size in ICNS_LEGACY_TYPES:
        if ostype == rgb_type:
            data = payload
            channels = []
            for _ in range(3):
                channel, used = unpackbits_icns(data, size * size)
                channels.append(Image.frombytes("L", (size, size), channel))
                data = data[used:]
            mask = entries.get(mask_type)
            if mask is None or len(mask) != size * size:
                raise ValueError(f"{ostype!r}: Maske {mask_type!r} fehlt oder hat falsche Größe")
            return Image.merge("RGBA", (*channels, Image.frombytes("L", (size, size), mask)))
    raise ValueError(f"unbekannter Eintrag {ostype!r}")


def expected_size(ostype: bytes) -> Optional[int]:
    for kind, size in ICNS_PNG_TYPES + ICNS_ARGB_TYPES:
        if kind == ostype:
            return size
    for rgb_type, _, size in ICNS_LEGACY_TYPES:
        if rgb_type == ostype:
            return size
    return None


def verify_icns(path: Path) -> List[str]:
    """Prüft eine icns-Datei; liefert eine Liste von Problemen (leer = in Ordnung)."""
    problems: List[str] = []
    try:
        entries = read_icns(path.read_bytes())
    except (OSError, ValueError) as error:
        return [f"{path}: {error}"]
    required = [t for t, _ in ICNS_PNG_TYPES] + [t for t, _ in ICNS_ARGB_TYPES]
    for ostype in required:
        if ostype not in entries:
            problems.append(f"{path}: Eintrag {ostype.decode()} fehlt")
    for ostype, payload in entries.items():
        if ostype == b"TOC " or ostype.endswith(b"8mk"):
            continue
        size = expected_size(ostype)
        if size is None:
            continue
        try:
            image = decode_icns_entry(ostype, payload, entries)
        except (OSError, ValueError) as error:
            problems.append(f"{path}: {ostype.decode()}: {error}")
            continue
        if image.size != (size, size):
            problems.append(f"{path}: {ostype.decode()} hat {image.size}, erwartet {size}×{size}")
        elif image.getchannel("A").getextrema()[1] == 0:
            problems.append(f"{path}: {ostype.decode()} ist vollständig transparent")
    if b"TOC " in entries:
        toc = entries[b"TOC "]
        listed = [toc[i:i + 4] for i in range(0, len(toc), 8)]
        if sorted(listed) != sorted(k for k in entries if k != b"TOC "):
            problems.append(f"{path}: Inhaltsverzeichnis (TOC) passt nicht zu den Einträgen")
    return problems


# --------------------------------------------------------------------------------------------
# Vorschau-Tafel
# --------------------------------------------------------------------------------------------


def contact_sheet(app: Dict[int, Image.Image], printer: Dict[int, Image.Image]) -> Image.Image:
    """Übersicht aller Größen auf hellem und dunklem Grund."""
    sizes = [16, 32, 64, 128, 256]
    width = 40 + sum(sizes) + 40 * len(sizes) + 300
    rows = [("app", (246, 246, 250)), ("app", (30, 30, 36)), ("printer", (246, 246, 250)), ("printer", (30, 30, 36))]
    row_height = 300
    sheet = Image.new("RGB", (width, row_height * len(rows)), (255, 255, 255))
    for row_index, (kind, color) in enumerate(rows):
        top = row_index * row_height
        sheet.paste(color, (0, top, width, top + row_height))
        x = 30
        source = app if kind == "app" else printer
        for size in sizes:
            icon = source[size]
            y = top + (row_height - size) // 2
            sheet.paste(icon, (x, y), icon)
            x += size + 40
        big = source[512].resize((260, 260), Image.Resampling.LANCZOS)
        sheet.paste(big, (x, top + 20), big)
    return sheet


# --------------------------------------------------------------------------------------------
# Hauptprogramm
# --------------------------------------------------------------------------------------------


def display(path: Path) -> str:
    """Pfad relativ zum Repository (falls darin), sonst absolut."""
    try:
        return str(path.resolve().relative_to(REPO_ROOT))
    except ValueError:
        return str(path)


def generate(output: Path, quiet: bool = False) -> None:
    resources = output / "Resources"
    preview = resources / "icon-preview"
    pkg_resources = output / "pkg" / "Resources"
    for directory in (resources, preview, pkg_resources):
        directory.mkdir(parents=True, exist_ok=True)

    def log(message: str) -> None:
        if not quiet:
            print(message)

    all_sizes = sorted(set(ICNS_SIZES) | {16, 32, 64, 128, 256, 512, 1024})
    rendered: Dict[str, Dict[int, Image.Image]] = {}
    for kind, name in (("app", "AppIcon"), ("printer", "LabelWerk")):
        images = {size: render(kind, size) for size in all_sizes}
        rendered[kind] = images
        icns_path = resources / f"{name}.icns"
        icns_path.write_bytes(build_icns(images))
        problems = verify_icns(icns_path)
        if problems:
            raise SystemExit("\n".join(problems))
        log(f"geschrieben: {display(icns_path)} ({icns_path.stat().st_size // 1024} KB)")
        for size in (16, 32, 64, 128, 256, 512, 1024):
            path = preview / f"{name}-{size}.png"
            images[size].save(path, format="PNG", optimize=True)
        log(f"Vorschauen: {display(preview)}/{name}-*.png")

    contact_sheet(rendered["app"], rendered["printer"]).save(preview / "overview.png", format="PNG", optimize=True)
    log(f"Übersicht: {display(preview / 'overview.png')}")

    for dark, filename in ((False, "background.png"), (True, "background-dark.png")):
        image = render_installer_background(dark)
        image.save(pkg_resources / filename, format="PNG", optimize=True, dpi=(144, 144))
        log(f"Installer-Hintergrund: {display(pkg_resources / filename)}")


def check(output: Path) -> int:
    problems: List[str] = []
    for name in ("AppIcon", "LabelWerk"):
        path = output / "Resources" / f"{name}.icns"
        if not path.exists():
            problems.append(f"{path}: fehlt – Scripts/make_icons.py ausführen")
            continue
        problems.extend(verify_icns(path))
    for problem in problems:
        print(f"Fehler: {problem}", file=sys.stderr)
    if not problems:
        print("Symbole: in Ordnung.")
    return 1 if problems else 0


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Erzeugt App-, Drucker- und Installer-Grafiken von LabelWerk.")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT,
                        help="Zielverzeichnis (Standard: Installer/ im Repository)")
    parser.add_argument("--check", action="store_true", help="vorhandene icns-Dateien nur prüfen")
    parser.add_argument("-q", "--quiet", action="store_true", help="keine Fortschrittsmeldungen")
    args = parser.parse_args(argv)
    if args.check:
        return check(args.output)
    generate(args.output, quiet=args.quiet)
    return 0


if __name__ == "__main__":
    sys.exit(main())
