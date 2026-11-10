/*
 * lw_dither.h – Rasterung von 8-Bit-Luminanz in 1-Bit, bitgenau nach ARCHITECTURE.md §4.1
 * (identisch zu `Ditherer` in LabelWerkImaging).
 *
 * Eingabe: Luminanz L ∈ 0…255 (0 = schwarz), Schwelle T ∈ 1…254 (wird begrenzt).
 * Ausgabe: gepackte Zeilen, MSB zuerst, 1 = schwarz, Füllbits 0.
 *
 * Die Rasterung arbeitet zeilenweise (Streaming): Für eine Seite beliebiger Höhe werden nur drei
 * Fehlerzeilen gehalten – ideal für den CUPS-Filter, der Rasterzeilen einzeln liest.
 */

#ifndef LW_DITHER_H
#define LW_DITHER_H

#include <stdbool.h>
#include <stdint.h>

#include "lw_bitmap.h"

typedef enum lw_dither_algorithm {
    LW_DITHER_THRESHOLD = 0,     /* schwarz ⇔ L < T */
    LW_DITHER_ORDERED,           /* Bayer 8×8 */
    LW_DITHER_HALFTONE,          /* Clustered Dot 8×8 */
    LW_DITHER_FLOYD_STEINBERG,   /* D = 16 */
    LW_DITHER_ATKINSON,          /* D = 8 */
    LW_DITHER_STUCKI             /* D = 42 */
} lw_dither_algorithm;

#define LW_DITHER_COUNT 6

/** Bayer-Matrix (Index y % 8 * 8 + x % 8). */
extern const int32_t lw_bayer_matrix[64];
/** Clustered-Dot-Matrix für `halftone`. */
extern const int32_t lw_halftone_matrix[64];

/** Randzugabe der Fehlerzeilen links/rechts; Anteile außerhalb des Bildes landen dort. */
#define LW_DITHER_MARGIN 2

typedef struct lw_ditherer {
    lw_dither_algorithm algorithm;
    int width;
    int32_t threshold;          /* T nach Begrenzung auf 1…254 */
    int32_t cell[64];           /* ordered/halftone: M·4 + 2 + (T − 128) */
    int32_t *errors;            /* 3 Zeilen à (width + 2·MARGIN), nur Fehlerdiffusion */
    int32_t *rows[3];           /* aktuelle, nächste, übernächste Zeile (ab Bildspalte 0) */
    long y;                     /* Index der nächsten Zeile */
} lw_ditherer;

/** Begrenzt T auf 1…254. */
int lw_dither_clamp_threshold(int threshold);

/**
 * Bereitet die zeilenweise Rasterung für Zeilen der Breite `width` vor.
 * Liefert false bei ungültiger Breite oder Speichermangel.
 */
bool lw_ditherer_init(lw_ditherer *d, lw_dither_algorithm algorithm, int threshold, int width);

/**
 * Rastert die nächste Zeile. `lum` hat `width` Bytes; `out` erhält (width + 7) / 8 Bytes
 * (wird vollständig überschrieben, Füllbits 0).
 */
void lw_ditherer_row(lw_ditherer *d, const uint8_t *lum, uint8_t *out);

void lw_ditherer_free(lw_ditherer *d);

/**
 * Rastert ein ganzes Bild (Komfortfunktion, u. a. für Tests). `out` muss initialisiert sein
 * (lw_bitmap_init); vorhandener Speicher wird freigegeben und die Bitmap neu angelegt.
 * Liefert false bei ungültigen Maßen oder Speichermangel (`out` ist dann leer).
 */
bool lw_dither_image(const uint8_t *lum, int width, int height, lw_dither_algorithm algorithm,
                     int threshold, lw_bitmap *out);

#endif /* LW_DITHER_H */
