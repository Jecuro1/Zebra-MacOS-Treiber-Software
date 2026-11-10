/*
 * mkraster – erzeugt CUPS-Rasterdateien mit frei wählbaren Kopfdaten für die End-to-End-Tests.
 *
 * Aufruf:
 *     mkraster -o AUSGABE [-m native|compressed|pwg] [-d ROHDATEN] SEITE [SEITE …]
 *
 * SEITE ist eine Liste key=value, durch Kommas getrennt:
 *     w=<cupsWidth>  h=<cupsHeight>  bpc=<1|2|4|8|16>
 *     cs=<W|SW|K|RGB|SRGB|ADOBERGB|RGBA|CMY|YMC|CMYK|YMCK|KCMY|CIELAB|ICC3|Zahl>
 *     order=<chunky|banded|planar>  res=<dpi> (oder xres=/yres=)
 *     bpp=<Bits je Pixel, Standard Kanäle × bpc>  bpl=<Bytes je Zeile, Standard minimal>
 *     (libcups ≥ 2.3 akzeptiert nur exakte Werte; abweichende Werte nur mit raw=1 sinnvoll)
 *     pattern=<gradient|hgrad|vgrad|text|checker|noise|blank|black|bars|dots>  seed=<n>
 *     bx=<x> by=<y> bw=<b> bh=<h>  Muster nur in diesem Rechteck, außerhalb weiß (z. B. ein kleines
 *             Etikett in der Ecke einer A4-Seite)
 *     pw=<Punkte> ph=<Punkte>  Seitengröße (cupsPageSize, float; PageSize gerundet). Standard:
 *             w · 72 / xres bzw. h · 72 / yres (ganzzahlig, wie bisher)
 *     cps=0   cupsPageSize nicht setzen (0) – der Filter nimmt dann PageSize
 *     raw=1   Kopf und Daten ohne libcups-Prüfung direkt schreiben (nur -m native; erlaubt
 *             z. B. Seiten mit Höhe 0)
 *     truncate=<n>  nur die ersten n Zeilen schreiben (unvollständiger Datenstrom; nur letzte Seite)
 *
 * Die Bytes, die je Seite an cupsRasterWritePixels übergeben werden, werden zusätzlich
 * unverändert in ROHDATEN geschrieben (16-Bit-Werte in Host-Byte-Reihenfolge – genau so, wie
 * cupsRasterReadPixels sie dem Filter liefert). Auf stdout erscheint je Seite eine JSON-Zeile mit
 * den Kopfdaten und der Lage der Rohdaten, damit der Python-Referenz-Encoder die Luminanz
 * unabhängig berechnen kann. Die letzte Zeile {"readable_pages": n} nennt, wie viele Seiten die
 * installierte libcups beim Lesen vollständig liefert (Gegenprobe; libcups beendet den
 * Datenstrom je nach Version an ungültigen Köpfen). Dieselbe Zeile nennt in "page_sizes" je gelesener
 * Seite die Seitengröße [Breite, Höhe] in Punkten, wie der Filter sie verwendet: cupsPageSize, wenn
 * beide > 0, sonst PageSize (§8 „F“; Zahlen mit %.17g, also exakt).
 *
 * Füllkanäle (z. B. bei 1-Bit-RGB mit bpp=4) und Füllbytes am Zeilenende werden bewusst mit
 * Einsen bzw. 0xA5 belegt: Der Filter muss sie ignorieren. Bittiefen außer 1/2/4/8/16 erzeugen
 * nur den Kopf (Pixeldaten bleiben 0) – für Fehlertests.
 */

#if !defined(__APPLE__) && !defined(_DEFAULT_SOURCE)
#  define _DEFAULT_SOURCE 1
#endif

#include <cups/raster.h>

#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct page_spec {
    unsigned width, height, bpc, bpp, bpl;
    int color_space;
    int order;
    unsigned xres, yres;
    char pattern[32];
    int pattern_id;
    unsigned seed;
    int raw;
    long truncate_rows;   /* < 0: alle Zeilen */
    unsigned box_x, box_y, box_w, box_h;   /* box_w/box_h 0 = ganze Seite */
    double page_w, page_h;                 /* Punkte; < 0 = aus w/h und Auflösung */
    int cups_page_size;                    /* 0 = cupsPageSize leer lassen */
} page_spec;

