/*
 * rastertolabelwerk – CUPS-Filter: CUPS-Raster → ZPL II / EPL2 / CPCL für Zebra-Etikettendrucker.
 *
 * Aufruf (CUPS-Konvention):
 *     rastertolabelwerk job-id user title copies options [file]
 *
 * Ablauf:
 *   1. Optionen aus argv[5] zerlegen, PPD aus $PPD öffnen (ppdMarkDefaults + cupsMarkOptions),
 *      alle lw*-Optionen nach ARCHITECTURE.md §9 auflösen (argv > markierte Auswahl > PPD-Standard)
 *      und die PPD-Attribute *lwModel, *lwMaxPrintWidthDots, *lwDefaultGapDots lesen.
 *   2. Raster aus Datei oder stdin lesen; jede Zeile in 8-Bit-Luminanz umrechnen (§4.1), über die
 *      volle Seitenbreite rastern und auf die Druckbreite abschneiden. Weicht die Seitengröße
 *      (cupsPageSize) um mehr als 2 mm vom Etikett der Warteschlange ab (lwLabelWidth/
 *      lwLabelHeight, lwFitToLabel=Auto), wird die Seite zuerst ganz gelesen und an das Etikett
 *      angepasst (§8 „F“, lw_fit: Inhalt zuschneiden, bei Bedarf um 90° drehen, auf das Etikett
 *      abzüglich 1,5 mm Rand vergrößern bzw. verkleinern, mittig setzen) – sonst zeilenweise ohne
 *      Seitenpuffer.
 *   3. Seiten byte-genau nach §8 kodieren (lw_job) und nach stdout schreiben.
 *
 * Meldungen an CUPS auf stderr: "INFO:", "WARNING:", "ERROR:", "DEBUG:", "PAGE: n m".
 * SIGTERM (Auftrag abgebrochen): die aktuelle Seite wird – wenn vollständig gelesen – noch
 * ausgegeben, danach endet der Filter regulär (keine weiteren Seiten, keine Sortierwiederholungen).
 * Kommt der Abbruch vor der ersten Seite (auch bevor der Datenstrom überhaupt beginnt), schreibt
 * der Filter gar nichts – keinen Auftragskopf (also auch kein ~JC) und keine Endbefehle.
 * Exitcode: 0 = Erfolg (auch nach Abbruch), 1 = Fehler.
 *
 * Umgebungsvariablen (nur für Tests und Diagnose; unter CUPS normalerweise nicht gesetzt):
 *   LW_FIXED_TIME=<Sekunden seit 1970>   feste Uhrzeit für ^ST (lwRTC) statt der Systemzeit
 *   LW_TIME_STEP_SECONDS=<n>             mit LW_FIXED_TIME: Etikett k sieht LW_FIXED_TIME + k·n
 *                                        (simulierte Uhr für lwRTC=EveryMinute)
 *   LW_CANCEL_DELAY_SCALE=<Faktor ≥ 0>   Faktor für die Wartezeit nach ~JA (lwCancelDelay);
 *                                        0 = nicht warten
 */

#if !defined(__APPLE__) && !defined(_DEFAULT_SOURCE)
#  define _DEFAULT_SOURCE 1
#endif

#include <cups/cups.h>
#include <cups/ppd.h>
#include <cups/raster.h>

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "lw_bitmap.h"
#include "lw_cups.h"
#include "lw_dither.h"
#include "lw_fit.h"
#include "lw_job.h"
#include "lw_options.h"
#include "lw_raster.h"
#include "lw_util.h"

/** Obergrenze für cupsWidth (Schutz vor unsinnigen Kopfdaten; Druckköpfe haben < 3 000 Punkte). */
#define LW_MAX_RASTER_WIDTH 100000u
/** Größte Etikettenlänge, die ZPL (^LL) annimmt. */
#define LW_ZPL_MAX_LABEL_LENGTH 32000
/** Größter Seitenpuffer für „An Etikett anpassen“ (Bytes Luminanz); größere Seiten unverändert. */
#define LW_FIT_MAX_PAGE_BYTES ((size_t)1 << 30)

static volatile sig_atomic_t g_canceled = 0;

static void on_sigterm(int sig)
{
    (void)sig;
    g_canceled = 1;
}

/* ------------------------------------------------------------------------------------------ */
/* Auftragshaken                                                                              */
/* ------------------------------------------------------------------------------------------ */

