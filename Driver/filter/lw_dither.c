/*
 * lw_dither.c – Schwelle, geordnete Rasterung und Fehlerdiffusion (ARCHITECTURE.md §4.1).
 *
 * Alle Divisionen sind C-Ganzzahldivisionen (Abschneiden Richtung 0) – exakt wie in Swift.
 * Fehlerdiffusion: Zeilen von oben nach unten, Pixel stets von links nach rechts (keine
 * Serpentine), Fehlerpuffer int32_t. Jeder Anteil wird einzeln als e·w/D berechnet; Anteile
 * außerhalb des Bildes landen in den Randspalten bzw. in Zeilen, die nie gelesen werden, und
 * entfallen damit.
 */

#if !defined(__APPLE__) && !defined(_DEFAULT_SOURCE)
#  define _DEFAULT_SOURCE 1
#endif

#include "lw_dither.h"

#include <stdlib.h>
#include <string.h>

const int32_t lw_bayer_matrix[64] = {
     0, 32,  8, 40,  2, 34, 10, 42,
    48, 16, 56, 24, 50, 18, 58, 26,
    12, 44,  4, 36, 14, 46,  6, 38,
    60, 28, 52, 20, 62, 30, 54, 22,
     3, 35, 11, 43,  1, 33,  9, 41,
    51, 19, 59, 27, 49, 17, 57, 25,
    15, 47,  7, 39, 13, 45,  5, 37,
    63, 31, 55, 23, 61, 29, 53, 21,
};

const int32_t lw_halftone_matrix[64] = {
    24, 10, 12, 26, 35, 47, 49, 37,
     8,  0,  2, 14, 45, 59, 61, 51,
    22,  6,  4, 16, 43, 57, 63, 53,
    30, 20, 18, 28, 33, 41, 55, 39,
    34, 46, 48, 36, 25, 11, 13, 27,
    44, 58, 60, 50,  9,  1,  3, 15,
    42, 56, 62, 52, 23,  7,  5, 17,
    32, 40, 54, 38, 31, 21, 19, 29,
};

int lw_dither_clamp_threshold(int threshold)
{
    if (threshold < 1)
        return 1;
    if (threshold > 254)
        return 254;
    return threshold;
}

static bool uses_error_diffusion(lw_dither_algorithm a)
{
    return a == LW_DITHER_FLOYD_STEINBERG || a == LW_DITHER_ATKINSON || a == LW_DITHER_STUCKI;
}

bool lw_ditherer_init(lw_ditherer *d, lw_dither_algorithm algorithm, int threshold, int width)
{
    memset(d, 0, sizeof(*d));
    if (width < 0 || (int)algorithm < 0 || (int)algorithm >= LW_DITHER_COUNT)
        return false;
    d->algorithm = algorithm;
    d->width = width;
    d->threshold = lw_dither_clamp_threshold(threshold);
    d->y = 0;

    if (algorithm == LW_DITHER_ORDERED || algorithm == LW_DITHER_HALFTONE) {
        const int32_t *m = algorithm == LW_DITHER_ORDERED ? lw_bayer_matrix : lw_halftone_matrix;
        int32_t shift = d->threshold - 128;
        for (int i = 0; i < 64; i++)
            d->cell[i] = m[i] * 4 + 2 + shift;
    }

    if (uses_error_diffusion(algorithm)) {
        size_t stride = (size_t)width + 2 * LW_DITHER_MARGIN;
        d->errors = calloc(stride * 3, sizeof(int32_t));
        if (d->errors == NULL)
            return false;
        for (int r = 0; r < 3; r++)
            d->rows[r] = d->errors + (size_t)r * stride + LW_DITHER_MARGIN;
    }
    return true;
}

void lw_ditherer_free(lw_ditherer *d)
{
    free(d->errors);
    d->errors = NULL;
    d->rows[0] = d->rows[1] = d->rows[2] = NULL;
}

/* Rotiert die Fehlerzeilen nach einer Bildzeile und leert die neue übernächste Zeile. */
static void rotate_rows(lw_ditherer *d)
{
    int32_t *old = d->rows[0];
    d->rows[0] = d->rows[1];
    d->rows[1] = d->rows[2];
    d->rows[2] = old;
    memset(old - LW_DITHER_MARGIN, 0, ((size_t)d->width + 2 * LW_DITHER_MARGIN) * sizeof(int32_t));
}

