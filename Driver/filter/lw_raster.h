/*
 * lw_raster.h – Umrechnung beliebiger CUPS-Rasterzeilen in 8-Bit-Luminanz (ARCHITECTURE.md §4.1).
 *
 * Unabhängig von libcups (die Zahlenwerte der Farbräume und Farbanordnungen entsprechen
 * cups_cspace_t bzw. cups_order_t), damit die Umrechnung ohne CUPS-Datenstrom testbar ist.
 *
 * Regeln (L = 0 schwarz … 255 weiß):
 *   - W / SW (Graustufen):  L = v
 *   - K (Schwarzanteil):    L = 255 − v
 *   - RGB / sRGB / AdobeRGB: L = (299·R + 587·G + 114·B) / 1000
 *   - RGBA:                 L_rgb wie oben, auf Weiß komponiert: (L_rgb·A + 255·(255 − A)) / 255
 *   - CMYK / YMCK / KCMY:   L = 255 − min(255, K + (C + M + Y) / 3)
 *   - CMY / YMC:            L = 255 − min(255, (C + M + Y) / 3)
 *   - Bittiefen: 8 Bit direkt; 16 Bit → höherwertiges Byte des Werts (nach cupsRasterReadPixels
 *     liegen 16-Bit-Werte in Host-Byte-Reihenfolge vor); 1/2/4 Bit → v · 255 / (2^b − 1).
 *     Damit gilt für 1 Bit: W/SW Bit 0 → 0 (schwarz), K Bit 1 → 0 (schwarz).
 *   - Farbanordnung: chunky (Pixel nacheinander) und banded (je Zeile alle Werte eines Kanals
 *     nacheinander). Bei chunky mit Füllkanälen (z. B. 1-Bit-RGB mit 4 Bit je Pixel) stehen die
 *     Farbkanäle rechtsbündig im Pixel (Füllbits vorn), wie CUPS sie erzeugt. Planar wird nur
 *     für einkanalige Farbräume akzeptiert (dort identisch mit chunky).
 */

#ifndef LW_RASTER_H
#define LW_RASTER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* Farbräume (Werte wie cups_cspace_t). */
enum {
    LW_CSPACE_W = 0,
    LW_CSPACE_RGB = 1,
    LW_CSPACE_RGBA = 2,
    LW_CSPACE_K = 3,
    LW_CSPACE_CMY = 4,
    LW_CSPACE_YMC = 5,
    LW_CSPACE_CMYK = 6,
    LW_CSPACE_YMCK = 7,
    LW_CSPACE_KCMY = 8,
    LW_CSPACE_SW = 18,
    LW_CSPACE_SRGB = 19,
    LW_CSPACE_ADOBERGB = 20
};

/* Farbanordnungen (Werte wie cups_order_t). */
enum {
    LW_ORDER_CHUNKY = 0,
    LW_ORDER_BANDED = 1,
    LW_ORDER_PLANAR = 2
};

/** Relevante Felder eines CUPS-Seitenkopfs. */
typedef struct lw_raster_format {
    unsigned width;            /* cupsWidth */
    unsigned height;           /* cupsHeight */
    unsigned bits_per_color;   /* cupsBitsPerColor */
    unsigned bits_per_pixel;   /* cupsBitsPerPixel */
    unsigned bytes_per_line;   /* cupsBytesPerLine */
    unsigned color_order;      /* cupsColorOrder */
    unsigned color_space;      /* cupsColorSpace */
} lw_raster_format;

typedef enum lw_luma_kind {
    LW_LUMA_GRAY,       /* L = v */
    LW_LUMA_BLACK,      /* L = 255 − v */
    LW_LUMA_RGB,        /* Kanäle R, G, B */
    LW_LUMA_RGBA,       /* Kanäle R, G, B, A */
    LW_LUMA_CMY,        /* drei Kanäle, Summe symmetrisch */
    LW_LUMA_CMYK,       /* K an Position `k_index` */
} lw_luma_kind;

/** Vorbereiteter Umrechner für eine Seite. */
typedef struct lw_raster_converter {
    lw_raster_format format;
    lw_luma_kind kind;
    unsigned channels;         /* Farbkanäle (1, 3 oder 4) */
    unsigned k_index;          /* Index des K-Kanals (nur CMYK-Varianten) */
    unsigned bpc;              /* Bits je Kanal */
    unsigned pixel_bits;       /* chunky: Bits je Pixel (inkl. Füllkanäle) */
    unsigned slot_offset;      /* chunky: Index des ersten Farbkanals im Pixel */
    size_t band_bytes;         /* banded: Bytes je Kanalband */
    bool banded;
} lw_raster_converter;

/** Lesbarer Name eines Farbraums (z. B. "SW", "CIELab", "ICC3"), für Meldungen. */
const char *lw_raster_color_space_name(unsigned color_space);

/**
 * Prüft das Format und bereitet die Umrechnung vor. Liefert false und eine deutsche
 * Fehlermeldung in `error` (Größe `error_size`) bei nicht unterstützten oder widersprüchlichen
 * Angaben (planar mehrkanalig, unbekannter Farbraum, Bittiefe, zu kurze Zeilen …).
 */
bool lw_raster_converter_init(lw_raster_converter *c, const lw_raster_format *format,
                              char *error, size_t error_size);

/**
 * Wandelt eine Rasterzeile (`bytes_per_line` Bytes) in `width` Luminanzwerte um.
 */
void lw_raster_convert_line(const lw_raster_converter *c, const uint8_t *line, uint8_t *lum);

#endif /* LW_RASTER_H */
