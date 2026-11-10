/*
 * lw_bitmap.c – Operationen auf 1-Bit-Bitmaps (Abschneiden, Negativ, Spiegeln, Drehen).
 */

#if !defined(__APPLE__) && !defined(_DEFAULT_SOURCE)
#  define _DEFAULT_SOURCE 1
#endif

#include "lw_bitmap.h"

#include <stdlib.h>
#include <string.h>

/* Bitumkehr eines Bytes (Bit 7 ↔ Bit 0 …). */
static uint8_t reverse8(uint8_t b)
{
    b = (uint8_t)(((b & 0xF0u) >> 4) | ((b & 0x0Fu) << 4));
    b = (uint8_t)(((b & 0xCCu) >> 2) | ((b & 0x33u) << 2));
    b = (uint8_t)(((b & 0xAAu) >> 1) | ((b & 0x55u) << 1));
    return b;
}

void lw_bitmap_init(lw_bitmap *bm)
{
    bm->width = 0;
    bm->height = 0;
    bm->bpr = 0;
    bm->data = NULL;
}

bool lw_bitmap_alloc(lw_bitmap *bm, int width, int height)
{
    lw_bitmap_free(bm);
    if (width < 0 || height < 0)
        return false;
    int bpr = (int)(((long)width + 7) / 8);
    size_t total = (size_t)bpr * (size_t)height;
    if (height != 0 && total / (size_t)height != (size_t)bpr)
        return false;
    if (total > LW_BITMAP_MAX_BYTES)
        return false;
    uint8_t *data = NULL;
    if (total > 0) {
        data = calloc(total, 1);
        if (data == NULL)
            return false;
    }
    bm->width = width;
    bm->height = height;
    bm->bpr = bpr;
    bm->data = data;
    return true;
}

void lw_bitmap_free(lw_bitmap *bm)
{
    free(bm->data);
    lw_bitmap_init(bm);
}

size_t lw_bitmap_size(const lw_bitmap *bm)
{
    return (size_t)bm->bpr * (size_t)bm->height;
}

bool lw_bitmap_get(const lw_bitmap *bm, int x, int y)
{
    if (x < 0 || y < 0 || x >= bm->width || y >= bm->height)
        return false;
    return (lw_bitmap_row(bm, y)[x >> 3] & (0x80u >> (x & 7))) != 0;
}

void lw_bitmap_set(lw_bitmap *bm, int x, int y, bool black)
{
    if (x < 0 || y < 0 || x >= bm->width || y >= bm->height)
        return;
    uint8_t *byte = &lw_bitmap_row(bm, y)[x >> 3];
    uint8_t mask = (uint8_t)(0x80u >> (x & 7));
    if (black)
        *byte |= mask;
    else
        *byte &= (uint8_t)~mask;
}

uint8_t lw_bitmap_last_mask(int width)
{
    int rest = width & 7;
    return rest == 0 ? 0xFFu : (uint8_t)(0xFFu << (8 - rest));
}

void lw_bitmap_crop_width(lw_bitmap *bm, int max_width)
{
    if (max_width <= 0 || bm->width <= max_width)
        return;
    int new_bpr = (max_width + 7) / 8;
    uint8_t mask = lw_bitmap_last_mask(max_width);
    for (int y = 0; y < bm->height; y++) {
        uint8_t *dst = bm->data + (size_t)y * (size_t)new_bpr;
        const uint8_t *src = bm->data + (size_t)y * (size_t)bm->bpr;
        /* Ziel liegt nie hinter der Quelle → memmove von vorne ist sicher. */
        memmove(dst, src, (size_t)new_bpr);
        dst[new_bpr - 1] &= mask;
    }
    bm->width = max_width;
    bm->bpr = new_bpr;
    if (bm->height == 0) {
        free(bm->data);
        bm->data = NULL;
    }
}

void lw_bitmap_invert(lw_bitmap *bm)
{
    if (bm->bpr == 0 || bm->height == 0)
        return;
    uint8_t mask = lw_bitmap_last_mask(bm->width);
    for (int y = 0; y < bm->height; y++) {
        uint8_t *row = lw_bitmap_row(bm, y);
        for (int i = 0; i < bm->bpr; i++)
            row[i] = (uint8_t)~row[i];
        row[bm->bpr - 1] &= mask;
    }
}

bool lw_bitmap_is_blank(const lw_bitmap *bm)
{
    size_t total = lw_bitmap_size(bm);
    const uint8_t *p = bm->data;
    for (size_t i = 0; i < total; i++)
        if (p[i] != 0)
            return false;
    return true;
}

void lw_bitmap_mirror_row(const uint8_t *src, uint8_t *dst, int width)
{
    int bpr = (width + 7) / 8;
    if (bpr == 0)
        return;
    /* 1. Bytefolge umkehren und jedes Byte bitweise spiegeln: Punkt x landet auf Bitposition
     *    bpr*8 − 1 − x = (width − 1 − x) + pad.
     * 2. Um `pad` Bits nach links schieben, damit die (leeren) Füllbits wieder rechts stehen. */
    for (int i = 0; i < bpr; i++)
        dst[i] = reverse8(src[bpr - 1 - i]);
    int pad = bpr * 8 - width;
    if (pad > 0) {
        for (int i = 0; i < bpr - 1; i++)
            dst[i] = (uint8_t)((dst[i] << pad) | (dst[i + 1] >> (8 - pad)));
        dst[bpr - 1] = (uint8_t)(dst[bpr - 1] << pad);
    }
}

bool lw_bitmap_mirror(lw_bitmap *bm)
{
    if (bm->bpr == 0 || bm->height == 0)
        return true;
    uint8_t *tmp = malloc((size_t)bm->bpr);
    if (tmp == NULL)
        return false;
    for (int y = 0; y < bm->height; y++) {
        uint8_t *row = lw_bitmap_row(bm, y);
        lw_bitmap_mirror_row(row, tmp, bm->width);
        memcpy(row, tmp, (size_t)bm->bpr);
    }
    free(tmp);
    return true;
}

bool lw_bitmap_rotate180(lw_bitmap *bm)
{
    if (bm->bpr == 0 || bm->height == 0)
        return true;
    size_t bpr = (size_t)bm->bpr;
    uint8_t *tmp = malloc(bpr * 2);
    if (tmp == NULL)
        return false;
    uint8_t *a = tmp, *b = tmp + bpr;
    int top = 0, bottom = bm->height - 1;
    while (top < bottom) {
        uint8_t *rt = lw_bitmap_row(bm, top);
        uint8_t *rb = lw_bitmap_row(bm, bottom);
        lw_bitmap_mirror_row(rt, a, bm->width);
        lw_bitmap_mirror_row(rb, b, bm->width);
        memcpy(rt, b, bpr);
        memcpy(rb, a, bpr);
        top++;
        bottom--;
    }
    if (top == bottom) {
        uint8_t *rm = lw_bitmap_row(bm, top);
        lw_bitmap_mirror_row(rm, a, bm->width);
        memcpy(rm, a, bpr);
    }
    free(tmp);
    return true;
}