static void on_label_emitted(void *ctx, int page_number, int quantity)
{
    (void)ctx;
    fprintf(stderr, "PAGE: %d %d\n", page_number, quantity);
    fflush(stderr);
}

static FILE *open_spool(void *ctx)
{
    (void)ctx;
    char path[1024];
    int fd = cupsTempFd(path, (int)sizeof(path));
    if (fd < 0)
        return tmpfile();
    unlink(path);
    FILE *f = fdopen(fd, "w+b");
    if (f == NULL)
        close(fd);
    return f;
}

static bool is_canceled(void *ctx)
{
    (void)ctx;
    return g_canceled != 0;
}

/* Wartezeit nach ~JA (lwCancelBefore/lwCancelDelay), skaliert mit LW_CANCEL_DELAY_SCALE.
 * Ein SIGTERM beendet die Wartezeit vorzeitig. */
typedef struct filter_context {
    double delay_scale;
    const lw_logger *log;
} filter_context;

static void wait_ms(void *ctx, int ms)
{
    const filter_context *fc = ctx;
    double scaled = (double)ms * (fc != NULL ? fc->delay_scale : 1.0);
    if (scaled < 1.0)
        return;
    long total = (long)(scaled + 0.5);
    lw_log(fc != NULL ? fc->log : NULL, LW_LOG_DEBUG, "Warte %ld ms nach ~JA (laufende Aufträge abbrechen).", total);
    struct timespec rest = { total / 1000, (total % 1000) * 1000000L };
    while (!g_canceled && nanosleep(&rest, &rest) != 0 && errno == EINTR)
        ;
}

/* Ganzzahl aus einer Umgebungsvariablen; false, wenn sie fehlt oder ungültig ist. */
static bool env_long_long(const char *name, long long *value, const lw_logger *log)
{
    const char *text = getenv(name);
    if (text == NULL || text[0] == '\0')
        return false;
    char *end = NULL;
    errno = 0;
    long long v = strtoll(text, &end, 10);
    if (errno != 0 || end == text || *end != '\0') {
        lw_log(log, LW_LOG_WARNING, "Ungültiger Wert „%.40s“ für %s – wird ignoriert.", text, name);
        return false;
    }
    *value = v;
    return true;
}

/* ------------------------------------------------------------------------------------------ */
/* Seiten                                                                                     */
/* ------------------------------------------------------------------------------------------ */

typedef enum page_result {
    PAGE_OK,
    PAGE_CANCELED,
    PAGE_FAILED
} page_result;

typedef struct page_buffers {
    uint8_t *line;
    size_t line_size;
    uint8_t *lum;
    size_t lum_size;
    uint8_t *dither_row;
    size_t dither_row_size;
} page_buffers;

static bool ensure_buffer(uint8_t **buf, size_t *size, size_t need)
{
    if (need == 0)
        need = 1;
    if (*size >= need)
        return true;
    uint8_t *p = realloc(*buf, need);
    if (p == NULL)
        return false;
    *buf = p;
    *size = need;
    return true;
}

/* Liest eine Seite ohne sie zu verwenden (z. B. Breite 0). */
static page_result discard_page(cups_raster_t *ras, const cups_page_header2_t *h, page_buffers *b)
{
    if (!ensure_buffer(&b->line, &b->line_size, h->cupsBytesPerLine))
        return PAGE_FAILED;
    for (unsigned y = 0; y < h->cupsHeight; y++) {
        if (g_canceled)
            return PAGE_CANCELED;
        if (cupsRasterReadPixels(ras, b->line, h->cupsBytesPerLine) != h->cupsBytesPerLine)
            return g_canceled ? PAGE_CANCELED : PAGE_FAILED;
    }
    return PAGE_OK;
}

/* Quelle der Luminanzzeilen einer Seite: der Rasterdatenstrom (Zeile für Zeile) oder ein
 * Seitenpuffer (nach „An Etikett anpassen“). */
typedef struct row_source {
    cups_raster_t *ras;
    const cups_page_header2_t *h;
    const lw_raster_converter *conv;
    page_buffers *b;
    int page_number;
    int raster_height;
    const lw_logger *log;
    const uint8_t *image;      /* NULL = Datenstrom */
    size_t image_stride;
} row_source;