static void die(const char *msg)
{
    fprintf(stderr, "mkraster: %s\n", msg);
    exit(2);
}

static int channels_for(int cs)
{
    switch (cs) {
    case CUPS_CSPACE_W: case CUPS_CSPACE_SW: case CUPS_CSPACE_K:
        return 1;
    case CUPS_CSPACE_RGB: case CUPS_CSPACE_SRGB: case CUPS_CSPACE_ADOBERGB:
    case CUPS_CSPACE_CMY: case CUPS_CSPACE_YMC: case CUPS_CSPACE_CIELab: case CUPS_CSPACE_ICC3:
        return 3;
    case CUPS_CSPACE_RGBA: case CUPS_CSPACE_CMYK: case CUPS_CSPACE_YMCK: case CUPS_CSPACE_KCMY:
        return 4;
    default:
        return 1;
    }
}

static int parse_color_space(const char *v)
{
    static const struct { const char *name; int cs; } table[] = {
        { "W", CUPS_CSPACE_W }, { "SW", CUPS_CSPACE_SW }, { "K", CUPS_CSPACE_K },
        { "RGB", CUPS_CSPACE_RGB }, { "SRGB", CUPS_CSPACE_SRGB }, { "ADOBERGB", CUPS_CSPACE_ADOBERGB },
        { "RGBA", CUPS_CSPACE_RGBA }, { "CMY", CUPS_CSPACE_CMY }, { "YMC", CUPS_CSPACE_YMC },
        { "CMYK", CUPS_CSPACE_CMYK }, { "YMCK", CUPS_CSPACE_YMCK }, { "KCMY", CUPS_CSPACE_KCMY },
        { "CIELAB", CUPS_CSPACE_CIELab }, { "ICC3", CUPS_CSPACE_ICC3 },
    };
    for (size_t i = 0; i < sizeof(table) / sizeof(table[0]); i++)
        if (strcmp(v, table[i].name) == 0)
            return table[i].cs;
    char *end = NULL;
    long n = strtol(v, &end, 10);
    if (end == v || *end != '\0' || n < 0)
        die("unbekannter Farbraum");
    return (int)n;
}

static double parse_points(const char *v)
{
    char *end = NULL;
    double n = strtod(v, &end);
    if (end == v || *end != '\0' || !(n >= 0.0))
        die("ungültige Seitengröße");
    return n;
}

static unsigned parse_unsigned(const char *v)
{
    char *end = NULL;
    unsigned long n = strtoul(v, &end, 10);
    if (end == v || *end != '\0')
        die("ungültige Zahl");
    return (unsigned)n;
}

static int pattern_id(const char *name);

