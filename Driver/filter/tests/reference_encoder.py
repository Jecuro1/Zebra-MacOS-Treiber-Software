"""
reference_encoder.py – unabhängige Referenzimplementierung von ARCHITECTURE.md §4.1 (Rasterung,
Luminanz) und §8 (Druckauftragsformat) sowie der Optionsauflösung aus §9.

Reines Python (nur Standardbibliothek: zlib, base64). Dient den End-to-End-Tests als Orakel:
Der C-Filter ``rastertolabelwerk`` muss für dieselben Luminanzdaten byte-genau dieselbe Ausgabe
erzeugen. Die Implementierung ist bewusst anders strukturiert als der C-Code (ganze Bilder statt
Zeilen-Streaming, Fehlerfelder über das ganze Bild, Bitketten statt Bitmasken), damit
gemeinsame Denkfehler unwahrscheinlich sind.

Enthält auch die Optionen der Windows-Druckeinstellungen (Drehung 90/180/270°, Markenversatz,
Seitenkerben, Linerless, Bei letztem Element stoppen, Pause, eigene Steuerzeichen, RTC ``^ST``,
``~JA``, Etikettenbefehle, ``^MF``). Die Uhr für ``^ST`` ist ein Parameter (``now``,
``time_step``) – wie ``LW_FIXED_TIME``/``LW_TIME_STEP_SECONDS`` beim Filter; die Ortszeit folgt
der Umgebungsvariablen ``TZ`` des Python-Prozesses.

Als Modul importierbar::

    import reference_encoder as ref
    settings = ref.Settings(language="ZPL", dither="Atkinson")
    job = ref.encode_job_from_luminance([(w, h, lum)], settings, copies=2)
"""

from __future__ import annotations

import base64
import sys
import time
import zlib
from dataclasses import dataclass, field, replace
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

# --------------------------------------------------------------------------------------------
# §4.1 Rasterung
# --------------------------------------------------------------------------------------------

BAYER = [
    [0, 32, 8, 40, 2, 34, 10, 42],
    [48, 16, 56, 24, 50, 18, 58, 26],
    [12, 44, 4, 36, 14, 46, 6, 38],
    [60, 28, 52, 20, 62, 30, 54, 22],
    [3, 35, 11, 43, 1, 33, 9, 41],
    [51, 19, 59, 27, 49, 17, 57, 25],
    [15, 47, 7, 39, 13, 45, 5, 37],
    [63, 31, 55, 23, 61, 29, 53, 21],
]

HALFTONE = [
    [24, 10, 12, 26, 35, 47, 49, 37],
    [8, 0, 2, 14, 45, 59, 61, 51],
    [22, 6, 4, 16, 43, 57, 63, 53],
    [30, 20, 18, 28, 33, 41, 55, 39],
    [34, 46, 48, 36, 25, 11, 13, 27],
    [44, 58, 60, 50, 9, 1, 3, 15],
    [42, 56, 62, 52, 23, 7, 5, 17],
    [32, 40, 54, 38, 31, 21, 19, 29],
]

# Fehlerdiffusion: (dx, dy, Gewicht), Divisor
DIFFUSION = {
    "FloydSteinberg": ([(1, 0, 7), (-1, 1, 3), (0, 1, 5), (1, 1, 1)], 16),
    "Atkinson": ([(1, 0, 1), (2, 0, 1), (-1, 1, 1), (0, 1, 1), (1, 1, 1), (0, 2, 1)], 8),
    "Stucki": ([(1, 0, 8), (2, 0, 4),
                (-2, 1, 2), (-1, 1, 4), (0, 1, 8), (1, 1, 4), (2, 1, 2),
                (-2, 2, 1), (-1, 2, 2), (0, 2, 4), (1, 2, 2), (2, 2, 1)], 42),
}

DITHERS = ["Threshold", "Ordered", "Halftone", "FloydSteinberg", "Atkinson", "Stucki"]


def tdiv(a: int, b: int) -> int:
    """Ganzzahldivision mit Abschneiden Richtung 0 (wie C/Swift ``/``)."""
    q = abs(a) // abs(b)
    return q if (a >= 0) == (b > 0) else -q