/* Liefert Luminanzzeile `y` (Datenstrom: die nächste Zeile). */
static page_result next_row(const row_source *src, int y, const uint8_t **row)
{
    if (src->image != NULL) {
        *row = src->image + (size_t)y * src->image_stride;
        return PAGE_OK;
    }
    if (cupsRasterReadPixels(src->ras, src->b->line, src->h->cupsBytesPerLine) != src->h->cupsBytesPerLine) {
        if (g_canceled)
            return PAGE_CANCELED;
        lw_log(src->log, LW_LOG_ERROR, "Rasterdaten von Seite %d sind unvollständig (Zeile %d von %d).",
               src->page_number, y + 1, src->raster_height);
        return PAGE_FAILED;
    }
    lw_raster_convert_line(src->conv, src->b->line, src->b->lum);
    *row = src->b->lum;
    return PAGE_OK;
}

/* Rastert `width` × `height` Luminanzzeilen aus `src`, schneidet auf die Druckbreite ab und gibt
 * die Seite an den Auftrag. */
static page_result rasterize_page(const row_source *src, int width, int height, const cups_page_header2_t *h,
                                  lw_job *job, const lw_settings *settings, int max_print_width,
                                  page_buffers *b, const lw_logger *log)
{
    const int page_number = src->page_number;
    /* Bei 90°/270° wird erst nach dem Drehen abgeschnitten (lw_job_add_page, §8 Schritt 0). */
    const int rotation = lw_settings_effective_rotation(settings);
    const bool quarter = rotation == 90 || rotation == 270;
    const int rotated_width = quarter ? height : width;
    const int label_length = quarter ? width : height;
    const int out_width = (!quarter && max_print_width > 0 && width > max_print_width) ? max_print_width : width;
    if (max_print_width > 0 && rotated_width > max_print_width)
        lw_log(log, LW_LOG_INFO, "Seite %d ist %d Punkte breit und wird auf die Druckbreite von %d Punkten abgeschnitten.",
               page_number, rotated_width, max_print_width);
    if (quarter)
        lw_log(log, LW_LOG_DEBUG, "Seite %d wird um %d° gedreht.", page_number, rotation);
    if (settings->language == LW_LANGUAGE_ZPL && label_length > LW_ZPL_MAX_LABEL_LENGTH)
        lw_log(log, LW_LOG_WARNING, "Seite %d ist %d Punkte lang – ZPL erlaubt höchstens %d (^LL); der Drucker kürzt das Etikett.",
               page_number, label_length, LW_ZPL_MAX_LABEL_LENGTH);

    lw_bitmap page;
    lw_bitmap_init(&page);
    if (!lw_bitmap_alloc(&page, out_width, height)) {
        lw_log(log, LW_LOG_ERROR, "Seite %d (%d × %d Punkte) ist zu groß oder es fehlt Speicher.",
               page_number, out_width, height);
        return PAGE_FAILED;
    }
    const size_t full_bpr = ((size_t)width + 7) / 8;
    if (!ensure_buffer(&b->dither_row, &b->dither_row_size, full_bpr)) {
        lw_bitmap_free(&page);
        lw_log(log, LW_LOG_ERROR, "Nicht genügend Speicher für Seite %d.", page_number);
        return PAGE_FAILED;
    }

    lw_ditherer ditherer;
    if (!lw_ditherer_init(&ditherer, settings->dither, settings->threshold, width)) {
        lw_bitmap_free(&page);
        lw_log(log, LW_LOG_ERROR, "Nicht genügend Speicher für die Rasterung von Seite %d.", page_number);
        return PAGE_FAILED;
    }

    /* Gerastert wird über die volle Seitenbreite (wie JobEncoder.encode(images:)); erst die
     * fertige 1-Bit-Zeile wird auf die Druckbreite abgeschnitten. */
    const bool crop = out_width < width;
    const uint8_t last_mask = lw_bitmap_last_mask(out_width);
    page_result result = PAGE_OK;
    for (int y = 0; y < height; y++) {
        const uint8_t *lum = NULL;
        result = next_row(src, y, &lum);
        if (result != PAGE_OK)
            break;
        uint8_t *row = lw_bitmap_row(&page, y);
        if (crop) {
            lw_ditherer_row(&ditherer, lum, b->dither_row);
            memcpy(row, b->dither_row, (size_t)page.bpr);
            row[page.bpr - 1] &= last_mask;
        } else {
            lw_ditherer_row(&ditherer, lum, row);
        }
    }
    lw_ditherer_free(&ditherer);

    if (result == PAGE_OK) {
        job->resolution_dpi = (int)h->HWResolution[0];
        if (!lw_job_add_page(job, &page, page_number))
            result = PAGE_FAILED;
    }
    lw_bitmap_free(&page);
    return result;
}