static void parse_page(const char *arg, page_spec *p)
{
    memset(p, 0, sizeof(*p));
    p->width = 64;
    p->height = 32;
    p->bpc = 8;
    p->color_space = CUPS_CSPACE_SW;
    p->order = CUPS_ORDER_CHUNKED;
    p->xres = p->yres = 203;
    strcpy(p->pattern, "gradient");
    p->truncate_rows = -1;
    p->page_w = p->page_h = -1.0;
    p->cups_page_size = 1;

    char *copy = strdup(arg);
    if (copy == NULL)
        die("kein Speicher");
    for (char *tok = strtok(copy, ","); tok != NULL; tok = strtok(NULL, ",")) {
        char *eq = strchr(tok, '=');
        if (eq == NULL)
            die("Seitenangabe erwartet key=value");
        *eq = '\0';
        const char *k = tok, *v = eq + 1;
        if (strcmp(k, "w") == 0) p->width = parse_unsigned(v);
        else if (strcmp(k, "h") == 0) p->height = parse_unsigned(v);
        else if (strcmp(k, "bpc") == 0) p->bpc = parse_unsigned(v);
        else if (strcmp(k, "bpp") == 0) p->bpp = parse_unsigned(v);
        else if (strcmp(k, "bpl") == 0) p->bpl = parse_unsigned(v);
        else if (strcmp(k, "cs") == 0) p->color_space = parse_color_space(v);
        else if (strcmp(k, "order") == 0) {
            if (strcmp(v, "chunky") == 0) p->order = CUPS_ORDER_CHUNKED;
            else if (strcmp(v, "banded") == 0) p->order = CUPS_ORDER_BANDED;
            else if (strcmp(v, "planar") == 0) p->order = CUPS_ORDER_PLANAR;
            else die("unbekannte Anordnung");
        }
        else if (strcmp(k, "res") == 0) p->xres = p->yres = parse_unsigned(v);
        else if (strcmp(k, "xres") == 0) p->xres = parse_unsigned(v);
        else if (strcmp(k, "yres") == 0) p->yres = parse_unsigned(v);
        else if (strcmp(k, "pattern") == 0) {
            if (strlen(v) >= sizeof(p->pattern)) die("Mustername zu lang");
            strcpy(p->pattern, v);
        }
        else if (strcmp(k, "seed") == 0) p->seed = parse_unsigned(v);
        else if (strcmp(k, "raw") == 0) p->raw = (int)parse_unsigned(v);
        else if (strcmp(k, "truncate") == 0) p->truncate_rows = (long)parse_unsigned(v);
        else if (strcmp(k, "bx") == 0) p->box_x = parse_unsigned(v);
        else if (strcmp(k, "by") == 0) p->box_y = parse_unsigned(v);
        else if (strcmp(k, "bw") == 0) p->box_w = parse_unsigned(v);
        else if (strcmp(k, "bh") == 0) p->box_h = parse_unsigned(v);
        else if (strcmp(k, "pw") == 0) p->page_w = parse_points(v);
        else if (strcmp(k, "ph") == 0) p->page_h = parse_points(v);
        else if (strcmp(k, "cps") == 0) p->cups_page_size = (int)parse_unsigned(v);
        else die("unbekannter Schlüssel in Seitenangabe");
    }
    free(copy);
    p->pattern_id = pattern_id(p->pattern);
}

/* ---- Muster: liefert einen 16-Bit-„Helligkeitswert“ (0 = schwarz) ------------------------ */

enum { PAT_GRADIENT, PAT_HGRAD, PAT_VGRAD, PAT_CHECKER, PAT_NOISE, PAT_BLANK, PAT_BLACK, PAT_BARS,
       PAT_DOTS, PAT_TEXT };

static int pattern_id(const char *name)
{
    static const char *names[] = { "gradient", "hgrad", "vgrad", "checker", "noise", "blank",
                                   "black", "bars", "dots", "text" };
    for (int i = 0; i < (int)(sizeof(names) / sizeof(names[0])); i++)
        if (strcmp(name, names[i]) == 0)
            return i;
    die("unbekanntes Muster");
    return 0;
}

static uint32_t hash32(uint32_t x)
{
    x ^= x >> 16;
    x *= 0x7feb352dU;
    x ^= x >> 15;
    x *= 0x846ca68bU;
    x ^= x >> 16;
    return x;
}

static unsigned pattern_value_full(const page_spec *p, unsigned x, unsigned y);

/* Muster, außerhalb des Rechtecks bx/by/bw/bh weiß (Koordinaten des Musters relativ zum Rechteck). */
static unsigned pattern_value(const page_spec *p, unsigned x, unsigned y)
{
    if (p->box_w == 0 || p->box_h == 0)
        return pattern_value_full(p, x, y);
    if (x < p->box_x || y < p->box_y || x - p->box_x >= p->box_w || y - p->box_y >= p->box_h)
        return 65535;
    page_spec inner = *p;
    inner.width = p->box_w;
    inner.height = p->box_h;
    return pattern_value_full(&inner, x - p->box_x, y - p->box_y);
}

