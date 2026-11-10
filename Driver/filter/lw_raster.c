/*
 * lw_raster.c – CUPS-Rasterzeilen → 8-Bit-Luminanz.
 */

#if !defined(__APPLE__) && !defined(_DEFAULT_SOURCE)
#  define _DEFAULT_SOURCE 1
#endif

#include "lw_raster.h"

#include <stdio.h>
#include <string.h>

const char *lw_raster_color_space_name(unsigned cs)
{
    static const char *names[] = {
        "W", "RGB", "RGBA", "K", "CMY", "YMC", "CMYK", "YMCK", "KCMY", "KCMYcm", "GMCK", "GMCS",
        "WHITE", "GOLD", "SILVER", "CIEXYZ", "CIELab", "RGBW", "SW", "SRGB", "AdobeRGB"
    };
    static const char *icc[] = {
        "ICC1", "ICC2", "ICC3", "ICC4", "ICC5", "ICC6", "ICC7", "ICC8", "ICC9", "ICCA", "ICCB",
        "ICCC", "ICCD", "ICCE", "ICCF"
    };
    static const char *device[] = {
        "Device1", "Device2", "Device3", "Device4", "Device5", "Device6", "Device7", "Device8",
        "Device9", "DeviceA", "DeviceB", "DeviceC", "DeviceD", "DeviceE", "DeviceF"
    };
    if (cs < sizeof(names) / sizeof(names[0]))
        return names[cs];
    if (cs >= 32 && cs <= 46)
        return icc[cs - 32];
    if (cs >= 48 && cs <= 62)
        return device[cs - 48];
    return "unbekannt";
}

bool lw_raster_converter_init(lw_raster_converter *c, const lw_raster_format *f,
                              char *error, size_t error_size)
{
    memset(c, 0, sizeof(*c));
    c->format = *f;
    if (error_size > 0)
        error[0] = '\0';

    switch (f->color_space) {
    case LW_CSPACE_W:
    case LW_CSPACE_SW:
        c->kind = LW_LUMA_GRAY;
        c->channels = 1;
        break;
    case LW_CSPACE_K:
        c->kind = LW_LUMA_BLACK;
        c->channels = 1;
        break;
    case LW_CSPACE_RGB:
    case LW_CSPACE_SRGB:
    case LW_CSPACE_ADOBERGB:
        c->kind = LW_LUMA_RGB;
        c->channels = 3;
        break;
    case LW_CSPACE_RGBA:
        c->kind = LW_LUMA_RGBA;
        c->channels = 4;
        break;
    case LW_CSPACE_CMY:
    case LW_CSPACE_YMC:
        c->kind = LW_LUMA_CMY;
        c->channels = 3;
        break;
    case LW_CSPACE_CMYK:
    case LW_CSPACE_YMCK:
        c->kind = LW_LUMA_CMYK;
        c->channels = 4;
        c->k_index = 3;
        break;
    case LW_CSPACE_KCMY:
        c->kind = LW_LUMA_CMYK;
        c->channels = 4;
        c->k_index = 0;
        break;
    default:
        snprintf(error, error_size,
                 "Farbraum %s (cupsColorSpace %u) wird nicht unterstützt – unterstützt werden "
                 "W, SW, K, RGB, sRGB, AdobeRGB, RGBA, CMY, CMYK.",
                 lw_raster_color_space_name(f->color_space), f->color_space);
        return false;
    }

    unsigned bpc = f->bits_per_color;
    if (bpc != 1 && bpc != 2 && bpc != 4 && bpc != 8 && bpc != 16) {
        snprintf(error, error_size, "Bittiefe %u je Farbe wird nicht unterstützt (erlaubt: 1, 2, 4, 8, 16).", bpc);
        return false;
    }
    c->bpc = bpc;

    unsigned order = f->color_order;
    if (order > LW_ORDER_PLANAR) {
        snprintf(error, error_size, "Unbekannte Farbanordnung (cupsColorOrder %u).", order);
        return false;
    }
    if (order == LW_ORDER_PLANAR && c->channels > 1) {
        snprintf(error, error_size,
                 "Planare Farbanordnung mit %u Kanälen (%s) wird nicht unterstützt – bitte "
                 "chunky (cupsColorOrder 0) oder banded (1) verwenden.",
                 c->channels, lw_raster_color_space_name(f->color_space));
        return false;
    }

    uint64_t width = f->width;
    if (order == LW_ORDER_BANDED && c->channels > 1) {
        if (f->bytes_per_line % c->channels != 0) {
            snprintf(error, error_size,
                     "Bytes je Zeile (%u) sind bei banded-Anordnung nicht durch %u Kanäle teilbar.",
                     f->bytes_per_line, c->channels);
            return false;
        }
        c->banded = true;
        c->band_bytes = f->bytes_per_line / c->channels;
        uint64_t need = (width * bpc + 7) / 8;
        if (need > c->band_bytes) {
            snprintf(error, error_size,
                     "Rasterzeile zu kurz: %u Bytes je Zeile, benötigt %llu je Kanalband.",
                     f->bytes_per_line, (unsigned long long)need);
            return false;
        }
        return true;
    }

    /* chunky (oder einkanalig banded/planar – identisch zu chunky) */
    unsigned bpp = f->bits_per_pixel;
    if (bpp == 0 && c->channels == 1)
        bpp = bpc;   /* tolerant gegenüber Erzeugern, die cupsBitsPerPixel nicht setzen */
    if (bpp == 0 || bpp % bpc != 0 || bpp / bpc < c->channels || bpp > 240) {
        snprintf(error, error_size,
                 "Unstimmige Pixelgröße: %u Bit je Pixel bei %u Bit je Farbe und %u Kanälen (%s).",
                 f->bits_per_pixel, bpc, c->channels, lw_raster_color_space_name(f->color_space));
        return false;
    }
    /* bpp ist ein Vielfaches von bpc und bpc teilt 8 (bzw. ist 8/16) – ein Kanalwert liegt
     * daher nie über einer Bytegrenze. */
    c->pixel_bits = bpp;
    c->slot_offset = bpp / bpc - c->channels;
    uint64_t need = (width * bpp + 7) / 8;
    if (need > f->bytes_per_line) {
        snprintf(error, error_size,
                 "Rasterzeile zu kurz: %u Bytes je Zeile, benötigt %llu (%u Punkte × %u Bit).",
                 f->bytes_per_line, (unsigned long long)need, f->width, bpp);
        return false;
    }
    return true;
}

