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
    return true;
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

/* Gerundete Höhe zur Breite `target_w` bzw. Breite zur Höhe `target_h` (mindestens 1). */
static int scaled_other(long long other, long long target, long long side)
{
    long long v = (2 * other * target + side) / (2 * side);
    return v < 1 ? 1 : (int)v;
}

void lw_fit_target_size(int bw, int bh, const lw_fit_plan *plan, int *tw, int *th)
{
    const long long W = plan->width, H = plan->height;
    *tw = bw;
    *th = bh;
    if (W > 0 && H > 0) {
        if (bw <= W && bh <= H)
            return;
        if (W * bh <= H * bw) {
            *tw = (int)W;
            *th = scaled_other(bh, W, bw);
        } else {
            *th = (int)H;
            *tw = scaled_other(bw, H, bh);
        }
    } else if (W > 0) {
        if (bw <= W)
            return;
        *tw = (int)W;
        *th = scaled_other(bh, W, bw);
    } else if (H > 0) {
        if (bh <= H)
            return;
        *th = (int)H;
        *tw = scaled_other(bw, H, bh);
    }
}

/* Überlappung der Quelle s (Einheiten [s·n_dst, (s+1)·n_dst)) mit dem Ziel d ([d·n_src, (d+1)·n_src)). */
static long long overlap(long long s, long long d, long long n_src, long long n_dst)
{
    long long lo = s * n_dst > d * n_src ? s * n_dst : d * n_src;
    long long hi = (s + 1) * n_dst < (d + 1) * n_src ? (s + 1) * n_dst : (d + 1) * n_src;
    return hi > lo ? hi - lo : 0;
}

bool lw_fit_area_average(const uint8_t *lum, size_t stride, int x0, int y0, int bw, int bh,
                         uint8_t *dst, size_t dst_stride, int tw, int th)
{
    if (tw == bw && th == bh) {   /* Faktor 1: Ausschnitt kopieren (identisch mit der Formel) */
        for (int y = 0; y < bh; y++)
            memcpy(dst + (size_t)y * dst_stride, lum + (size_t)(y0 + y) * stride + (size_t)x0, (size_t)bw);
        return true;
    }
    uint64_t *hsum = malloc(sizeof(uint64_t) * (size_t)tw);
    uint64_t *acc_cur = calloc((size_t)tw, sizeof(uint64_t));
    uint64_t *acc_next = calloc((size_t)tw, sizeof(uint64_t));
    if (hsum == NULL || acc_cur == NULL || acc_next == NULL) {
        free(hsum);
        free(acc_cur);
        free(acc_next);
        return false;
    }
    const uint64_t total = (uint64_t)bw * (uint64_t)bh;
    int cur = 0;   /* nächste auszugebende Zielzeile */
    for (int y = 0; y < bh; y++) {
        /* Waagerecht: Σx ax(X, x) · L(x0 + x, y0 + y) je Zielspalte X. */
        const uint8_t *row = lum + (size_t)(y0 + y) * stride + (size_t)x0;
        for (int X = 0; X < tw; X++) {
            long long first = (long long)X * bw / tw;
            long long last = ((long long)(X + 1) * bw - 1) / tw;
            uint64_t sum = 0;
            for (long long x = first; x <= last; x++)
                sum += (uint64_t)overlap(x, X, bw, tw) * row[x];
            hsum[X] = sum;
        }
        /* Senkrecht: Quellzeile y deckt [y·th, (y+1)·th) und trifft höchstens zwei Zielzeilen. */
        long long lo = (long long)y * th, hi = lo + th;
        long long ya = lo / bh, yb = (hi - 1) / bh;
        for (long long Y = ya; Y <= yb && Y < th; Y++) {
            uint64_t weight = (uint64_t)overlap(y, Y, bh, th);
            uint64_t *acc = Y == cur ? acc_cur : acc_next;
            for (int X = 0; X < tw; X++)
                acc[X] += weight * hsum[X];
        }
        /* Fertige Zielzeilen ausgeben (alle Quellanteile bis (cur + 1)·bh gesammelt). */
        while (cur < th && (long long)(cur + 1) * bh <= hi) {
            uint8_t *out = dst + (size_t)cur * dst_stride;
            for (int X = 0; X < tw; X++)
                out[X] = (uint8_t)((acc_cur[X] + total / 2) / total);
            uint64_t *swap = acc_cur;
            acc_cur = acc_next;
            acc_next = swap;
            memset(acc_next, 0, sizeof(uint64_t) * (size_t)tw);
            cur++;
        }
    }
    free(hsum);
    free(acc_cur);
    free(acc_next);
    return true;
}

bool lw_fit_apply(const lw_fit_plan *plan, const uint8_t *lum, int width, int height,
                  uint8_t **out, int *out_w, int *out_h)
{
    int x0 = 0, y0 = 0, bw = 0, bh = 0, tw = 1, th = 1;
    bool content = lw_fit_content_bounds(lum, width, height, &x0, &y0, &bw, &bh);
    if (content)
        lw_fit_target_size(bw, bh, plan, &tw, &th);
    /* Leere Seite: weißes Etikett, freie Seite 1 Punkt. */
    int canvas_w = plan->width > 0 ? plan->width : tw;
    int canvas_h = plan->height > 0 ? plan->height : th;
    size_t size = (size_t)canvas_w * (size_t)canvas_h;
    uint8_t *canvas = malloc(size > 0 ? size : 1);
    if (canvas == NULL)
        return false;
    memset(canvas, 255, size);
    if (content) {
        size_t ox = (size_t)((canvas_w - tw) / 2), oy = (size_t)((canvas_h - th) / 2);
        if (!lw_fit_area_average(lum, (size_t)width, x0, y0, bw, bh, canvas + oy * (size_t)canvas_w + ox,
                                 (size_t)canvas_w, tw, th)) {
            free(canvas);
            return false;
        }
    }
    *out = canvas;
    *out_w = canvas_w;
    *out_h = canvas_h;
    return true;
}