static unsigned pattern_value_full(const page_spec *p, unsigned x, unsigned y)
{
    const unsigned w = p->width > 1 ? p->width - 1 : 1;
    const unsigned h = p->height > 1 ? p->height - 1 : 1;
    switch (p->pattern_id) {
    case PAT_GRADIENT:
        return (unsigned)(((uint64_t)x * 65535 / w + (uint64_t)y * 65535 / h) / 2);
    case PAT_HGRAD:
        return (unsigned)((uint64_t)x * 65535 / w);
    case PAT_VGRAD:
        return (unsigned)((uint64_t)y * 65535 / h);
    case PAT_CHECKER:
        return (((x / 8) + (y / 8)) & 1) ? 0 : 65535;
    case PAT_NOISE:
        return hash32(x * 7919u + y * 104729u + p->seed * 31337u) & 0xFFFFu;
    case PAT_BLANK:
        return 65535;
    case PAT_BLACK:
        return 0;
    case PAT_BARS:
        return ((x / 3) & 1) || (y % 40) < 4 ? 0 : 65535;
    case PAT_DOTS:
        return (x % 17 == 5 && y % 13 == 7) ? 0 : 65535;
    default:
        break;
    }
    {
        /* Textähnliche Zeilen: Zeichenzellen 12×20 mit zufälligen Strichen, kantengeglättet. */
        unsigned line = y / 24, ry = y % 24;
        unsigned cell = x / 12, rx = x % 12;
        if (ry >= 20 || rx >= 10 || (x < 8) || (line % 5 == 4))
            return 65535;
        uint32_t hv = hash32(line * 977u + cell * 131u + p->seed);
        if ((hv & 7) == 0)
            return 65535;   /* Leerzeichen */
        bool stroke = false;
        if ((hv >> 3) & 1) stroke |= rx < 2;                 /* linker Strich */
        if ((hv >> 4) & 1) stroke |= rx >= 8;                /* rechter Strich */
        if ((hv >> 5) & 1) stroke |= ry < 2;                 /* oben */
        if ((hv >> 6) & 1) stroke |= ry >= 9 && ry < 11;     /* Mitte */
        if ((hv >> 7) & 1) stroke |= ry >= 18;               /* unten */
        if ((hv >> 8) & 1) stroke |= rx == ry / 2;           /* Diagonale */
        if (stroke)
            return (hv >> 9) & 1 ? 0 : 9000;
        /* Kantenglättung neben Strichen */
        return ((rx == 2 || rx == 7) && ((hv >> 3) & 3)) ? 40000 : 65535;
    }
}

/* Kanalwerte (16 Bit) für einen Pixel. */
static void channel_values(const page_spec *p, unsigned x, unsigned y, unsigned out[4])
{
    unsigned g = pattern_value(p, x, y);
    unsigned ink = 65535u - g;
    switch (p->color_space) {
    case CUPS_CSPACE_K:
        out[0] = ink;
        break;
    case CUPS_CSPACE_RGB: case CUPS_CSPACE_SRGB: case CUPS_CSPACE_ADOBERGB:
    case CUPS_CSPACE_CIELab: case CUPS_CSPACE_ICC3:
        out[0] = g;
        out[1] = (g * 3u + x * 257u) & 0xFFFFu;
        out[2] = (65535u - g + y * 513u) & 0xFFFFu;
        break;
    case CUPS_CSPACE_RGBA:
        out[0] = g;
        out[1] = (g + x * 97u) & 0xFFFFu;
        out[2] = g;
        out[3] = (x % 7 == 0) ? 0x8000u : ((y % 11 == 0) ? 0u : 0xFFFFu);
        break;
    case CUPS_CSPACE_CMY: case CUPS_CSPACE_YMC:
        out[0] = ink;
        out[1] = (ink + x * 131u) & 0xFFFFu;
        out[2] = (ink / 2u + y * 77u) & 0xFFFFu;
        break;
    case CUPS_CSPACE_CMYK: case CUPS_CSPACE_YMCK: case CUPS_CSPACE_KCMY: {
        unsigned k = ink > 32768u ? (ink - 32768u) * 2u : 0u;
        unsigned c = (ink + x * 61u) & 0xFFFFu;
        unsigned m = ink / 2u;
        unsigned yy = (ink / 3u + y * 29u) & 0xFFFFu;
        if (p->color_space == CUPS_CSPACE_CMYK) { out[0] = c; out[1] = m; out[2] = yy; out[3] = k; }
        else if (p->color_space == CUPS_CSPACE_YMCK) { out[0] = yy; out[1] = m; out[2] = c; out[3] = k; }
        else { out[0] = k; out[1] = c; out[2] = m; out[3] = yy; }
        break;
    }
    default:   /* W, SW und unbekannte einkanalige Räume */
        out[0] = g;
        break;
    }
}

