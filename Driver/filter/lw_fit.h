/*
 * lw_fit.h – „An Etikett anpassen“ (lwFitToLabel, ARCHITECTURE.md §8 „F“).
 *
 * macOS-Programme schicken oft A4/Letter („Andere 210 × 297 mm“) statt der Etikettengröße der
 * Warteschlange. Weicht die Seitengröße (cupsPageSize) um mehr als 2 mm vom Etikett
 * (lwLabelWidth × lwLabelHeight, 1/100 mm) ab, wird die 8-Bit-Luminanz der Seite VOR dem Rastern
 * auf den Inhalt (L < 250) zugeschnitten, bei Bedarf per Flächenmittel verkleinert (nie
 * vergrößert) und mittig auf ein weißes Etikett gesetzt. Byte-gleich zu `LabelFit` (Swift) und
 * `fit_page` (Python-Referenz); nur Ganzzahlrechnung (64 Bit) bis auf die Umrechnung
 * Punkte → 1/100 mm (double, exakt wie spezifiziert).
 *
 * Freie Seite: Bei Endlosmaterial (lwMediaTracking=Continuous) oder lwLabelHeight=0 ist die
 * Etikettenlänge frei – angepasst wird nur die Breite (bei 90°/270° Drehung entsprechend die
 * Seitenhöhe).
 */

#ifndef LW_FIT_H
#define LW_FIT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "lw_options.h"

/** Ein Punkt ist Inhalt ⇔ L < LW_FIT_CONTENT_LEVEL. */
#define LW_FIT_CONTENT_LEVEL 250
/** Abweichung in 1/100 mm, ab der angepasst wird (> 2 mm). */
#define LW_FIT_TOLERANCE 200
/** Größte Etikettenseite in Punkten (ZPL ^LL). */
#define LW_FIT_MAX_DOTS 32000
/** Größte gültige Seitenseite in Punkten (1/72 Zoll). */
#define LW_FIT_MAX_PAGE_POINTS 100000.0

/** Zielgröße in Punkten der Seite; 0 = frei (keine Vorgabe). */
typedef struct lw_fit_plan {
    int width;
    int height;
} lw_fit_plan;

/** Punkte → 1/100 mm: floor(points * 2540.0 / 72.0 + 0.5); −1 bei ungültigem Wert
 *  (nicht 0 < points ≤ LW_FIT_MAX_PAGE_POINTS, auch NaN). */
long lw_fit_hundredths_mm(double points);

/**
 * Schritt F.1: Ist die Seite (`width` × `height` Punkte, Seitengröße in Punkten) anzupassen?
 * Liefert true und die Zielgröße in `plan` (Etikett in Seitenrichtung, bei R = 90/270 vertauscht).
 * false: keine Anpassung (Off, Etikett oder Seitengröße unbekannt, Größe passt, Auflösung 0 …).
 */
bool lw_fit_decide(const lw_settings *s, int width, int height, double page_w_pt, double page_h_pt,
                   int xdpi, int ydpi, lw_fit_plan *plan);

/** Schritt F.2: Rahmen der Punkte mit L < 250; false bei leerer Seite. */
bool lw_fit_content_bounds(const uint8_t *lum, int width, int height, int *x0, int *y0, int *bw, int *bh);

/** Schritt F.3: Zielgröße des Inhalts (nie größer als `bw` × `bh`, Seitenverhältnis erhalten). */
void lw_fit_target_size(int bw, int bh, const lw_fit_plan *plan, int *tw, int *th);

/**
 * Schritt F.4: Flächenmittel des Ausschnitts (x0, y0, bw, bh) eines Bildes mit Zeilenabstand
 * `stride` auf `tw` × `th` (tw ≤ bw, th ≤ bh) nach `dst` (Zeilenabstand `dst_stride`).
 * Liefert false bei Speichermangel (`dst` unverändert).
 */
bool lw_fit_area_average(const uint8_t *lum, size_t stride, int x0, int y0, int bw, int bh,
                         uint8_t *dst, size_t dst_stride, int tw, int th);

/**
 * Schritte F.2–F.5: legt das Bild auf das Etikett. `*out` erhält ein neues Bild (malloc,
 * `*out_w` × `*out_h`, Zeilenabstand `*out_w`). Liefert false bei Speichermangel.
 */
bool lw_fit_apply(const lw_fit_plan *plan, const uint8_t *lum, int width, int height,
                  uint8_t **out, int *out_w, int *out_h);

#endif /* LW_FIT_H */
