/*
 * lw_bitmap.h – 1-Bit-Bitmaps der LabelWerk-Filter (entspricht `MonoBitmap` in Swift).
 *
 * Darstellung (ARCHITECTURE.md §4): zeilenweise, `bpr = (width + 7) / 8` Bytes je Zeile,
 * höchstwertiges Bit zuerst, 1 = schwarz (Punkt brennt). Füllbits rechts der Bildbreite sind
 * immer 0 – alle Operationen erhalten diese Invariante.
 */

#ifndef LW_BITMAP_H
#define LW_BITMAP_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/** Obergrenze für den Bitmapspeicher einer Seite (256 MiB) – Schutz vor unsinnigen Kopfdaten. */
#define LW_BITMAP_MAX_BYTES ((size_t)256 * 1024 * 1024)

typedef struct lw_bitmap {
    int width;      /* Punkte je Zeile (≥ 0) */
    int height;     /* Zeilen (≥ 0) */
    int bpr;        /* Bytes je Zeile = (width + 7) / 8 */
    uint8_t *data;  /* bpr * height Bytes, NULL bei leerer Fläche */
} lw_bitmap;

/** Leere Bitmap (0 × 0, ohne Speicher). */
void lw_bitmap_init(lw_bitmap *bm);

/**
 * Legt eine weiße Bitmap an (alle Bits 0). Liefert false bei negativen Maßen, Überlauf,
 * Überschreitung von LW_BITMAP_MAX_BYTES oder Speichermangel (`bm` ist dann leer).
 * Vorhandener Speicher in `bm` wird zuvor freigegeben.
 */
bool lw_bitmap_alloc(lw_bitmap *bm, int width, int height);

void lw_bitmap_free(lw_bitmap *bm);

/** Gesamtzahl der Datenbytes (bpr * height). */
size_t lw_bitmap_size(const lw_bitmap *bm);

/** Zeiger auf Zeile `y`. */
static inline uint8_t *lw_bitmap_row(const lw_bitmap *bm, int y)
{
    return bm->data + (size_t)y * (size_t)bm->bpr;
}

bool lw_bitmap_get(const lw_bitmap *bm, int x, int y);
void lw_bitmap_set(lw_bitmap *bm, int x, int y, bool black);

/** Maske der gültigen Bits im letzten Byte einer Zeile (0xFF bei width % 8 == 0). */
uint8_t lw_bitmap_last_mask(int width);

/**
 * Schneidet rechts ab, falls `width > max_width` (> 0); sonst keine Änderung.
 * Arbeitet ohne zusätzlichen Speicher (Zeilen werden im Puffer zusammengeschoben).
 */
void lw_bitmap_crop_width(lw_bitmap *bm, int max_width);

/** Negativ: alle Bildbits invertieren, Füllbits bleiben 0. */
void lw_bitmap_invert(lw_bitmap *bm);

/** true, wenn kein Bit gesetzt ist (auch bei leerer Fläche). */
bool lw_bitmap_is_blank(const lw_bitmap *bm);

/** Horizontal spiegeln (x → width − 1 − x). Liefert false bei Speichermangel. */
bool lw_bitmap_mirror(lw_bitmap *bm);

/** Um 180° drehen (Zeilenfolge umkehren und jede Zeile spiegeln). false bei Speichermangel. */
bool lw_bitmap_rotate180(lw_bitmap *bm);

/**
 * Spiegelt eine einzelne Zeile von `src` nach `dst` (beide `bpr` Bytes, dürfen nicht
 * überlappen). Füllbits in `dst` sind danach 0.
 */
void lw_bitmap_mirror_row(const uint8_t *src, uint8_t *dst, int width);

#endif /* LW_BITMAP_H */