/* Seitengröße in Punkten: cupsPageSize, wenn beide > 0, sonst PageSize, sonst unbekannt (§8 „F“). */
static bool page_size_points(const cups_page_header2_t *h, double *w, double *hgt)
{
    if (h->cupsPageSize[0] > 0.0f && h->cupsPageSize[1] > 0.0f) {
        *w = (double)h->cupsPageSize[0];
        *hgt = (double)h->cupsPageSize[1];
        return true;
    }
    if (h->PageSize[0] > 0 && h->PageSize[1] > 0) {
        *w = (double)h->PageSize[0];
        *hgt = (double)h->PageSize[1];
        return true;
    }
    return false;
}

static int resolution_or_zero(unsigned dpi)
{
    return dpi <= 100000u ? (int)dpi : 0;
}

static page_result process_page(cups_raster_t *ras, const cups_page_header2_t *h, int page_number,
                                lw_job *job, const lw_settings *settings, int max_print_width,
                                page_buffers *b, const lw_logger *log)
{
    lw_raster_format format = {
        .width = h->cupsWidth,
        .height = h->cupsHeight,
        .bits_per_color = h->cupsBitsPerColor,
        .bits_per_pixel = h->cupsBitsPerPixel,
        .bytes_per_line = h->cupsBytesPerLine,
        .color_order = (unsigned)h->cupsColorOrder,
        .color_space = (unsigned)h->cupsColorSpace,
    };

    lw_log(log, LW_LOG_DEBUG,
           "Seite %d: %u × %u Punkte, %u × %u dpi, Farbraum %s, %u Bit/Farbe, %u Bit/Pixel, "
           "%u Bytes/Zeile, Anordnung %u, Seitengröße %.2f × %.2f pt",
           page_number, h->cupsWidth, h->cupsHeight, h->HWResolution[0], h->HWResolution[1],
           lw_raster_color_space_name(format.color_space), h->cupsBitsPerColor,
           h->cupsBitsPerPixel, h->cupsBytesPerLine, format.color_order,
           (double)h->cupsPageSize[0], (double)h->cupsPageSize[1]);

    if (h->cupsWidth == 0 || h->cupsHeight == 0) {
        lw_log(log, LW_LOG_WARNING, "Seite %d hat keine druckbare Fläche (%u × %u Punkte) und wird übersprungen.",
               page_number, h->cupsWidth, h->cupsHeight);
        job->pages_skipped_empty++;
        return h->cupsHeight > 0 && h->cupsBytesPerLine > 0 ? discard_page(ras, h, b) : PAGE_OK;
    }
    if (h->cupsWidth > LW_MAX_RASTER_WIDTH) {
        lw_log(log, LW_LOG_ERROR, "Seite %d ist mit %u Punkten zu breit (höchstens %u).",
               page_number, h->cupsWidth, LW_MAX_RASTER_WIDTH);
        return PAGE_FAILED;
    }
    if (h->cupsHeight > (unsigned)INT_MAX) {
        lw_log(log, LW_LOG_ERROR, "Seite %d ist mit %u Zeilen zu lang.", page_number, h->cupsHeight);
        return PAGE_FAILED;
    }

    lw_raster_converter conv;
    char error[256];
    if (!lw_raster_converter_init(&conv, &format, error, sizeof(error))) {
        lw_log(log, LW_LOG_ERROR, "Seite %d: %s", page_number, error);
        return PAGE_FAILED;
    }

    const int width = (int)h->cupsWidth;
    const int height = (int)h->cupsHeight;
    if (!ensure_buffer(&b->line, &b->line_size, h->cupsBytesPerLine) ||
        !ensure_buffer(&b->lum, &b->lum_size, (size_t)width)) {
        lw_log(log, LW_LOG_ERROR, "Nicht genügend Speicher für Seite %d.", page_number);
        return PAGE_FAILED;
    }
    row_source stream = { ras, h, &conv, b, page_number, height, log, NULL, 0 };

    /* --- §8 „F“: An Etikett anpassen ------------------------------------------------------ */
    double page_w = 0.0, page_h = 0.0;
    lw_fit_plan plan;
    bool fit = page_size_points(h, &page_w, &page_h) &&
               lw_fit_decide(settings, width, height, page_w, page_h, resolution_or_zero(h->HWResolution[0]),
                             resolution_or_zero(h->HWResolution[1]), &plan);
    if (!fit)
        return rasterize_page(&stream, width, height, h, job, settings, max_print_width, b, log);

    const size_t page_bytes = (size_t)width * (size_t)height;
    uint8_t *image = page_bytes <= LW_FIT_MAX_PAGE_BYTES ? malloc(page_bytes) : NULL;
    if (image == NULL) {
        lw_log(log, LW_LOG_WARNING, "Seite %d (%d × %d Punkte) ist zu groß, um sie an das Etikett anzupassen – "
               "sie wird unverändert gedruckt.", page_number, width, height);
        return rasterize_page(&stream, width, height, h, job, settings, max_print_width, b, log);
    }
    for (int y = 0; y < height; y++) {
        const uint8_t *lum = NULL;
        page_result r = next_row(&stream, y, &lum);
        if (r != PAGE_OK) {
            free(image);
            return r;
        }
        memcpy(image + (size_t)y * (size_t)width, lum, (size_t)width);
    }
    uint8_t *fitted = NULL;
    int fitted_w = 0, fitted_h = 0, turn = LW_FIT_TURN_NONE;
    row_source buffered = stream;
    page_result result;
    if (lw_fit_apply(&plan, image, width, height, &fitted, &fitted_w, &fitted_h, &turn)) {
        lw_log(log, LW_LOG_INFO,
               "Seite %d (%.0f × %.0f mm) passt nicht zum Etikett – der Inhalt wird automatisch auf "
               "das Etikett gelegt (%d × %d Punkte%s).",
               page_number, page_w * 25.4 / 72.0, page_h * 25.4 / 72.0, fitted_w, fitted_h,
               turn == LW_FIT_TURN_CW ? ", um 90° im Uhrzeigersinn gedreht"
               : turn == LW_FIT_TURN_CCW ? ", um 90° gegen den Uhrzeigersinn gedreht" : "");
        free(image);
        buffered.image = fitted;
        buffered.image_stride = (size_t)fitted_w;
        result = rasterize_page(&buffered, fitted_w, fitted_h, h, job, settings, max_print_width, b, log);
        free(fitted);
    } else {
        lw_log(log, LW_LOG_WARNING, "Nicht genügend Speicher, um Seite %d an das Etikett anzupassen – "
               "sie wird unverändert gedruckt.", page_number);
        buffered.image = image;
        buffered.image_stride = (size_t)width;
        result = rasterize_page(&buffered, width, height, h, job, settings, max_print_width, b, log);
        free(image);
    }
    return result;
}

