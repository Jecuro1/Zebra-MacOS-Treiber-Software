/*
 * lw_fit.c – „An Etikett anpassen“ (ARCHITECTURE.md §8 „F“).
 */

#if !defined(__APPLE__) && !defined(_DEFAULT_SOURCE)
#  define _DEFAULT_SOURCE 1
#endif

#include "lw_fit.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

long lw_fit_hundredths_mm(double points)
{
    if (!(points > 0.0 && points <= LW_FIT_MAX_PAGE_POINTS))
        return -1;
    /* Genau diese Reihenfolge (Multiplikation, Division, Addition) in double – wie Swift/Python. */
    return (long)floor(points * 2540.0 / 72.0 + 0.5);
}

int lw_fit_margin(int dpi)
{
    return (int)(((long long)LW_FIT_MARGIN * dpi + 1270) / 2540);
}

static long long labs_ll(long long v)
{
    return v < 0 ? -v : v;
}

bool lw_fit_decide(const lw_settings *s, int width, int height, double page_w_pt, double page_h_pt,
                   int xdpi, int ydpi, lw_fit_plan *plan)
{
    if (s->fit_to_label != LW_FIT_AUTO || s->label_width <= 0 || width <= 0 || height <= 0)
        return false;
    long page_w = lw_fit_hundredths_mm(page_w_pt);
    long page_h = lw_fit_hundredths_mm(page_h_pt);
    if (page_w < 0 || page_h < 0)
        return false;
    /* Endlosmaterial bzw. unbekannte Länge: Länge frei (0). */
    long long length = s->tracking == LW_TRACKING_CONTINUOUS ? 0 : s->label_height;
    long long cw, ch;
    int rotation = lw_settings_effective_rotation(s);
    if (rotation == 90 || rotation == 270) {
        cw = length;              /* Seite liegt quer: Breite = Etikettenlänge */
        ch = s->label_width;
    } else {
        cw = s->label_width;
        ch = length;
    }
    bool differs = (cw > 0 && labs_ll((long long)page_w - cw) > LW_FIT_TOLERANCE) ||
                   (ch > 0 && labs_ll((long long)page_h - ch) > LW_FIT_TOLERANCE);
    if (!differs || xdpi <= 0 || ydpi <= 0)
        return false;
    long long tw = cw > 0 ? (cw * xdpi + 1270) / 2540 : 0;
    long long th = ch > 0 ? (ch * ydpi + 1270) / 2540 : 0;
    if ((cw > 0 && (tw < 1 || tw > LW_FIT_MAX_DOTS)) || (ch > 0 && (th < 1 || th > LW_FIT_MAX_DOTS)))
        return false;
    plan->width = (int)tw;
    plan->height = (int)th;
    plan->margin_x = lw_fit_margin(xdpi);
    plan->margin_y = lw_fit_margin(ydpi);
    plan->page_w = page_w;
    plan->page_h = page_h;
    return true;
}

void lw_fit_reference_init(lw_fit_reference *ref)
{
    memset(ref, 0, sizeof(*ref));
    ref->valid = false;
}

bool lw_fit_reference_applies(const lw_fit_reference *ref, const lw_fit_plan *plan)
{
    if (ref == NULL || !ref->valid)
        return false;
    const lw_fit_plan *r = &ref->plan;
    return r->width == plan->width && r->height == plan->height && r->margin_x == plan->margin_x &&
           r->margin_y == plan->margin_y && labs_ll((long long)plan->page_w - r->page_w) <= LW_FIT_TOLERANCE &&
           labs_ll((long long)plan->page_h - r->page_h) <= LW_FIT_TOLERANCE;
}

bool lw_fit_content_bounds(const uint8_t *lum, int width, int height, int *x0, int *y0, int *bw, int *bh)
{
    int left = width, right = -1, top = -1, bottom = -1;
    for (int y = 0; y < height; y++) {
        const uint8_t *row = lum + (size_t)y * (size_t)width;
        int first = -1;
        for (int x = 0; x < width; x++) {
            if (row[x] < LW_FIT_CONTENT_LEVEL) {
                first = x;
                break;
            }
        }
        if (first < 0)
            continue;
        int last = first;
        for (int x = width - 1; x > first; x--) {
            if (row[x] < LW_FIT_CONTENT_LEVEL) {
                last = x;
                break;
            }
        }
        if (top < 0)
            top = y;
        bottom = y;
        if (first < left)
            left = first;
        if (last > right)
            right = last;
    }
    if (top < 0)
        return false;
    *x0 = left;
    *y0 = top;
    *bw = right - left + 1;
    *bh = bottom - top + 1;
    return true;
}

/* Feste Etikettenseite abzüglich Rand auf beiden Seiten (zu klein → ganze Seite). */
static long long inner_side(long long side, long long margin)
{
    long long inner = side - 2 * margin;
    return inner >= 1 ? inner : side;
}