void lw_ditherer_row(lw_ditherer *d, const uint8_t *lum, uint8_t *out)
{
    const int w = d->width;
    const int bpr = (w + 7) / 8;
    const int32_t t = d->threshold;
    if (bpr > 0)
        memset(out, 0, (size_t)bpr);

    switch (d->algorithm) {
    case LW_DITHER_THRESHOLD:
        for (int x = 0; x < w; x++)
            if ((int32_t)lum[x] < t)
                out[x >> 3] |= (uint8_t)(0x80u >> (x & 7));
        break;

    case LW_DITHER_ORDERED:
    case LW_DITHER_HALFTONE: {
        const int32_t *cells = d->cell + (d->y & 7) * 8;
        for (int x = 0; x < w; x++)
            if ((int32_t)lum[x] < cells[x & 7])
                out[x >> 3] |= (uint8_t)(0x80u >> (x & 7));
        break;
    }

    case LW_DITHER_FLOYD_STEINBERG: {
        int32_t *cur = d->rows[0], *nxt = d->rows[1];
        for (int x = 0; x < w; x++) {
            int32_t v = (int32_t)lum[x] + cur[x];
            int32_t e;
            if (v < t) {
                out[x >> 3] |= (uint8_t)(0x80u >> (x & 7));
                e = v;          /* out = 0 */
            } else {
                e = v - 255;    /* out = 255 */
            }
            if (e != 0) {
                cur[x + 1] += e * 7 / 16;
                nxt[x - 1] += e * 3 / 16;
                nxt[x] += e * 5 / 16;
                nxt[x + 1] += e * 1 / 16;
            }
        }
        rotate_rows(d);
        break;
    }

    case LW_DITHER_ATKINSON: {
        int32_t *r0 = d->rows[0], *r1 = d->rows[1], *r2 = d->rows[2];
        for (int x = 0; x < w; x++) {
            int32_t v = (int32_t)lum[x] + r0[x];
            int32_t e;
            if (v < t) {
                out[x >> 3] |= (uint8_t)(0x80u >> (x & 7));
                e = v;
            } else {
                e = v - 255;
            }
            if (e != 0) {
                int32_t part = e * 1 / 8;   /* alle Gewichte 1 → identischer Anteil */
                r0[x + 1] += part;
                r0[x + 2] += part;
                r1[x - 1] += part;
                r1[x] += part;
                r1[x + 1] += part;
                r2[x] += part;
            }
        }
        rotate_rows(d);
        break;
    }

    case LW_DITHER_STUCKI: {
        int32_t *r0 = d->rows[0], *r1 = d->rows[1], *r2 = d->rows[2];
        for (int x = 0; x < w; x++) {
            int32_t v = (int32_t)lum[x] + r0[x];
            int32_t e;
            if (v < t) {
                out[x >> 3] |= (uint8_t)(0x80u >> (x & 7));
                e = v;
            } else {
                e = v - 255;
            }
            if (e != 0) {
                int32_t e8 = e * 8 / 42, e4 = e * 4 / 42, e2 = e * 2 / 42, e1 = e * 1 / 42;
                r0[x + 1] += e8;
                r0[x + 2] += e4;
                r1[x - 2] += e2;
                r1[x - 1] += e4;
                r1[x] += e8;
                r1[x + 1] += e4;
                r1[x + 2] += e2;
                r2[x - 2] += e1;
                r2[x - 1] += e2;
                r2[x] += e4;
                r2[x + 1] += e2;
                r2[x + 2] += e1;
            }
        }
        rotate_rows(d);
        break;
    }
    }
    d->y++;
}

bool lw_dither_image(const uint8_t *lum, int width, int height, lw_dither_algorithm algorithm,
                     int threshold, lw_bitmap *out)
{
    if (!lw_bitmap_alloc(out, width, height))
        return false;
    if (width == 0 || height == 0)
        return true;
    lw_ditherer d;
    if (!lw_ditherer_init(&d, algorithm, threshold, width)) {
        lw_bitmap_free(out);
        return false;
    }
    for (int y = 0; y < height; y++)
        lw_ditherer_row(&d, lum + (size_t)y * (size_t)width, lw_bitmap_row(out, y));
    lw_ditherer_free(&d);
    return true;
}