class Bitmap:
    """1-Bit-Bitmap: MSB zuerst, 1 = schwarz, Füllbits 0."""

    __slots__ = ("width", "height", "data")

    def __init__(self, width: int, height: int, data: Optional[bytearray] = None):
        self.width = width
        self.height = height
        bpr = (width + 7) // 8
        self.data = bytearray(bpr * height) if data is None else bytearray(data)
        assert len(self.data) == bpr * height

    @property
    def bpr(self) -> int:
        return (self.width + 7) // 8

    def row(self, y: int) -> bytes:
        return bytes(self.data[y * self.bpr:(y + 1) * self.bpr])

    def get(self, x: int, y: int) -> bool:
        return bool(self.data[y * self.bpr + x // 8] & (0x80 >> (x % 8)))

    def copy(self) -> "Bitmap":
        return Bitmap(self.width, self.height, bytearray(self.data))

    # --- Bitketten-Helfer ---------------------------------------------------------------
    def row_bits(self, y: int) -> str:
        """Zeile als '0'/'1'-Kette der Länge width."""
        if self.bpr == 0:
            return ""
        value = int.from_bytes(self.row(y), "big")
        return format(value, "0%db" % (self.bpr * 8))[: self.width]

    @staticmethod
    def pack_bits(bits: str, width: int) -> bytes:
        bpr = (width + 7) // 8
        if bpr == 0:
            return b""
        padded = bits + "0" * (bpr * 8 - len(bits))
        return int(padded, 2).to_bytes(bpr, "big")

    @classmethod
    def from_rows(cls, width: int, rows: Iterable[str]) -> "Bitmap":
        data = bytearray()
        height = 0
        for bits in rows:
            data += cls.pack_bits(bits, width)
            height += 1
        return cls(width, height, data)


def clamp_threshold(t: int) -> int:
    return max(1, min(254, t))


def dither(lum: bytes, width: int, height: int, algorithm: str, threshold: int = 128) -> Bitmap:
    """Rastert ein Luminanzbild (0 = schwarz) nach §4.1."""
    t = clamp_threshold(threshold)
    if width == 0 or height == 0:
        return Bitmap(width, height)
    if algorithm == "Threshold":
        table = bytes(ord("1") if v < t else ord("0") for v in range(256))
        rows = (lum[y * width:(y + 1) * width].translate(table).decode("ascii") for y in range(height))
        return Bitmap.from_rows(width, rows)
    if algorithm in ("Ordered", "Halftone"):
        matrix = BAYER if algorithm == "Ordered" else HALFTONE
        shift = t - 128
        rows = []
        for y in range(height):
            mrow = [m * 4 + 2 + shift for m in matrix[y % 8]]
            line = lum[y * width:(y + 1) * width]
            rows.append("".join("1" if line[x] < mrow[x % 8] else "0" for x in range(width)))
        return Bitmap.from_rows(width, rows)
    if algorithm in DIFFUSION:
        weights, divisor = DIFFUSION[algorithm]
        err = [0] * (width * height)        # Fehlerfeld über das ganze Bild
        rows = []
        for y in range(height):
            bits = []
            base = y * width
            for x in range(width):
                v = lum[base + x] + err[base + x]
                out = 0 if v < t else 255
                bits.append("1" if out == 0 else "0")
                e = v - out
                if e == 0:
                    continue
                for dx, dy, w in weights:
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < width and ny < height:
                        err[ny * width + nx] += tdiv(e * w, divisor)
            rows.append("".join(bits))
        return Bitmap.from_rows(width, rows)
    raise ValueError("unbekanntes Rasterverfahren: %r" % algorithm)


# --------------------------------------------------------------------------------------------
# §4.1 Luminanz aus Rasterdaten
# --------------------------------------------------------------------------------------------

CS_W, CS_RGB, CS_RGBA, CS_K, CS_CMY, CS_YMC, CS_CMYK, CS_YMCK, CS_KCMY = 0, 1, 2, 3, 4, 5, 6, 7, 8
CS_SW, CS_SRGB, CS_ADOBERGB = 18, 19, 20
ORDER_CHUNKY, ORDER_BANDED, ORDER_PLANAR = 0, 1, 2

CHANNELS = {CS_W: 1, CS_SW: 1, CS_K: 1, CS_RGB: 3, CS_SRGB: 3, CS_ADOBERGB: 3, CS_RGBA: 4,
            CS_CMY: 3, CS_YMC: 3, CS_CMYK: 4, CS_YMCK: 4, CS_KCMY: 4}


def is_supported_format(info: dict) -> bool:
    cs, order = info["cs"], info["order"]
    if cs not in CHANNELS or info["bpc"] not in (1, 2, 4, 8, 16):
        return False
    return not (order == ORDER_PLANAR and CHANNELS[cs] > 1)


def _sample(line: bytes, bit: int, bpc: int) -> int:
    """Kanalwert an Bitposition, skaliert auf 0…255 (16 Bit: höherwertiges Byte des Werts)."""
    if bpc == 16:
        value = int.from_bytes(line[bit // 8: bit // 8 + 2], sys.byteorder)
        return value >> 8
    if bpc == 8:
        return line[bit // 8]
    byte = line[bit // 8]
    shift = 8 - bpc - (bit % 8)
    value = (byte >> shift) & ((1 << bpc) - 1)
    return value * 255 // ((1 << bpc) - 1)


def luminance_line(line: bytes, info: dict) -> bytes:
    width, bpc, cs, order = info["w"], info["bpc"], info["cs"], info["order"]
    channels = CHANNELS[cs]
    out = bytearray(width)
    banded = order == ORDER_BANDED and channels > 1
    band = info["bpl"] // channels if banded else 0
    bpp = info["bpp"] or bpc
    slot_offset = bpp // bpc - channels
    for x in range(width):
        if banded:
            v = [_sample(line[c * band:(c + 1) * band], x * bpc, bpc) for c in range(channels)]
        else:
            v = [_sample(line, x * bpp + (slot_offset + c) * bpc, bpc) for c in range(channels)]
        if cs in (CS_W, CS_SW):
            lum = v[0]
        elif cs == CS_K:
            lum = 255 - v[0]
        elif cs in (CS_RGB, CS_SRGB, CS_ADOBERGB):
            lum = (299 * v[0] + 587 * v[1] + 114 * v[2]) // 1000
        elif cs == CS_RGBA:
            base = (299 * v[0] + 587 * v[1] + 114 * v[2]) // 1000
            lum = (base * v[3] + 255 * (255 - v[3])) // 255
        elif cs in (CS_CMY, CS_YMC):
            lum = 255 - min(255, (v[0] + v[1] + v[2]) // 3)
        elif cs in (CS_CMYK, CS_YMCK):
            lum = 255 - min(255, v[3] + (v[0] + v[1] + v[2]) // 3)
        elif cs == CS_KCMY:
            lum = 255 - min(255, v[0] + (v[1] + v[2] + v[3]) // 3)
        else:
            raise ValueError("Farbraum %d nicht unterstützt" % cs)
        out[x] = lum
    return bytes(out)


def luminance_from_samples(raw: bytes, info: dict) -> bytes:
    """Wandelt die Rohdaten einer Seite (Zeilen à info['bpl'] Bytes) in w·h Luminanzwerte."""
    width, height, bpl = info["w"], info["h"], info["bpl"]
    bpc, cs, order = info["bpc"], info["cs"], info["order"]
    bpp = info["bpp"] or bpc
    if not is_supported_format(info):
        raise ValueError("Format nicht unterstützt")
    # Schnelle Wege (8 Bit Grau / Schwarz, 1 Bit) – Ergebnis identisch zur allgemeinen Formel.
    if CHANNELS[cs] == 1 and bpp == bpc and bpc == 8:
        rows = [raw[y * bpl:y * bpl + width] for y in range(height)]
        data = b"".join(rows)
        if cs == CS_K:
            data = data.translate(bytes(255 - v for v in range(256)))
        return data
    if CHANNELS[cs] == 1 and bpp == bpc and bpc == 1:
        on = 255 if cs in (CS_W, CS_SW) else 0
        table = {"1": on, "0": 255 - on}
        out = bytearray()
        nbytes = (width + 7) // 8
        for y in range(height):
            chunk = raw[y * bpl:y * bpl + nbytes]
            bits = format(int.from_bytes(chunk, "big"), "0%db" % (nbytes * 8))[:width]
            out += bytes(table[b] for b in bits)
        return bytes(out)
    return b"".join(luminance_line(raw[y * bpl:(y + 1) * bpl], info) for y in range(height))


# --------------------------------------------------------------------------------------------
# Bitmap-Vorverarbeitung (§8)
# --------------------------------------------------------------------------------------------

def crop(bm: Bitmap, max_width: int) -> Bitmap:
    if max_width <= 0 or bm.width <= max_width:
        return bm
    return Bitmap.from_rows(max_width, (bm.row_bits(y)[:max_width] for y in range(bm.height)))


def invert(bm: Bitmap) -> Bitmap:
    return Bitmap.from_rows(bm.width, (bm.row_bits(y).translate(str.maketrans("01", "10"))
                                       for y in range(bm.height)))


def is_blank(bm: Bitmap) -> bool:
    return not any(bm.data)


def mirror(bm: Bitmap) -> Bitmap:
    return Bitmap.from_rows(bm.width, (bm.row_bits(y)[::-1] for y in range(bm.height)))


def rotate180(bm: Bitmap) -> Bitmap:
    return Bitmap.from_rows(bm.width, (bm.row_bits(y)[::-1] for y in reversed(range(bm.height))))


def rotate_quarter(bm: Bitmap, degrees: int) -> Bitmap:
    """Dreht im Uhrzeigersinn: 90° (x, y) → (h − 1 − y, x), 270° (x, y) → (y, w − 1 − x).

    Neue Zeile ``ny`` = Spalte ``ny`` von unten nach oben gelesen (90°) bzw. Spalte
    ``w − 1 − ny`` von oben nach unten (270°)."""
    rows = [bm.row_bits(y) for y in range(bm.height)]
    w, h = bm.width, bm.height
    if degrees == 90:
        new_rows = ("".join(rows[h - 1 - nx][ny] for nx in range(h)) for ny in range(w))
    elif degrees == 270:
        new_rows = ("".join(rows[nx][w - 1 - ny] for nx in range(h)) for ny in range(w))
    else:
        return bm
    return Bitmap.from_rows(h, new_rows) if w > 0 else Bitmap(h, 0)


def last_black_row(bm: Bitmap) -> int:
    """Letzte Zeile mit einem schwarzen Punkt, −1 bei leerer Bitmap."""
    for y in reversed(range(bm.height)):
        if any(bm.row(y)):
            return y
    return -1


def with_height(bm: Bitmap, height: int) -> Bitmap:
    """Kürzt bzw. verlängert (weiße Zeilen) auf ``height`` Zeilen."""
    rows = [bm.row_bits(y) for y in range(min(height, bm.height))]
    rows += ["0" * bm.width] * (height - len(rows))
    return Bitmap.from_rows(bm.width, rows)


# --------------------------------------------------------------------------------------------
# Kodierungen
# --------------------------------------------------------------------------------------------

def hex_encode(data: bytes) -> bytes:
    return data.hex().upper().encode("ascii")


def _acs_run(value: str, count: int) -> str:
    parts = []
    while count > 0:
        n = min(count, 419)
        if n <= 2:
            parts.append(value * n)
        else:
            twenties, ones = divmod(n, 20)
            prefix = ""
            if twenties:
                prefix += chr(ord("g") + twenties - 1)
            if ones:
                prefix += chr(ord("G") + ones - 1)
            parts.append(prefix + value)
        count -= n
    return "".join(parts)


def acs_encode(bm: Bitmap) -> bytes:
    """Zebra ACS mit denselben Kodierentscheidungen wie LabelWerkImaging.ACS.encode."""
    out = []
    previous = None
    for y in range(bm.height):
        row = bm.row(y)
        if previous is not None and row == previous:
            out.append(":")
            continue
        previous = row
        nibbles = row.hex().upper()
        last = nibbles[-1]
        stripped = nibbles.rstrip(last)
        tail = len(nibbles) - len(stripped)
        terminator = ""
        body = nibbles
        if last in "0F" and tail >= 2:
            body = stripped
            terminator = "," if last == "0" else "!"
        i = 0
        while i < len(body):
            j = i
            while j < len(body) and body[j] == body[i]:
                j += 1
            out.append(_acs_run(body[i], j - i))
            i = j
        out.append(terminator)
    return "".join(out).encode("ascii")


def acs_decode(text: bytes, bytes_per_row: int, total: int) -> bytes:
    """Dekodiert ACS/Hex in genau ``total`` Bytes (zur semantischen Prüfung der Filterausgabe)."""
    row_n = bytes_per_row * 2
    nibbles: List[int] = []
    pending = 0
    for ch in text.decode("ascii"):
        if len(nibbles) >= total * 2:
            break
        if ch in "0123456789ABCDEFabcdef":
            nibbles.extend([int(ch, 16)] * (pending or 1))
            pending = 0
        elif "G" <= ch <= "Y":
            pending += ord(ch) - ord("G") + 1
        elif "g" <= ch <= "z":
            pending += (ord(ch) - ord("g") + 1) * 20
        elif ch in ",!":
            pending = 0
            end = (len(nibbles) // row_n + 1) * row_n
            nibbles.extend([0 if ch == "," else 15] * (end - len(nibbles)))
        elif ch == ":":
            pending = 0
            row = len(nibbles) // row_n
            end = (row + 1) * row_n
            while len(nibbles) < end:
                nibbles.append(0 if row == 0 else nibbles[len(nibbles) - row_n])
        elif ch in " \r\n\t":
            continue
        else:
            raise ValueError("unzulässiges ACS-Zeichen %r" % ch)
    nibbles = nibbles[: total * 2] + [0] * max(0, total * 2 - len(nibbles))
    return bytes(nibbles[i] << 4 | nibbles[i + 1] for i in range(0, total * 2, 2))


def crc16_xmodem(data: bytes) -> int:
    crc = 0
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def z64_encode(data: bytes) -> bytes:
    b64 = base64.b64encode(zlib.compress(data, -1))   # -1 = Z_DEFAULT_COMPRESSION
    return b":Z64:" + b64 + b":" + ("%04X" % crc16_xmodem(b64)).encode("ascii")


def z64_decode(text: bytes) -> bytes:
    assert text.startswith(b":Z64:")
    body, _, crc = text[5:].rpartition(b":")
    if int(crc, 16) != crc16_xmodem(body):
        raise ValueError("Z64-Prüfsumme falsch")
    return zlib.decompress(base64.b64decode(body))


def base64url_encode(text: str) -> str:
    """Kodierung der Rohbefehle wie CUPSCommandEncoding.encode (ohne Padding)."""
    return base64.urlsafe_b64encode(text.encode("utf-8")).decode("ascii").rstrip("=")


# --------------------------------------------------------------------------------------------
# §9 Optionen
# --------------------------------------------------------------------------------------------

@dataclass
class Settings:
    language: str = "ZPL"
    darkness: Optional[int] = None
    speed: Optional[int] = None
    media_type: Optional[str] = None       # DirectThermal / ThermalTransfer
    tracking: Optional[str] = None         # Gap / BlackMark / Continuous / Auto
    print_mode: Optional[str] = None       # TearOff …
    label_top: Optional[int] = None
    label_left: Optional[int] = None
    tear_off: Optional[int] = None
    backfeed: Optional[str] = None         # After / Before / Normal / Off
    mirror: bool = False
    negative: bool = False
    rotate180: bool = False
    dither: str = "Threshold"
    threshold: int = 128
    compression: str = "Z64"
    cut_every: int = 0
    calibrate: bool = False
    save_settings: bool = False
    skip_blank: bool = False
    start_commands: bytes = b""
    end_commands: bytes = b""
    # --- Erweiterungen (Windows-Druckeinstellungen) ---
    rotation: int = 0                      # 0 / 90 / 180 / 270 (0 + rotate180 = 180)
    mark_offset: Optional[int] = None      # ^MNM,n (nur BlackMark), −80…283
    stop_at_last: bool = False             # nur Continuous
    stop_offset: int = 0                   # 0…32000 Punkte
    pause_every: int = 0                   # ^PQn,p,0,N (Vorrang vor cut_every)
    control_chars: Optional[Tuple[int, int, int]] = None   # None = Standard, sonst (^, ~, ,)-Ersatz
    rtc: Optional[str] = None              # JobStart / EveryLabel / EveryMinute
    cancel_before: bool = False            # ~JA
    cancel_delay: int = 1000               # ms, nur der Filter wartet
    label_start_commands: bytes = b""
    label_end_commands: bytes = b""
    power_up_action: Optional[str] = None  # Feed / Calibrate / Length / NoMotion / ShortCal
    head_close_action: Optional[str] = None

    def clamped(self) -> "Settings":
        def c(v, lo, hi):
            return None if v is None else max(lo, min(hi, v))

        chars = self.control_chars
        if chars is not None:
            chars = tuple(v if CONTROL_CHAR_MIN <= v <= CONTROL_CHAR_MAX else std
                          for v, std in zip(chars, STANDARD_CONTROL_CHARS))
        return replace(self,
                       darkness=c(self.darkness, 0, 30), speed=c(self.speed, 1, 14),
                       label_top=c(self.label_top, -120, 120), label_left=c(self.label_left, -9999, 9999),
                       tear_off=c(self.tear_off, -120, 120), threshold=c(self.threshold, 1, 254),
                       cut_every=c(self.cut_every, 0, 9999),
                       rotation=self.rotation if self.rotation in (0, 90, 180, 270) else 0,
                       mark_offset=c(self.mark_offset, -80, 283), stop_offset=c(self.stop_offset, 0, 32000),
                       pause_every=c(self.pause_every, 0, 9999), cancel_delay=c(self.cancel_delay, 0, 10000),
                       control_chars=chars)

    @property
    def effective_rotation(self) -> int:
        if self.rotation in (90, 180, 270):
            return self.rotation
        return 180 if self.rotate180 else 0


#: Standard-Steuerzeichen (^ ~ ,) und gültiger Bereich eigener Zeichen.
STANDARD_CONTROL_CHARS = (0x5E, 0x7E, 0x2C)
CONTROL_CHAR_MIN, CONTROL_CHAR_MAX = 33, 126


ENUMS = {
    "lwLanguage": {"zpl": "ZPL", "zpl2": "ZPL", "zplii": "ZPL", "epl": "EPL", "epl2": "EPL", "cpcl": "CPCL"},
    "lwMediaType": {"directthermal": "DirectThermal", "thermaltransfer": "ThermalTransfer"},
    "lwMediaTracking": {"gap": "Gap", "blackmark": "BlackMark", "continuous": "Continuous", "auto": "Auto",
                        "notch": "Notch"},
    "lwPrintMode": {k.lower(): k for k in ("TearOff", "PeelOff", "Cutter", "DelayedCut", "Rewind",
                                           "Applicator", "Kiosk", "LinerlessPeel", "LinerlessCut",
                                           "LinerlessDelayedCut", "LinerlessRewind", "LinerlessTear")},
    "lwBackfeed": {k.lower(): k for k in ("After", "Before", "Normal", "Off")},
    "lwDither": {k.lower(): k for k in DITHERS},
    "lwCompression": {"z64": "Z64", "acs": "ACS", "hex": "Hex"},
    "lwRotation": {"0": 0, "90": 90, "180": 180, "270": 270},
    "lwRTC": {k.lower(): k for k in ("JobStart", "EveryLabel", "EveryMinute")},
    "lwPowerUpAction": {k.lower(): k for k in ("Feed", "Calibrate", "Length", "NoMotion", "ShortCal")},
    "lwHeadCloseAction": {k.lower(): k for k in ("Feed", "Calibrate", "Length", "NoMotion", "ShortCal")},
    "lwControlChars": {"standard": False, "printer": True},
}

INVALID = object()
DEFAULT = object()


def _parse_int(text: str):
    if text.lower() == "default":
        return DEFAULT
    t = text[7:] if text.lower().startswith("custom.") else text
    sign = 1
    if t[:1] in "+-" and t[:1] != "":
        sign = -1 if t[0] == "-" else 1
        t = t[1:]
    if not t or not all("0" <= ch <= "9" for ch in t):
        return INVALID
    value = sign * int(t)
    if value >= 2 ** 63 or value < -(2 ** 63):
        return INVALID
    return max(-(2 ** 31 - 1), min(2 ** 31 - 1, value))


def _parse_bool(text: str):
    low = text.lower()
    if low == "default":
        return DEFAULT
    if low in ("true", "yes", "on", "1"):
        return True
    if low in ("false", "no", "off", "0"):
        return False
    return INVALID


def _parse_enum(name: str, text: str):
    if text.lower() == "default":
        return DEFAULT
    return ENUMS[name].get(text.lower(), INVALID)


def _parse_char(text: str):
    """Dezimaler ASCII-Code 33…126 (lwFormatPrefix/lwControlPrefix/lwDelimiter)."""
    value = _parse_int(text)
    if value is INVALID or value is DEFAULT:
        return value
    return value if CONTROL_CHAR_MIN <= value <= CONTROL_CHAR_MAX else INVALID


def _parse_commands(text: str):
    if text == "" or text.lower() in ("default", "none"):
        return DEFAULT
    allowed = set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_+/")
    core = text.rstrip("=")
    pad = len(text) - len(core)
    if len(core) % 4 == 1 or pad > (4 - len(core) % 4) % 4 or not set(core) <= allowed:
        return INVALID
    std = core.replace("-", "+").replace("_", "/")
    std += "=" * ((4 - len(std) % 4) % 4)
    try:
        raw = base64.b64decode(std, validate=True)
        raw.decode("utf-8")
    except (ValueError, UnicodeDecodeError):
        return INVALID
    return raw


SPACE = " \t\r\n\v\f"


def resolve_settings(argv: Dict[str, str], marked: Dict[str, str], defaults: Dict[str, str]) -> Settings:
    """Vorrang: argv > markierte PPD-Auswahl > PPD-Standard > eingebauter Standard.

    Ungültige Werte werden übergangen; "Default" bedeutet „nicht setzen“ bzw. eingebauter
    Standard. Optionsnamen in ``argv`` werden ohne Groß-/Kleinschreibung verglichen (wie
    cupsGetOption).
    """
    argv_ci = {k.lower(): v for k, v in argv.items()}
    levels = [argv_ci, {k.lower(): v for k, v in marked.items()}, {k.lower(): v for k, v in defaults.items()}]
    base = Settings()

    def pick(name, parser, fallback):
        for level in levels:
            raw = level.get(name.lower())
            if raw is None:
                continue
            text = raw.strip(SPACE)
            if text == "":
                continue
            value = parser(text)
            if value is INVALID:
                continue
            return fallback if value is DEFAULT else value
        return fallback

    s = Settings(
        language=pick("lwLanguage", lambda t: _parse_enum("lwLanguage", t), base.language),
        darkness=pick("lwDarkness", _parse_int, None),
        speed=pick("lwSpeed", _parse_int, None),
        media_type=pick("lwMediaType", lambda t: _parse_enum("lwMediaType", t), None),
        tracking=pick("lwMediaTracking", lambda t: _parse_enum("lwMediaTracking", t), None),
        print_mode=pick("lwPrintMode", lambda t: _parse_enum("lwPrintMode", t), None),
        label_top=pick("lwLabelTop", _parse_int, None),
        label_left=pick("lwLabelLeft", _parse_int, None),
        tear_off=pick("lwTearOff", _parse_int, None),
        backfeed=pick("lwBackfeed", lambda t: _parse_enum("lwBackfeed", t), None),
        mirror=pick("lwMirror", _parse_bool, False),
        negative=pick("lwNegative", _parse_bool, False),
        rotate180=pick("lwRotate180", _parse_bool, False),
        dither=pick("lwDither", lambda t: _parse_enum("lwDither", t), base.dither),
        threshold=pick("lwThreshold", _parse_int, base.threshold),
        compression=pick("lwCompression", lambda t: _parse_enum("lwCompression", t), base.compression),
        cut_every=pick("lwCutEvery", _parse_int, 0),
        calibrate=pick("lwCalibrate", _parse_bool, False),
        save_settings=pick("lwSaveSettings", _parse_bool, False),
        skip_blank=pick("lwSkipBlank", _parse_bool, False),
        start_commands=pick("lwStartCmd", _parse_commands, b""),
        end_commands=pick("lwEndCmd", _parse_commands, b""),
        rotation=pick("lwRotation", lambda t: _parse_enum("lwRotation", t), 0),
        mark_offset=pick("lwMarkOffset", _parse_int, None),
        stop_at_last=pick("lwStopAtLast", _parse_bool, False),
        stop_offset=pick("lwStopOffset", _parse_int, 0),
        pause_every=pick("lwPauseEvery", _parse_int, 0),
        rtc=pick("lwRTC", lambda t: _parse_enum("lwRTC", t), None),
        cancel_before=pick("lwCancelBefore", _parse_bool, False),
        cancel_delay=pick("lwCancelDelay", _parse_int, 1000),
        label_start_commands=pick("lwLabelStartCmd", _parse_commands, b""),
        label_end_commands=pick("lwLabelEndCmd", _parse_commands, b""),
        power_up_action=pick("lwPowerUpAction", lambda t: _parse_enum("lwPowerUpAction", t), None),
        head_close_action=pick("lwHeadCloseAction", lambda t: _parse_enum("lwHeadCloseAction", t), None),
    )
    if pick("lwControlChars", lambda t: _parse_enum("lwControlChars", t), False):
        s = replace(s, control_chars=(pick("lwFormatPrefix", _parse_char, STANDARD_CONTROL_CHARS[0]),
                                      pick("lwControlPrefix", _parse_char, STANDARD_CONTROL_CHARS[1]),
                                      pick("lwDelimiter", _parse_char, STANDARD_CONTROL_CHARS[2])))
    return s.clamped()


def resolve_collate(argv: Dict[str, str], marked: Dict[str, str]) -> bool:
    """Sortieren: "collate" > "multiple-document-handling" > PPD *Collate > True."""
    argv_ci = {k.lower(): v for k, v in argv.items()}
    value = argv_ci.get("collate")
    if value is not None:
        parsed = _parse_bool(value.strip(SPACE))
        if parsed is not INVALID and parsed is not DEFAULT:
            return parsed
    mdh = argv_ci.get("multiple-document-handling")
    if mdh is not None:
        if "uncollated" in mdh:
            return False
        if "collated" in mdh or mdh.startswith("single-document"):
            return True
    choice = {k.lower(): v for k, v in marked.items()}.get("collate")
    if choice is not None:
        parsed = _parse_bool(choice.strip(SPACE))
        if parsed is not INVALID and parsed is not DEFAULT:
            return parsed
    return True


def parse_copies(text: str) -> int:
    """Kopien aus argv[4] wie der Filter: ungültig → 1, < 1 → 1, Obergrenze MAX_QUANTITY."""
    value = _parse_int(text.strip(SPACE)) if text.strip(SPACE) else INVALID
    if value is INVALID or value is DEFAULT:
        return 1
    return max(1, min(MAX_QUANTITY, value))


def parse_cups_options(text: str) -> Dict[str, str]:
    """Vereinfachtes cupsParseOptions für die Testoptionen: name=wert, durch Leerzeichen
    getrennt, Anführungszeichen im Wert erlaubt; "name" allein → "true", "noname" → name="false"
    (wie libcups)."""
    result: Dict[str, str] = {}
    i, n = 0, len(text)
    while i < n:
        while i < n and text[i] in SPACE:
            i += 1
        if i >= n:
            break
        start = i
        while i < n and text[i] not in "=" + SPACE:
            i += 1
        name = text[start:i]
        value = "true"
        if i < n and text[i] == "=":
            i += 1
            buf = []
            while i < n and text[i] not in SPACE:
                ch = text[i]
                if ch in "'\"":
                    quote = ch
                    i += 1
                    while i < n and text[i] != quote:
                        if text[i] == "\\" and i + 1 < n:
                            i += 1
                        buf.append(text[i])
                        i += 1
                    i += 1
                    continue
                if ch == "\\" and i + 1 < n:
                    i += 1
                    ch = text[i]
                buf.append(ch)
                i += 1
            value = "".join(buf)
        elif name[:2].lower() == "no":
            name, value = name[2:], "false"
        result[name] = value
    return result


# --------------------------------------------------------------------------------------------
# §8 Druckauftrag
# --------------------------------------------------------------------------------------------

MAX_QUANTITY = 99_999_999
DEFAULT_GAP_DOTS = 24

ZPL_CODES = {
    "print_mode": {"TearOff": "T", "PeelOff": "P", "Cutter": "C", "DelayedCut": "D", "Rewind": "R",
                   "Applicator": "A", "Kiosk": "K"},
    "tracking": {"Gap": "Y", "BlackMark": "M", "Continuous": "N", "Auto": "A", "Notch": "W"},
    "media_action": {"Feed": "F", "Calibrate": "C", "Length": "L", "NoMotion": "N", "ShortCal": "S"},
    "media_type": {"DirectThermal": "D", "ThermalTransfer": "T"},
    "backfeed": {"After": "A", "Before": "B", "Normal": "N", "Off": "O"},
}


#: Setzwerte für setvar "media.printmode" der Linerless-Modi (kein ^MM-Code) laut Zebra-SGD-Referenz:
#: Kennbuchstaben L/U/V; für Linerless schneiden/verzögert schneiden ist keiner dokumentiert (Wort).
LINERLESS_SGD = {"LinerlessPeel": "L", "LinerlessCut": "linerless cut",
                 "LinerlessDelayedCut": "linerless delayed cut", "LinerlessRewind": "U",
                 "LinerlessTear": "V"}


def preprocess(page: Bitmap, s: Settings, max_width: int) -> Optional[Bitmap]:
    rotation = s.effective_rotation
    bm = rotate_quarter(page, rotation) if rotation in (90, 270) else page          # (0)
    bm = crop(bm, max_width)                                                        # (1)
    if bm.width == 0 or bm.height == 0:
        return None
    if s.stop_at_last and s.tracking == "Continuous":                               # (1b)
        bm = with_height(bm, max(1, last_black_row(bm) + 1 + s.stop_offset))
    if s.negative:                                                                  # (2)
        bm = invert(bm)
    if s.skip_blank and is_blank(bm):                                               # (3)
        return None
    if s.mirror and s.language != "ZPL":                                            # (4)
        bm = mirror(bm)
    if rotation == 180 and s.language == "CPCL":                                    # (5)
        bm = rotate180(bm)
    return bm


def set_time_line(when: int) -> str:
    """^XA^STmm,dd,yyyy,hh,mm,ss,M^XZ in Ortszeit (Umgebungsvariable TZ)."""
    t = time.localtime(when)
    return "^XA^ST%02d,%02d,%04d,%02d,%02d,%02d,M^XZ" % (t.tm_mon, t.tm_mday, t.tm_year, t.tm_hour,
                                                          t.tm_min, t.tm_sec)


def graphic_data(bm: Bitmap, compression: str) -> bytes:
    raw = bytes(bm.data)
    if compression == "Hex":
        return hex_encode(raw)
    if compression == "ACS":
        return acs_encode(bm)
    return z64_encode(raw)


def label_sequence(count: int, copies: int, collate: bool) -> List[Tuple[int, int]]:
    q = max(1, min(MAX_QUANTITY, copies))
    if collate and count > 1:
        return [(i, 1) for _ in range(q) for i in range(count)]
    return [(i, q) for i in range(count)]


def encode_job(pages: Sequence[Bitmap], settings: Settings, *, resolution_dpi: int = 203,
               max_width: int = 0, gap_dots: int = DEFAULT_GAP_DOTS, copies: int = 1,
               collate: bool = True, now: Optional[int] = None, time_step: int = 0) -> bytes:
    """Kodiert einen Auftrag nach §8.

    ``now`` (Sekunden seit 1970, Standard: aktuelle Zeit) und ``time_step`` bilden die Uhr für
    ``^ST`` (lwRTC): Auftragskopf = ``now``, Etikett k (0-basiert, Sortierwiederholungen zählen
    mit) = ``now + k · time_step`` – wie ``LW_FIXED_TIME``/``LW_TIME_STEP_SECONDS`` im Filter."""
    s = settings.clamped()
    processed = [bm for bm in (preprocess(p, s, max_width) for p in pages) if bm is not None]
    seq = label_sequence(len(processed), copies, collate)
    out = bytearray()
    start_time = int(time.time()) if now is None else now
    if s.control_chars is None:
        table = None
    else:
        table = bytes.maketrans(b"^~,", bytes(s.control_chars))

    def line(text: str, end: str = "\n"):
        out.extend((text + end).encode("utf-8"))

    def cmd(text: str) -> None:
        """Selbst erzeugter ZPL-Befehl: Steuerzeichen in einem Durchgang ersetzen."""
        data = text.encode("ascii")
        out.extend(data if table is None else data.translate(table))

    def raw_line(data: bytes) -> None:
        if data:
            out.extend(data + b"\n")

    if s.language == "ZPL":
        if s.cancel_before:          # ~JA zuerst: löscht die Daten vor sich im Eingangspuffer
            cmd("~JA\n")
        raw_line(s.start_commands)
        if s.darkness is not None:
            cmd("~SD%02d\n" % s.darkness)
        if s.tear_off is not None:
            cmd("~TA%03d\n" % s.tear_off)
        if s.backfeed:
            cmd("~JS%s\n" % ZPL_CODES["backfeed"][s.backfeed])
        if s.calibrate:
            cmd("~JC\n")
        if s.print_mode in LINERLESS_SGD:
            out.extend(b'! U1 setvar "media.printmode" "%s"\r\n' % LINERLESS_SGD[s.print_mode].encode("ascii"))
        if s.power_up_action and s.head_close_action:
            cmd("^XA^MF%s,%s^XZ\n" % (ZPL_CODES["media_action"][s.power_up_action],
                                     ZPL_CODES["media_action"][s.head_close_action]))
        last_st = start_time
        if s.rtc:
            cmd(set_time_line(start_time) + "\n")
        for n, (index, qty) in enumerate(seq):
            bm = processed[index]
            if s.rtc in ("EveryLabel", "EveryMinute"):
                t = start_time + n * time_step
                if (n > 0) if s.rtc == "EveryLabel" else (t - last_st >= 60):
                    cmd(set_time_line(t) + "\n")
                    last_st = t
            cmd("^XA\n")
            raw_line(s.label_start_commands)
            head = []
            if s.print_mode and s.print_mode not in LINERLESS_SGD:
                head.append("^MM" + ZPL_CODES["print_mode"][s.print_mode])
            if s.tracking == "BlackMark" and s.mark_offset is not None:
                head.append("^MNM,%d" % s.mark_offset)
            elif s.tracking:
                head.append("^MN" + ZPL_CODES["tracking"][s.tracking])
            if s.media_type:
                head.append("^MT" + ZPL_CODES["media_type"][s.media_type])
            if s.speed is not None:
                head.append("^PR%d,%d,%d" % (s.speed, s.speed, s.speed))
            head += ["^PW%d" % bm.width, "^LL%d" % bm.height, "^LH0,0"]
            if s.label_top is not None:
                head.append("^LT%d" % s.label_top)
            if s.label_left is not None:
                head.append("^LS%d" % s.label_left)
            head.append("^POI" if s.effective_rotation == 180 else "^PON")
            head.append("^PMY" if s.mirror else "^PMN")
            total = len(bm.data)
            cmd("".join(h + "\n" for h in head) + "^FO0,0^GFA,%d,%d,%d," % (total, total, bm.bpr))
            out.extend(graphic_data(bm, s.compression))
            cmd("^FS\n")
            if s.pause_every > 0:
                cmd("^PQ%d,%d,0,N\n" % (qty, s.pause_every))
            elif s.cut_every > 0:
                cmd("^PQ%d,%d,0,Y\n" % (qty, s.cut_every))
            else:
                cmd("^PQ%d\n" % qty)
            if n == 0 and s.save_settings:
                cmd("^JUS\n")
            raw_line(s.label_end_commands)
            cmd("^XZ\n")
        raw_line(s.end_commands)
    elif s.language == "EPL":
        if s.cancel_before:
            out.extend(b"~JA\n")     # wörtlich, wie die Startbefehle (keine eigenen Steuerzeichen)
        raw_line(s.start_commands)
        for index, qty in seq:
            bm = processed[index]
            out.extend(b"\n")
            line("N")
            raw_line(s.label_start_commands)
            line("q%d" % bm.width)
            if s.tracking == "BlackMark":
                line("Q%d,B%d" % (bm.height, gap_dots))
            elif s.tracking == "Continuous":
                line("Q%d,0" % bm.height)
            else:
                line("Q%d,%d" % (bm.height, gap_dots))
            if s.speed is not None:
                line("S%d" % max(1, min(6, s.speed)))
            if s.darkness is not None:
                line("D%d" % max(0, min(15, (s.darkness + 1) // 2)))
            line("ZB" if s.effective_rotation == 180 else "ZT")
            if s.media_type or s.print_mode:
                opt = "O"
                if s.media_type == "DirectThermal":
                    opt += "D"
                if s.print_mode == "Cutter":
                    opt += "C"
                elif s.print_mode == "PeelOff":
                    opt += "P"
                line(opt)
            out.extend(b"GW0,0,%d,%d," % (bm.bpr, bm.height))
            out.extend(bytes(b ^ 0xFF for b in bm.data))   # EPL: Bit 0 = schwarz
            out.extend(b"\n")
            raw_line(s.label_end_commands)
            line("P%d" % qty)
        if s.end_commands:
            out.extend(s.end_commands + b"\n")
    elif s.language == "CPCL":
        res = 200 if resolution_dpi in (203, 0) else resolution_dpi
        for index, qty in seq:
            bm = processed[index]
            line("! 0 %d %d %d %d" % (res, res, bm.height, qty), "\r\n")
            line("PAGE-WIDTH %d" % bm.width, "\r\n")
            if s.darkness is not None:
                line("CONTRAST %d" % max(0, min(3, (s.darkness * 3 + 15) // 30)), "\r\n")
            if s.speed is not None:
                line("SPEED %d" % max(0, min(5, s.speed)), "\r\n")
            out.extend(b"CG %d %d 0 0 " % (bm.bpr, bm.height))
            out.extend(bytes(bm.data))
            out.extend(b"\r\n")
            if s.tracking != "Continuous":
                line("FORM", "\r\n")
            line("PRINT", "\r\n")
    else:
        raise ValueError("unbekannte Sprache %r" % s.language)
    return bytes(out)


def encode_job_from_luminance(images: Sequence[Tuple[int, int, bytes]], settings: Settings,
                              **kwargs) -> bytes:
    """Rastert jedes Luminanzbild über die volle Breite (vor dem Abschneiden) und kodiert den
    Auftrag – entspricht JobEncoder.encode(images:) bzw. dem CUPS-Filter."""
    s = settings.clamped()
    pages = [dither(lum, w, h, s.dither, s.threshold) for (w, h, lum) in images]
    return encode_job(pages, s, **kwargs)


def selftest() -> None:
    """Schnelle Eigenprüfung der Referenz (bekannte Werte und Rundreisen)."""
    import random
    assert crc16_xmodem(b"123456789") == 0x31C3
    assert tdiv(-7, 2) == -3 and tdiv(7, -2) == -3 and tdiv(-784, 16) == -49
    assert dither(bytes([100, 100, 100]), 3, 1, "FloydSteinberg").data == bytearray([0xA0])
    assert dither(bytes([0, 1, 127, 128, 129, 254, 255, 100]), 8, 1, "Threshold").data == bytearray([0xE1])
    assert acs_encode(Bitmap(16, 1, bytearray([0x00, 0x00]))) == b","
    assert acs_encode(Bitmap(8, 1, bytearray([0xC0]))) == b"C0"
    assert acs_encode(Bitmap(16, 2, bytearray([0xC0, 0x40, 0, 0]))) == b"C040,"
    assert acs_encode(Bitmap(2000, 1, bytearray([0x77] * 250))) == b"zY7jG7"
    rng = random.Random(1)
    for _ in range(200):
        w, h = rng.randint(1, 70), rng.randint(1, 6)
        bm = Bitmap.from_rows(w, ("".join(rng.choice("0001") for _ in range(w)) for _ in range(h)))
        assert acs_decode(acs_encode(bm), bm.bpr, len(bm.data)) == bytes(bm.data)
        assert z64_decode(z64_encode(bytes(bm.data))) == bytes(bm.data)
        assert mirror(mirror(bm)).data == bm.data and rotate180(rotate180(bm)).data == bm.data
        assert invert(invert(bm)).data == bm.data
    assert parse_cups_options("a=1 noCollate c='x y' d") == {"a": "1", "Collate": "false", "c": "x y", "d": "true"}
    assert resolve_settings({}, {}, {}) == Settings()
    assert resolve_settings({"lwDarkness": "99", "lwThreshold": "0"}, {}, {}).darkness == 30
    assert _parse_commands(base64url_encode("^XA")) == b"^XA"
    assert _parse_commands("Zm9v=") is INVALID and _parse_commands("_w") is INVALID
    for _ in range(100):
        w, h = rng.randint(1, 40), rng.randint(1, 9)
        bm = Bitmap.from_rows(w, ("".join(rng.choice("01") for _ in range(w)) for _ in range(h)))
        r90 = rotate_quarter(bm, 90)
        assert (r90.width, r90.height) == (h, w)
        assert all(r90.get(h - 1 - y, x) == bm.get(x, y) for y in range(h) for x in range(w))
        r270 = rotate_quarter(bm, 270)
        assert all(r270.get(y, w - 1 - x) == bm.get(x, y) for y in range(h) for x in range(w))
        assert rotate_quarter(r90, 270).data == bm.data
        assert rotate_quarter(rotate_quarter(bm, 90), 90).data == rotate180(bm).data
    assert with_height(Bitmap(9, 2, bytearray(b"\x80\x00\x00\x00")), 3).data == bytearray(b"\x80\x00" + bytes(4))
    assert last_black_row(Bitmap(9, 3)) == -1
    s = resolve_settings({"lwControlChars": "Printer", "lwFormatPrefix": "35", "lwDelimiter": "200"}, {}, {})
    assert s.control_chars == (35, 0x7E, 0x2C)
    assert resolve_settings({"lwFormatPrefix": "35"}, {}, {}).control_chars is None
    assert resolve_settings({"lwRotation": "90", "lwRotate180": "True"}, {}, {}).effective_rotation == 90
    assert resolve_settings({"lwRotate180": "True"}, {}, {}).effective_rotation == 180
    assert set_time_line(0)[-5:] == ",M^XZ"


__all__ = [
    "Bitmap", "Settings", "DITHERS", "dither", "luminance_from_samples", "luminance_line",
    "is_supported_format", "crop", "invert", "is_blank", "mirror", "rotate180", "hex_encode",
    "acs_encode", "acs_decode", "crc16_xmodem", "z64_encode", "z64_decode", "base64url_encode",
    "resolve_settings", "parse_cups_options", "encode_job", "encode_job_from_luminance",
    "label_sequence", "preprocess", "resolve_collate", "parse_copies", "selftest", "rotate_quarter",
    "last_black_row", "with_height", "set_time_line", "LINERLESS_SGD", "STANDARD_CONTROL_CHARS",
]


if __name__ == "__main__":
    selftest()
    print("reference_encoder: Eigenprüfung bestanden")