void lw_fit_box(const lw_fit_plan *plan, int rw, int rh, long long *box_w, long long *box_h)
{
    /* Freie Seite = Inhalt: entlang einer freien Seite wird nie vergrößert (die Länge folgt dem Inhalt). */
    *box_w = plan->width > 0 ? inner_side(plan->width, plan->margin_x) : rw;
    *box_h = plan->height > 0 ? inner_side(plan->height, plan->margin_y) : rh;
}

int lw_fit_rotation(const lw_fit_plan *plan, int bw, int bh)
{
    if (plan->width <= 0 || plan->height <= 0)
        return LW_FIT_TURN_NONE;
    long long iw, ih;
    lw_fit_box(plan, bw, bh, &iw, &ih);
    /* s90 > 1,1 · s0 ⇔ (Inhalt hoch ∧ Etikett quer) ∨ (Inhalt quer ∧ Etikett hoch), jeweils um
     * mehr als 10 % (§8 F.3). */
    if (10LL * bh > 11LL * bw && 10 * iw > 11 * ih)
        return LW_FIT_TURN_CW;
    if (10LL * bw > 11LL * bh && 10 * ih > 11 * iw)
        return LW_FIT_TURN_CCW;
    return LW_FIT_TURN_NONE;
}

void lw_fit_rotate(const uint8_t *lum, size_t stride, int x0, int y0, int bw, int bh, int turn, uint8_t *dst)
{
    const size_t out_w = (size_t)bh;
    for (int y = 0; y < bh; y++) {
        const uint8_t *row = lum + (size_t)(y0 + y) * stride + (size_t)x0;
        if (turn == LW_FIT_TURN_CW) {
            /* (x, y) → (bh − 1 − y, x) */
            uint8_t *col = dst + (size_t)(bh - 1 - y);
            for (int x = 0; x < bw; x++)
                col[(size_t)x * out_w] = row[x];
        } else {
            /* (x, y) → (y, bw − 1 − x) */
            uint8_t *col = dst + (size_t)y;
            for (int x = 0; x < bw; x++)
                col[(size_t)(bw - 1 - x) * out_w] = row[x];
        }
    }
}

void lw_fit_scale(int rw, int rh, const lw_fit_plan *plan, long long *num, long long *den)
{
    long long bw_box, bh_box;
    lw_fit_box(plan, rw, rh, &bw_box, &bh_box);
    if (bw_box * rh <= bh_box * rw) {
        *num = bw_box;
        *den = rw;
    } else {
        *num = bh_box;
        *den = rh;
    }
}

/* Gerundete Seite `side` · num / den (mindestens 1). */
static int scaled_side(long long side, long long num, long long den)
{
    long long v = (2 * side * num + den) / (2 * den);
    return v < 1 ? 1 : (int)v;
}

void lw_fit_scaled_size(int rw, int rh, long long num, long long den, int *tw, int *th)
{
    *tw = scaled_side(rw, num, den);
    *th = scaled_side(rh, num, den);
}

void lw_fit_target_size(int rw, int rh, const lw_fit_plan *plan, int *tw, int *th)
{
    /* Mit dem eigenen Maßstab füllt die begrenzende Seite den Rahmen genau: (2·rw·BW + rw)/(2·rw) = BW. */
    long long num, den;
    lw_fit_scale(rw, rh, plan, &num, &den);
    lw_fit_scaled_size(rw, rh, num, den, tw, th);
}

/* Überlappung der Quelle s (Einheiten [s·n_dst, (s+1)·n_dst)) mit dem Ziel d ([d·n_src, (d+1)·n_src)). */
static long long overlap(long long s, long long d, long long n_src, long long n_dst)
{
    long long lo = s * n_dst > d * n_src ? s * n_dst : d * n_src;
    long long hi = (s + 1) * n_dst < (d + 1) * n_src ? (s + 1) * n_dst : (d + 1) * n_src;
    return hi > lo ? hi - lo : 0;
}

/* Σx ax(X, x) · L(x) je Zielspalte X einer Quellzeile. */
static void horizontal_sums(const uint8_t *row, int bw, int tw, uint64_t *sums)
{
    for (int X = 0; X < tw; X++) {
        long long first = (long long)X * bw / tw;
        long long last = ((long long)(X + 1) * bw - 1) / tw;
        uint64_t sum = 0;
        for (long long x = first; x <= last; x++)
            sum += (uint64_t)overlap(x, X, bw, tw) * row[x];
        sums[X] = sum;
    }
}