static unsigned quantize(unsigned v16, unsigned bpc)
{
    return bpc >= 16 ? v16 : v16 >> (16 - bpc);
}

/* Schreibt `value` (bpc Bit) an Bitposition `bit` (MSB zuerst); 16 Bit in Host-Reihenfolge. */
static void put_bits(uint8_t *line, uint64_t bit, unsigned bpc, unsigned value)
{
    if (bpc == 16) {
        uint16_t v = (uint16_t)value;
        memcpy(line + (bit >> 3), &v, 2);
    } else if (bpc == 8) {
        line[bit >> 3] = (uint8_t)value;
    } else {
        unsigned shift = 8 - bpc - (unsigned)(bit & 7);
        unsigned mask = ((1u << bpc) - 1u) << shift;
        line[bit >> 3] = (uint8_t)((line[bit >> 3] & ~mask) | ((value << shift) & mask));
    }
}

int main(int argc, char *argv[])
{
    const char *out_path = NULL, *dump_path = NULL;
    cups_mode_t mode = CUPS_RASTER_WRITE;
    int first_page = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-o") == 0 && i + 1 < argc) out_path = argv[++i];
        else if (strcmp(argv[i], "-d") == 0 && i + 1 < argc) dump_path = argv[++i];
        else if (strcmp(argv[i], "-m") == 0 && i + 1 < argc) {
            const char *m = argv[++i];
            if (strcmp(m, "native") == 0) mode = CUPS_RASTER_WRITE;
            else if (strcmp(m, "compressed") == 0) mode = CUPS_RASTER_WRITE_COMPRESSED;
            else if (strcmp(m, "pwg") == 0) mode = CUPS_RASTER_WRITE_PWG;
            else die("unbekannter Modus");
        } else {
            first_page = i;
            break;
        }
    }
    if (out_path == NULL || first_page == 0)
        die("Aufruf: mkraster -o AUSGABE [-m native|compressed|pwg] [-d ROHDATEN] SEITE …");

    int fd = open(out_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0)
        die("Ausgabedatei kann nicht angelegt werden");
    FILE *dump = NULL;
    if (dump_path != NULL && (dump = fopen(dump_path, "wb")) == NULL)
        die("Rohdatendatei kann nicht angelegt werden");
    cups_raster_t *ras = cupsRasterOpen(fd, mode);
    if (ras == NULL)
        die("cupsRasterOpen fehlgeschlagen");

    long dump_offset = 0;
    for (int a = first_page; a < argc; a++) {
        page_spec p;
        parse_page(argv[a], &p);
        int channels = channels_for(p.color_space);
        unsigned bpc = p.bpc;
        unsigned bpp = p.bpp;
        if (bpp == 0) {
            /* libcups ≥ 2.3 verlangt bei chunky genau Kanäle × Bittiefe (ohne Füllkanal);
             * ältere Erzeuger nutzten bei 3 Kanälen < 8 Bit 4 Plätze (bpp=… explizit angeben). */
            if (p.order != CUPS_ORDER_CHUNKED || channels == 1)
                bpp = bpc;
            else
                bpp = bpc * (unsigned)channels;
        }
        const bool writable_depth = bpc == 1 || bpc == 2 || bpc == 4 || bpc == 8 || bpc == 16;
        unsigned band = (unsigned)(((uint64_t)p.width * bpc + 7) / 8);
        unsigned min_bpl;
        if (p.order == CUPS_ORDER_BANDED && channels > 1)
            min_bpl = band * (unsigned)channels;
        else if (p.order == CUPS_ORDER_PLANAR && channels > 1)
            min_bpl = band;
        else
            min_bpl = (unsigned)(((uint64_t)p.width * bpp + 7) / 8);
        unsigned bpl = p.bpl != 0 ? p.bpl : min_bpl;

        cups_page_header2_t h;
        memset(&h, 0, sizeof(h));
        strcpy(h.MediaClass, "PwgRaster");
        h.HWResolution[0] = p.xres;
        h.HWResolution[1] = p.yres;
        h.cupsWidth = p.width;
        h.cupsHeight = p.height;
        h.cupsBitsPerColor = bpc;
        h.cupsBitsPerPixel = bpp;
        h.cupsBytesPerLine = bpl;
        h.cupsColorOrder = (cups_order_t)p.order;
        h.cupsColorSpace = (cups_cspace_t)p.color_space;
        h.cupsNumColors = (unsigned)channels;
        h.NumCopies = 1;
        h.PageSize[0] = p.xres ? p.width * 72 / p.xres : 0;
        h.PageSize[1] = p.yres ? p.height * 72 / p.yres : 0;
        h.cupsPageSize[0] = (float)h.PageSize[0];
        h.cupsPageSize[1] = (float)h.PageSize[1];
        if (p.page_w >= 0.0) {
            h.cupsPageSize[0] = (float)p.page_w;
            h.PageSize[0] = (unsigned)(p.page_w + 0.5);
        }
        if (p.page_h >= 0.0) {
            h.cupsPageSize[1] = (float)p.page_h;
            h.PageSize[1] = (unsigned)(p.page_h + 0.5);
        }
        if (!p.cups_page_size)
            h.cupsPageSize[0] = h.cupsPageSize[1] = 0.0f;
        h.ImagingBoundingBox[2] = h.PageSize[0];
        h.ImagingBoundingBox[3] = h.PageSize[1];

        if (p.raw) {
            if (mode != CUPS_RASTER_WRITE)
                die("raw=1 nur mit -m native");
            if (write(fd, &h, sizeof(h)) != (ssize_t)sizeof(h))
                die("Schreiben fehlgeschlagen");
        } else if (!cupsRasterWriteHeader2(ras, &h)) {
            die("cupsRasterWriteHeader2 hat den Seitenkopf abgelehnt");
        }

        unsigned planes = (p.order == CUPS_ORDER_PLANAR && channels > 1) ? (unsigned)channels : 1;
        /* Puffer mindestens so groß wie die Pixeldaten, auch wenn bpl absichtlich zu klein ist. */
        size_t line_cap = (bpl > min_bpl ? bpl : min_bpl) + 2;
        uint8_t *line = malloc(line_cap);
        if (line == NULL)
            die("kein Speicher");
        unsigned slots = bpp / (bpc ? bpc : 1);
        unsigned slot_offset = slots >= (unsigned)channels ? slots - (unsigned)channels : 0;
        long rows_total = (long)p.height * (long)planes;
        long rows_written = 0;
        for (unsigned plane = 0; plane < planes; plane++) {
            for (unsigned y = 0; y < p.height; y++) {
                if (p.truncate_rows >= 0 && rows_written >= p.truncate_rows)
                    break;
                /* Füllbytes am Zeilenende: absichtlich „Müll“. */
                memset(line, 0xA5, line_cap);
                memset(line, 0, min_bpl);
                for (unsigned x = 0; writable_depth && x < p.width; x++) {
                    unsigned v[4] = { 0, 0, 0, 0 };
                    channel_values(&p, x, y, v);
                    if (p.order == CUPS_ORDER_BANDED && channels > 1) {
                        for (int ch = 0; ch < channels; ch++)
                            put_bits(line + (size_t)band * (size_t)ch, (uint64_t)x * bpc, bpc, quantize(v[ch], bpc));
                    } else if (planes > 1) {
                        put_bits(line, (uint64_t)x * bpc, bpc, quantize(v[plane], bpc));
                    } else {
                        uint64_t base = (uint64_t)x * bpp;
                        for (unsigned s = 0; s < slot_offset; s++)   /* Füllkanäle: Einsen */
                            put_bits(line, base + (uint64_t)s * bpc, bpc, (1u << (bpc >= 16 ? 16 : bpc)) - 1u);
                        for (int ch = 0; ch < channels; ch++)
                            put_bits(line, base + (uint64_t)(slot_offset + (unsigned)ch) * bpc, bpc, quantize(v[ch], bpc));
                    }
                }
                if (p.raw) {
                    if (bpl > 0 && write(fd, line, bpl) != (ssize_t)bpl)
                        die("Schreiben fehlgeschlagen");
                } else if (bpl > 0 && cupsRasterWritePixels(ras, line, bpl) != bpl) {
                    die("cupsRasterWritePixels fehlgeschlagen");
                }
                if (dump != NULL && bpl > 0 && fwrite(line, 1, bpl, dump) != bpl)
                    die("Rohdaten konnten nicht geschrieben werden");
                rows_written++;
            }
        }
        free(line);
        long dump_size = rows_written * (long)bpl;
        printf("{\"page\": %d, \"w\": %u, \"h\": %u, \"bpc\": %u, \"bpp\": %u, \"bpl\": %u, "
               "\"cs\": %d, \"order\": %d, \"channels\": %d, \"xres\": %u, \"yres\": %u, "
               "\"rows\": %ld, \"rows_total\": %ld, \"dump_offset\": %ld, \"dump_size\": %ld}\n",
               a - first_page + 1, p.width, p.height, bpc, bpp, bpl, p.color_space, p.order, channels,
               p.xres, p.yres, rows_written, rows_total, dump_offset, dump_size);
        dump_offset += dump_size;
        if (p.truncate_rows >= 0)
            break;   /* unvollständige Seite beendet den Datenstrom */
    }
    cupsRasterClose(ras);
    close(fd);
    if (dump != NULL && fclose(dump) != 0)
        die("Rohdaten konnten nicht geschrieben werden");

    /* Gegenprobe: Wie viele Seiten liefert die installierte libcups beim Lesen vollständig?
     * (libcups beendet den Datenstrom je nach Version an ungültigen Köpfen, z. B. Höhe 0.) */
    int in = open(out_path, O_RDONLY);
    if (in < 0)
        die("Ausgabedatei kann nicht gelesen werden");
    cups_raster_t *reader = cupsRasterOpen(in, CUPS_RASTER_READ);
    int readable = 0;
    cups_page_header2_t rh;
    char sizes[8192] = "";
    size_t sizes_len = 0;
    while (reader != NULL && cupsRasterReadHeader2(reader, &rh)) {
        unsigned lines = rh.cupsHeight;
        if (rh.cupsColorOrder == CUPS_ORDER_PLANAR && rh.cupsNumColors > 1)
            lines *= rh.cupsNumColors;
        uint8_t *buf = malloc(rh.cupsBytesPerLine > 0 ? rh.cupsBytesPerLine : 1);
        if (buf == NULL)
            die("kein Speicher");
        bool complete = true;
        for (unsigned y = 0; y < lines && complete; y++)
            complete = cupsRasterReadPixels(reader, buf, rh.cupsBytesPerLine) == rh.cupsBytesPerLine;
        free(buf);
        if (!complete)
            break;
        double pw = 0.0, ph = 0.0;
        if (rh.cupsPageSize[0] > 0.0f && rh.cupsPageSize[1] > 0.0f) {
            pw = rh.cupsPageSize[0];
            ph = rh.cupsPageSize[1];
        } else if (rh.PageSize[0] > 0 && rh.PageSize[1] > 0) {
            pw = rh.PageSize[0];
            ph = rh.PageSize[1];
        }
        if (sizes_len + 64 < sizeof(sizes))
            sizes_len += (size_t)snprintf(sizes + sizes_len, sizeof(sizes) - sizes_len, "%s[%.17g, %.17g]",
                                          readable > 0 ? ", " : "", pw, ph);
        readable++;
    }
    if (reader != NULL)
        cupsRasterClose(reader);
    close(in);
    printf("{\"readable_pages\": %d, \"page_sizes\": [%s]}\n", readable, sizes);
    return 0;
}