/* Liest einen Kanalwert an Bitposition `bit` und skaliert ihn auf 0…255. */
static inline unsigned read_sample(const uint8_t *base, uint64_t bit, unsigned bpc)
{
    switch (bpc) {
    case 8:
        return base[bit >> 3];
    case 16: {
        uint16_t v;
        memcpy(&v, base + (bit >> 3), sizeof(v));   /* Host-Byte-Reihenfolge */
        return (unsigned)(v >> 8);
    }
    case 4: {
        unsigned v = (base[bit >> 3] >> (4 - (unsigned)(bit & 7))) & 0x0Fu;
        return v * 17u;
    }
    case 2: {
        unsigned v = (base[bit >> 3] >> (6 - (unsigned)(bit & 7))) & 0x03u;
        return v * 85u;
    }
    default: { /* 1 */
        unsigned v = (base[bit >> 3] >> (7 - (unsigned)(bit & 7))) & 0x01u;
        return v * 255u;
    }
    }
}

static inline uint8_t luma_rgb(unsigned r, unsigned g, unsigned b)
{
    return (uint8_t)((299u * r + 587u * g + 114u * b) / 1000u);
}

void lw_raster_convert_line(const lw_raster_converter *c, const uint8_t *line, uint8_t *lum)
{
    const unsigned width = c->format.width;
    const unsigned bpc = c->bpc;

    /* Schnelle Wege für die häufigsten Formate. */
    if (!c->banded && c->channels == 1 && c->pixel_bits == bpc) {
        if (bpc == 8) {
            if (c->kind == LW_LUMA_GRAY) {
                memcpy(lum, line, width);
            } else {
                for (unsigned x = 0; x < width; x++)
                    lum[x] = (uint8_t)(255u - line[x]);
            }
            return;
        }
        if (bpc == 1) {
            const uint8_t on = c->kind == LW_LUMA_GRAY ? 255 : 0;
            const uint8_t off = (uint8_t)(255 - on);
            for (unsigned x = 0; x < width; x++)
                lum[x] = (line[x >> 3] & (0x80u >> (x & 7))) != 0 ? on : off;
            return;
        }
    }

    unsigned v[4] = { 0, 0, 0, 0 };
    for (unsigned x = 0; x < width; x++) {
        for (unsigned ch = 0; ch < c->channels; ch++) {
            if (c->banded)
                v[ch] = read_sample(line + c->band_bytes * ch, (uint64_t)x * bpc, bpc);
            else
                v[ch] = read_sample(line, (uint64_t)x * c->pixel_bits + (uint64_t)(c->slot_offset + ch) * bpc, bpc);
        }
        uint8_t l;
        switch (c->kind) {
        case LW_LUMA_GRAY:
            l = (uint8_t)v[0];
            break;
        case LW_LUMA_BLACK:
            l = (uint8_t)(255u - v[0]);
            break;
        case LW_LUMA_RGB:
            l = luma_rgb(v[0], v[1], v[2]);
            break;
        case LW_LUMA_RGBA: {
            unsigned base = luma_rgb(v[0], v[1], v[2]);
            unsigned a = v[3];
            l = (uint8_t)((base * a + 255u * (255u - a)) / 255u);
            break;
        }
        case LW_LUMA_CMY: {
            unsigned ink = (v[0] + v[1] + v[2]) / 3u;
            l = (uint8_t)(255u - (ink > 255u ? 255u : ink));
            break;
        }
        case LW_LUMA_CMYK:
        default: {
            unsigned k = v[c->k_index];
            unsigned sum = 0;
            for (unsigned ch = 0; ch < 4; ch++)
                if (ch != c->k_index)
                    sum += v[ch];
            unsigned ink = k + sum / 3u;
            l = (uint8_t)(255u - (ink > 255u ? 255u : ink));
            break;
        }
        }
        lum[x] = l;
    }
}