bool lw_fit_area_average(const uint8_t *lum, size_t stride, int x0, int y0, int bw, int bh,
                         uint8_t *dst, size_t dst_stride, int tw, int th)
{
    if (tw == bw && th == bh) {   /* Faktor 1: Ausschnitt kopieren (identisch mit der Formel) */
        for (int y = 0; y < bh; y++)
            memcpy(dst + (size_t)y * dst_stride, lum + (size_t)(y0 + y) * stride + (size_t)x0, (size_t)bw);
        return true;
    }
    uint64_t *acc = malloc(sizeof(uint64_t) * (size_t)tw);
    uint64_t *cached = malloc(sizeof(uint64_t) * (size_t)tw);
    uint64_t *fresh = malloc(sizeof(uint64_t) * (size_t)tw);
    if (acc == NULL || cached == NULL || fresh == NULL) {
        free(acc);
        free(cached);
        free(fresh);
        return false;
    }
    const uint64_t total = (uint64_t)bw * (uint64_t)bh;
    long long cached_row = -1;   /* Quellzeile, deren Summen in `cached` stehen */
    for (int Y = 0; Y < th; Y++) {
        /* Zielzeile Y deckt [Y·bh, (Y+1)·bh), Quellzeile y deckt [y·th, (y+1)·th). Aufeinander-
         * folgende Zielzeilen teilen höchstens eine Quellzeile (die letzte der vorigen) – beim
         * Vergrößern oft dieselbe; sie wird aus `cached` wiederverwendet. */
        long long ya = (long long)Y * bh / th;
        long long yb = ((long long)(Y + 1) * bh - 1) / th;
        memset(acc, 0, sizeof(uint64_t) * (size_t)tw);
        for (long long y = ya; y <= yb; y++) {
            uint64_t *sums = cached;
            if (y != cached_row) {
                horizontal_sums(lum + (size_t)(y0 + y) * stride + (size_t)x0, bw, tw, fresh);
                sums = fresh;
            }
            const uint64_t weight = (uint64_t)overlap(y, Y, bh, th);
            for (int X = 0; X < tw; X++)
                acc[X] += weight * sums[X];
            if (y == yb && sums == fresh) {
                fresh = cached;
                cached = sums;
                cached_row = y;
            }
        }
        uint8_t *out = dst + (size_t)Y * dst_stride;
        for (int X = 0; X < tw; X++)
            out[X] = (uint8_t)((acc[X] + total / 2) / total);
    }
    free(acc);
    free(cached);
    free(fresh);
    return true;
}

bool lw_fit_apply(const lw_fit_plan *plan, lw_fit_reference *ref, const uint8_t *lum, int width, int height,
                  uint8_t **out, int *out_w, int *out_h, int *turn)
{
    int x0 = 0, y0 = 0, bw = 0, bh = 0, tw = 1, th = 1;
    int rotation = LW_FIT_TURN_NONE;
    long long num = 1, den = 1;
    const uint8_t *source = lum;
    size_t source_stride = (size_t)width;
    uint8_t *rotated = NULL;
    bool content = lw_fit_content_bounds(lum, width, height, &x0, &y0, &bw, &bh);
    const bool applies = content && lw_fit_reference_applies(ref, plan);
    if (content) {
        /* Gilt die Referenz, dreht die Seite wie sie (auch wenn ihr eigener Inhalt es nicht zeigt). */
        rotation = applies ? ref->turn : lw_fit_rotation(plan, bw, bh);
        if (rotation != LW_FIT_TURN_NONE) {
            /* Ausschnitt gedreht puffern (bh × bw), dann wie einen ungedrehten Inhalt skalieren. */
            rotated = malloc((size_t)bw * (size_t)bh);
            if (rotated == NULL)
                return false;
            lw_fit_rotate(lum, (size_t)width, x0, y0, bw, bh, rotation, rotated);
            source = rotated;
            source_stride = (size_t)bh;
            x0 = y0 = 0;
            int swap = bw;
            bw = bh;
            bh = swap;
        }
        /* Maßstab: eigener; mit Referenz deren, solange der Inhalt damit in den Rahmen passt
         * (s_R ≤ s_p ⇔ num_R · den_p ≤ num_p · den_R). */
        lw_fit_scale(bw, bh, plan, &num, &den);
        if (applies && ref->scale_num * den <= num * ref->scale_den) {
            num = ref->scale_num;
            den = ref->scale_den;
        }
        lw_fit_scaled_size(bw, bh, num, den, &tw, &th);
    }
    /* Leere Seite: weißes Etikett, freie Seite 1 Punkt. */
    int canvas_w = plan->width > 0 ? plan->width : tw;
    int canvas_h = plan->height > 0 ? plan->height : th;
    size_t size = (size_t)canvas_w * (size_t)canvas_h;
    uint8_t *canvas = malloc(size > 0 ? size : 1);
    if (canvas == NULL) {
        free(rotated);
        return false;
    }
    memset(canvas, 255, size);
    if (content) {
        size_t ox = (size_t)((canvas_w - tw) / 2), oy = (size_t)((canvas_h - th) / 2);
        if (!lw_fit_area_average(source, source_stride, x0, y0, bw, bh, canvas + oy * (size_t)canvas_w + ox,
                                 (size_t)canvas_w, tw, th)) {
            free(rotated);
            free(canvas);
            return false;
        }
    }
    free(rotated);
    if (content && ref != NULL && !applies) {
        /* Keine passende Referenz: Diese Seite wird die Referenz für die folgenden. */
        ref->valid = true;
        ref->plan = *plan;
        ref->turn = rotation;
        ref->scale_num = num;
        ref->scale_den = den;
    }
    *out = canvas;
    *out_w = canvas_w;
    *out_h = canvas_h;
    if (turn != NULL)
        *turn = rotation;
    return true;
}