/* ------------------------------------------------------------------------------------------ */
/* Hauptprogramm                                                                              */
/* ------------------------------------------------------------------------------------------ */

int main(int argc, char *argv[])
{
    lw_logger log = { lw_logger_file_emit, stderr };

    if (argc < 6 || argc > 7) {
        fprintf(stderr, "Usage: %s job-id user title copies options [file]\n",
                argc > 0 ? argv[0] : "rastertolabelwerk");
        return 1;
    }

    struct sigaction action;
    memset(&action, 0, sizeof(action));
    sigemptyset(&action.sa_mask);
    action.sa_handler = on_sigterm;
    sigaction(SIGTERM, &action, NULL);

    /* --- Optionen & PPD ----------------------------------------------------------------- */
    lw_cups_options opts;
    lw_cups_options_open(&opts, argv[5], &log);

    lw_settings settings;
    lw_settings_init(&settings);
    lw_settings_resolve(&settings, lw_cups_lookup, &opts, &log);
    lw_settings_log(&settings, &log);

    int max_print_width = lw_cups_ppd_int(&opts, LW_ATTR_MAX_PRINT_WIDTH, 1, 0, &log);
    int gap_dots = lw_cups_ppd_int(&opts, LW_ATTR_DEFAULT_GAP, 0, LW_DEFAULT_GAP_DOTS, &log);
    const char *model = lw_cups_ppd_string(&opts, LW_ATTR_MODEL);
    int copies = lw_cups_copies(argv[4], &log);
    bool collate = lw_cups_collate(&opts, &log);
    long long fixed_time = 0, time_step = 0;
    bool fixed_clock = env_long_long("LW_FIXED_TIME", &fixed_time, &log);
    if (fixed_clock)
        env_long_long("LW_TIME_STEP_SECONDS", &time_step, &log);
    filter_context fctx = { 1.0, &log };
    const char *scale = getenv("LW_CANCEL_DELAY_SCALE");
    if (scale != NULL && scale[0] != '\0') {
        char *end = NULL;
        double v = strtod(scale, &end);
        if (end == scale || *end != '\0' || !(v >= 0.0) || v > 1000.0)
            lw_log(&log, LW_LOG_WARNING, "Ungültiger Wert „%.40s“ für LW_CANCEL_DELAY_SCALE – wird ignoriert.", scale);
        else
            fctx.delay_scale = v;
    }
    lw_log(&log, LW_LOG_DEBUG, "Modell=%s Druckbreite=%d Lücke=%d Kopien=%d Sortieren=%d",
           model != NULL ? model : "-", max_print_width, gap_dots, copies, collate);

    /* --- Eingabe -------------------------------------------------------------------------- */
    int fd = 0;
    if (argc == 7) {
        fd = open(argv[6], O_RDONLY);
        if (fd < 0) {
            lw_log(&log, LW_LOG_ERROR, "Druckdatei „%s“ kann nicht geöffnet werden: %s", argv[6], strerror(errno));
            lw_settings_free(&settings);
            lw_cups_options_close(&opts);
            return 1;
        }
    }
    cups_raster_t *ras = cupsRasterOpen(fd, CUPS_RASTER_READ);
    if (ras == NULL) {
        /* Abbruch vor dem Synchronisationswort: CUPS beendet auch den vorgelagerten Filter, der
         * die Pipe dann ohne Daten schließt. Das ist kein Fehler des Datenstroms – es wurde
         * nichts gesendet, und wie bei jedem Abbruch endet der Filter mit Exitcode 0. */
        const bool canceled_early = g_canceled != 0;
        if (canceled_early)
            lw_log(&log, LW_LOG_INFO, "Auftrag abgebrochen – 0 Etikett(en) wurden gesendet.");
        else
            lw_log(&log, LW_LOG_ERROR, "Der Rasterdatenstrom konnte nicht geöffnet werden.");
        if (fd != 0)
            close(fd);
        lw_settings_free(&settings);
        lw_cups_options_close(&opts);
        return canceled_early ? 0 : 1;
    }

    /* --- Auftrag -------------------------------------------------------------------------- */
    lw_sink out;
    lw_sink_init_file(&out, stdout);
    lw_job_config config = {
        .settings = &settings,
        .resolution_dpi = 203,
        .max_print_width = max_print_width,
        .gap_dots = gap_dots,
        .copies = copies,
        .collate = collate,
        .fixed_clock = fixed_clock,
        .fixed_time = fixed_time,
        .time_step = time_step,
    };
    lw_job_hooks hooks = {
        .label_emitted = on_label_emitted,
        .open_spool = open_spool,
        .is_canceled = is_canceled,
        .ctx = &fctx,
        .log = &log,
        .wait_ms = wait_ms,
    };
    lw_job job;
    lw_job_init(&job, &config, &out, &hooks);

    page_buffers buffers;
    memset(&buffers, 0, sizeof(buffers));
    cups_page_header2_t header;
    int page_number = 0;
    bool failed = false;
    bool canceled = false;

    while (!g_canceled && cupsRasterReadHeader2(ras, &header)) {
        page_number++;
        lw_log(&log, LW_LOG_INFO, "Seite %d wird verarbeitet (%s) …", page_number,
               lw_language_name(settings.language));
        page_result r = process_page(ras, &header, page_number, &job, &settings, max_print_width,
                                     &buffers, &log);
        if (r == PAGE_FAILED) {
            failed = true;
            break;
        }
        if (r == PAGE_CANCELED)
            break;
    }
    canceled = g_canceled != 0;

    if (!failed) {
        if (page_number == 0 && !canceled) {
            lw_log(&log, LW_LOG_ERROR, "Im Rasterdatenstrom wurden keine Seiten gefunden.");
            failed = true;
        } else if (!lw_job_finish(&job, canceled)) {
            failed = true;
        } else if (canceled) {
            lw_log(&log, LW_LOG_INFO, "Auftrag abgebrochen – %ld Etikett(en) wurden gesendet.", job.labels_emitted);
        } else {
            lw_log(&log, LW_LOG_INFO, "Fertig: %ld Seite(n), %ld Etikett(en) gesendet%s.",
                   job.pages_accepted, job.labels_emitted,
                   job.pages_skipped_blank > 0 ? " (leere Seiten übersprungen)" : "");
        }
    }

    free(buffers.line);
    free(buffers.lum);
    free(buffers.dither_row);
    lw_job_free(&job);
    cupsRasterClose(ras);
    if (fd != 0)
        close(fd);
    lw_settings_free(&settings);
    lw_cups_options_close(&opts);
    return failed ? 1 : 0;
}
