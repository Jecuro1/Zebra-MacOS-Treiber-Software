/*
 * lw_job.c – ZPL-, EPL- und CPCL-Schreiber, Kopien/Sortierung (ARCHITECTURE.md §8).
 */

#if !defined(__APPLE__) && !defined(_DEFAULT_SOURCE)
#  define _DEFAULT_SOURCE 1
#endif

#include "lw_job.h"

#include <stdarg.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <zlib.h>

#include "lw_encode.h"

static int clamp_int(int v, int lo, int hi)
{
    return v < lo ? lo : (v > hi ? hi : v);
}

static void record_init(lw_page_record *r)
{
    r->page_number = 0;
    r->height = 0;
    r->resolution_dpi = 0;
    lw_buf_init(&r->body);
}

static void record_swap(lw_page_record *a, lw_page_record *b)
{
    lw_page_record t = *a;
    *a = *b;
    *b = t;
}

int lw_cpcl_resolution(int dpi)
{
    if (dpi <= 0 || dpi == 203)
        return 200;
    return dpi;
}

bool lw_job_init(lw_job *job, const lw_job_config *config, lw_sink *out, const lw_job_hooks *hooks)
{
    memset(job, 0, sizeof(*job));
    if (config == NULL || config->settings == NULL || out == NULL)
        return false;
    job->s = *config->settings;
    lw_settings_clamp(&job->s);
    job->resolution_dpi = config->resolution_dpi;
    job->max_print_width = config->max_print_width > 0 ? config->max_print_width : 0;
    job->gap_dots = config->gap_dots >= 0 ? config->gap_dots : LW_DEFAULT_GAP_DOTS;
    job->quantity = clamp_int(config->copies, 1, LW_MAX_QUANTITY);
    job->collate_mode = config->collate && job->quantity > 1;
    job->fixed_clock = config->fixed_clock;
    job->fixed_time = config->fixed_time;
    job->time_step = config->time_step;
    job->out = out;
    if (hooks != NULL)
        job->hooks = *hooks;
    record_init(&job->pending);
    record_init(&job->current);
    return true;
}

void lw_job_free(lw_job *job)
{
    lw_buf_free(&job->pending.body);
    lw_buf_free(&job->current.body);
    if (job->spool != NULL) {
        fclose(job->spool);
        job->spool = NULL;
    }
}

/* Schreibt Rohbefehle + LF (nur falls nicht leer). */
static void write_commands_line(lw_job *job, const char *text, size_t len)
{
    if (text == NULL || len == 0)
        return;
    lw_sink_write(job->out, text, len);
    lw_sink_write(job->out, "\n", 1);
}

/* ------------------------------------------------------------------------------------------ */
/* Steuerzeichen und Uhr                                                                      */
/* ------------------------------------------------------------------------------------------ */

/* Ersetzt in selbst erzeugten ZPL-Befehlen ^ ~ , durch die eigenen Steuerzeichen (ein Durchgang,
 * daher auch bei vertauschten Zeichen korrekt). Ohne control_printer: keine Änderung. */
static void map_control_chars(const lw_settings *s, uint8_t *p, size_t n)
{
    if (!s->control_printer || p == NULL)
        return;
    for (size_t i = 0; i < n; i++) {
        switch (p[i]) {
        case '^': p[i] = (uint8_t)s->format_prefix; break;
        case '~': p[i] = (uint8_t)s->control_prefix; break;
        case ',': p[i] = (uint8_t)s->delimiter; break;
        default: break;
        }
    }
}

/* Abbildung auf den Pufferinhalt ab `start` (nach dem Anhängen selbst erzeugter Befehle). */
static void map_buf_from(const lw_settings *s, lw_buf *b, size_t start)
{
    if (!b->failed && b->len > start)
        map_control_chars(s, b->data + start, b->len - start);
}

/* Schreibt einen selbst erzeugten ZPL-Befehl (mit Steuerzeichen-Abbildung) in die Ausgabe. */
static void sink_command(lw_job *job, const char *fmt, ...) LW_PRINTF(2, 3);
static void sink_command(lw_job *job, const char *fmt, ...)
{
    char line[192];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(line, sizeof(line), fmt, ap);
    va_end(ap);
    if (n < 0 || (size_t)n >= sizeof(line)) {
        job->out->failed = true;
        return;
    }
    map_control_chars(&job->s, (uint8_t *)line, (size_t)n);
    lw_sink_write(job->out, line, (size_t)n);
}

/* Uhrzeit für den Auftragskopf (k < 0) bzw. vor Etikett k. */
static long long job_clock(const lw_job *job, long k)
{
    if (!job->fixed_clock)
        return (long long)time(NULL);
    return k <= 0 ? job->fixed_time : job->fixed_time + (long long)k * job->time_step;
}

/* ^XA^STmm,dd,yyyy,hh,mm,ss,M^XZ (Ortszeit, 24 Stunden). */
static void write_set_time(lw_job *job, long long when)
{
    time_t t = (time_t)when;
    struct tm tm;
    if (localtime_r(&t, &tm) == NULL)
        memset(&tm, 0, sizeof(tm));
    sink_command(job, "^XA^ST%02d,%02d,%04d,%02d,%02d,%02d,M^XZ\n", tm.tm_mon + 1, tm.tm_mday,
                 tm.tm_year + 1900, tm.tm_hour, tm.tm_min, tm.tm_sec);
    job->last_st_time = when;
}

/* ~JA: Ausgabe leeren und (nur im Filter) die eingestellte Zeit warten. */
static void write_cancel_all(lw_job *job, bool zpl)
{
    if (zpl)
        sink_command(job, "~JA\n");
    else
        lw_sink_puts(job->out, "~JA\n");   /* EPL: wörtlich wie Startbefehle */
    lw_sink_flush(job->out);
    if (job->hooks.wait_ms != NULL && job->s.cancel_delay > 0 && !job->out->failed)
        job->hooks.wait_ms(job->hooks.ctx, job->s.cancel_delay);
}

static bool report_output_failure(lw_job *job)
{
    if (job->out->failed) {
        lw_log(job->hooks.log, LW_LOG_ERROR, "Die Druckdaten konnten nicht geschrieben werden.");
        return false;
    }
    return true;
}

bool lw_job_begin(lw_job *job)
{
    if (job->begun)
        return true;
    job->begun = true;
    const lw_settings *s = &job->s;
    switch (s->language) {
    case LW_LANGUAGE_ZPL:
        write_commands_line(job, s->start_commands, s->start_commands_len);
        if (s->cancel_before)
            write_cancel_all(job, true);
        if (s->darkness != LW_UNSET)
            sink_command(job, "~SD%02d\n", s->darkness);
        if (s->tear_off != LW_UNSET)
            sink_command(job, "~TA%03d\n", s->tear_off);
        /* Rückzugsfolge: Steuerbefehl ~JS (^JS ist in ZPL II die Sensorwahl). */
        if (s->backfeed != LW_BACKFEED_UNSET)
            sink_command(job, "~JS%c\n", lw_backfeed_code(s->backfeed));
        if (s->calibrate)
            sink_command(job, "~JC\n");
        /* Linerless-Modi haben keinen ^MM-Code: Modus per SGD (unabhängig von Steuerzeichen). */
        if (lw_print_mode_is_linerless(s->print_mode))
            lw_sink_printf(job->out, "! U1 setvar \"media.printmode\" \"%s\"\r\n",
                           lw_print_mode_sgd(s->print_mode));
        if (s->power_up_action != LW_MEDIA_ACTION_UNSET && s->head_close_action != LW_MEDIA_ACTION_UNSET)
            sink_command(job, "^XA^MF%c,%c^XZ\n", lw_media_action_code(s->power_up_action),
                         lw_media_action_code(s->head_close_action));
        if (s->rtc != LW_RTC_UNSET)
            write_set_time(job, job_clock(job, -1));
        break;
    case LW_LANGUAGE_EPL:
        write_commands_line(job, s->start_commands, s->start_commands_len);
        if (s->cancel_before)
            write_cancel_all(job, false);
        break;
    case LW_LANGUAGE_CPCL:
        /* CPCL kennt laut §8 keinen Auftragskopf. */
        break;
    }
    return report_output_failure(job);
}

/* ------------------------------------------------------------------------------------------ */
/* Etikettenrümpfe                                                                            */
/* ------------------------------------------------------------------------------------------ */

/* Rohbefehle + LF in einen Puffer (nur falls nicht leer). */
static void buf_commands_line(lw_buf *b, const char *text, size_t len)
{
    if (text == NULL || len == 0)
        return;
    lw_buf_append(b, text, len);
    lw_buf_append_byte(b, '\n');
}

static bool encode_zpl_body(lw_job *job, const lw_bitmap *page, lw_buf *b)
{
    const lw_settings *s = &job->s;
    size_t mark = b->len;
    lw_buf_append_str(b, "^XA\n");
    map_buf_from(s, b, mark);
    buf_commands_line(b, s->label_start_commands, s->label_start_commands_len);
    mark = b->len;
    if (s->print_mode != LW_PRINT_MODE_UNSET && !lw_print_mode_is_linerless(s->print_mode))
        lw_buf_printf(b, "^MM%c\n", lw_print_mode_code(s->print_mode));
    if (s->tracking == LW_TRACKING_BLACK_MARK && s->mark_offset != LW_UNSET)
        lw_buf_printf(b, "^MNM,%d\n", s->mark_offset);
    else if (s->tracking != LW_TRACKING_UNSET)
        lw_buf_printf(b, "^MN%c\n", lw_tracking_code(s->tracking));
    if (s->media_type != LW_MEDIA_TYPE_UNSET)
        lw_buf_printf(b, "^MT%c\n", lw_media_type_code(s->media_type));
    if (s->speed != LW_UNSET)
        lw_buf_printf(b, "^PR%d,%d,%d\n", s->speed, s->speed, s->speed);
    lw_buf_printf(b, "^PW%d\n", page->width);
    lw_buf_printf(b, "^LL%d\n", page->height);
    lw_buf_append_str(b, "^LH0,0\n");
    if (s->label_top != LW_UNSET)
        lw_buf_printf(b, "^LT%d\n", s->label_top);
    if (s->label_left != LW_UNSET)
        lw_buf_printf(b, "^LS%d\n", s->label_left);
    lw_buf_append_str(b, lw_settings_effective_rotation(s) == 180 ? "^POI\n" : "^PON\n");
    lw_buf_append_str(b, s->mirror ? "^PMY\n" : "^PMN\n");

    size_t total = lw_bitmap_size(page);
    lw_buf_printf(b, "^FO0,0^GFA,%zu,%zu,%d,", total, total, page->bpr);
    map_buf_from(s, b, mark);   /* Grafikdaten selbst bleiben unverändert */
    switch (s->compression) {
    case LW_COMPRESSION_HEX:
        lw_hex_append(b, page->data, total);
        break;
    case LW_COMPRESSION_ACS:
        lw_acs_append(b, page->data, page->bpr, page->height);
        break;
    case LW_COMPRESSION_Z64: {
        int rc = lw_z64_append(b, page->data, total);
        if (rc != Z_OK) {
            if (rc == LW_Z64_NOMEM)
                b->failed = true;
            else {
                lw_log(job->hooks.log, LW_LOG_ERROR,
                       "Z64-Kompression fehlgeschlagen (zlib-Fehler %d).", rc);
                return false;
            }
        }
        break;
    }
    }
    mark = b->len;
    lw_buf_append_str(b, "^FS\n");
    map_buf_from(s, b, mark);
    return !b->failed;
}

static bool encode_epl_body(lw_job *job, const lw_bitmap *page, lw_buf *b)
{
    const lw_settings *s = &job->s;
    /* Führendes LF leert evtl. Restdaten im Empfangspuffer. */
    lw_buf_append_str(b, "\nN\n");
    buf_commands_line(b, s->label_start_commands, s->label_start_commands_len);
    lw_buf_printf(b, "q%d\n", page->width);
    switch (s->tracking) {
    case LW_TRACKING_BLACK_MARK:
        lw_buf_printf(b, "Q%d,B%d\n", page->height, job->gap_dots);
        break;
    case LW_TRACKING_CONTINUOUS:
        lw_buf_printf(b, "Q%d,0\n", page->height);
        break;
    case LW_TRACKING_GAP:
    case LW_TRACKING_NOTCH:     /* Seitenkerben: Durchlichtsensor wie bei Lücken */
    case LW_TRACKING_AUTO:
    case LW_TRACKING_UNSET:
        lw_buf_printf(b, "Q%d,%d\n", page->height, job->gap_dots);
        break;
    }
    if (s->speed != LW_UNSET)
        lw_buf_printf(b, "S%d\n", clamp_int(s->speed, 1, 6));
    if (s->darkness != LW_UNSET)
        lw_buf_printf(b, "D%d\n", clamp_int((s->darkness + 1) / 2, 0, 15));
    lw_buf_append_str(b, lw_settings_effective_rotation(s) == 180 ? "ZB\n" : "ZT\n");
    if (s->media_type != LW_MEDIA_TYPE_UNSET || s->print_mode != LW_PRINT_MODE_UNSET) {
        lw_buf_append_byte(b, 'O');
        if (s->media_type == LW_MEDIA_TYPE_DIRECT_THERMAL)
            lw_buf_append_byte(b, 'D');
        if (s->print_mode == LW_PRINT_MODE_CUTTER)
            lw_buf_append_byte(b, 'C');
        else if (s->print_mode == LW_PRINT_MODE_PEEL_OFF)
            lw_buf_append_byte(b, 'P');
        lw_buf_append_byte(b, '\n');
    }
    /* EPL: ein 0-Bit ist schwarz → Bitmap invertiert übertragen (Füllbits werden 1 = weiß). */
    lw_buf_printf(b, "GW0,0,%d,%d,", page->bpr, page->height);
    size_t total = lw_bitmap_size(page);
    if (lw_buf_reserve(b, total)) {
        uint8_t *dst = b->data + b->len;
        for (size_t i = 0; i < total; i++)
            dst[i] = (uint8_t)~page->data[i];
        b->len += total;
        b->data[b->len] = 0;
    }
    lw_buf_append_byte(b, '\n');
    buf_commands_line(b, s->label_end_commands, s->label_end_commands_len);
    return !b->failed;
}

static bool encode_cpcl_body(lw_job *job, const lw_bitmap *page, lw_buf *b)
{
    const lw_settings *s = &job->s;
    lw_buf_printf(b, "PAGE-WIDTH %d\r\n", page->width);
    if (s->darkness != LW_UNSET)
        lw_buf_printf(b, "CONTRAST %d\r\n", clamp_int((s->darkness * 3 + 15) / 30, 0, 3));
    if (s->speed != LW_UNSET)
        lw_buf_printf(b, "SPEED %d\r\n", clamp_int(s->speed, 0, 5));
    lw_buf_printf(b, "CG %d %d 0 0 ", page->bpr, page->height);
    lw_buf_append(b, page->data, lw_bitmap_size(page));
    lw_buf_append_str(b, "\r\n");
    if (s->tracking != LW_TRACKING_CONTINUOUS)
        lw_buf_append_str(b, "FORM\r\n");
    lw_buf_append_str(b, "PRINT\r\n");
    return !b->failed;
}

bool lw_job_encode_body(lw_job *job, const lw_bitmap *page, lw_buf *body)
{
    bool ok = false;
    switch (job->s.language) {
    case LW_LANGUAGE_ZPL: ok = encode_zpl_body(job, page, body); break;
    case LW_LANGUAGE_EPL: ok = encode_epl_body(job, page, body); break;
    case LW_LANGUAGE_CPCL: ok = encode_cpcl_body(job, page, body); break;
    }
    if (!ok && body->failed)
        lw_log(job->hooks.log, LW_LOG_ERROR, "Nicht genügend Speicher zum Kodieren der Seite.");
    return ok;
}

/* ------------------------------------------------------------------------------------------ */
/* Ausgabe                                                                                    */
/* ------------------------------------------------------------------------------------------ */

bool lw_job_emit_label(lw_job *job, const lw_page_record *record, int quantity)
{
    const lw_settings *s = &job->s;
    switch (s->language) {
    case LW_LANGUAGE_ZPL:
        if (s->rtc == LW_RTC_EVERY_LABEL || s->rtc == LW_RTC_EVERY_MINUTE) {
            long long now = job_clock(job, job->labels_emitted);
            bool due = s->rtc == LW_RTC_EVERY_LABEL ? job->labels_emitted > 0
                                                    : now - job->last_st_time >= 60;
            if (due)
                write_set_time(job, now);
        }
        lw_sink_write(job->out, record->body.data, record->body.len);
        if (s->pause_every > 0)
            sink_command(job, "^PQ%d,%d,0,N\n", quantity, s->pause_every);
        else if (s->cut_every > 0)
            sink_command(job, "^PQ%d,%d,0,Y\n", quantity, s->cut_every);
        else
            sink_command(job, "^PQ%d\n", quantity);
        if (job->labels_emitted == 0 && s->save_settings)
            sink_command(job, "^JUS\n");
        write_commands_line(job, s->label_end_commands, s->label_end_commands_len);
        sink_command(job, "^XZ\n");
        break;
    case LW_LANGUAGE_EPL:
        lw_sink_write(job->out, record->body.data, record->body.len);
        lw_sink_printf(job->out, "P%d\n", quantity);
        break;
    case LW_LANGUAGE_CPCL: {
        int res = lw_cpcl_resolution(record->resolution_dpi);
        lw_sink_printf(job->out, "! 0 %d %d %d %d\r\n", res, res, record->height, quantity);
        lw_sink_write(job->out, record->body.data, record->body.len);
        break;
    }
    }
    lw_sink_flush(job->out);
    if (!report_output_failure(job))
        return false;
    job->labels_emitted++;
    if (job->hooks.label_emitted != NULL)
        job->hooks.label_emitted(job->hooks.ctx, record->page_number, quantity);
    return true;
}

/* Zwischendatei: Kopf (Seitennummer, Höhe, Auflösung, Länge) + Rumpf je Seite, Host-Byte-Reihenfolge. */
typedef struct spool_header {
    int32_t page_number;
    int32_t height;
    int32_t resolution_dpi;
    int32_t reserved;
    uint64_t length;
} spool_header;

static bool spool_write(lw_job *job, const lw_page_record *record)
{
    if (job->spool == NULL) {
        job->spool = job->hooks.open_spool != NULL ? job->hooks.open_spool(job->hooks.ctx) : tmpfile();
        if (job->spool == NULL) {
            lw_log(job->hooks.log, LW_LOG_ERROR,
                   "Zwischendatei für sortierte Kopien konnte nicht angelegt werden.");
            return false;
        }
    }
    spool_header h;
    memset(&h, 0, sizeof(h));
    h.page_number = record->page_number;
    h.height = record->height;
    h.resolution_dpi = record->resolution_dpi;
    h.length = record->body.len;
    if (fwrite(&h, sizeof(h), 1, job->spool) != 1 ||
        (record->body.len > 0 && fwrite(record->body.data, 1, record->body.len, job->spool) != record->body.len)) {
        lw_log(job->hooks.log, LW_LOG_ERROR,
               "Zwischendatei für sortierte Kopien konnte nicht geschrieben werden.");
        return false;
    }
    job->spooled_pages++;
    return true;
}

static bool spool_replay(lw_job *job, int repetitions)
{
    if (fflush(job->spool) != 0) {
        lw_log(job->hooks.log, LW_LOG_ERROR, "Zwischendatei konnte nicht geschrieben werden.");
        return false;
    }
    for (int rep = 0; rep < repetitions; rep++) {
        if (fseek(job->spool, 0, SEEK_SET) != 0) {
            lw_log(job->hooks.log, LW_LOG_ERROR, "Zwischendatei konnte nicht gelesen werden.");
            return false;
        }
        for (int i = 0; i < job->spooled_pages; i++) {
            if (job->hooks.is_canceled != NULL && job->hooks.is_canceled(job->hooks.ctx))
                return true;
            spool_header h;
            if (fread(&h, sizeof(h), 1, job->spool) != 1 || h.length > (uint64_t)SIZE_MAX - 1) {
                lw_log(job->hooks.log, LW_LOG_ERROR, "Zwischendatei ist beschädigt.");
                return false;
            }
            lw_buf_reset(&job->current.body);
            if (!lw_buf_reserve(&job->current.body, (size_t)h.length)) {
                lw_log(job->hooks.log, LW_LOG_ERROR, "Nicht genügend Speicher für sortierte Kopien.");
                return false;
            }
            if (h.length > 0 && fread(job->current.body.data, 1, (size_t)h.length, job->spool) != (size_t)h.length) {
                lw_log(job->hooks.log, LW_LOG_ERROR, "Zwischendatei ist beschädigt.");
                return false;
            }
            job->current.body.len = (size_t)h.length;
            job->current.body.data[job->current.body.len] = 0;
            job->current.page_number = h.page_number;
            job->current.height = h.height;
            job->current.resolution_dpi = h.resolution_dpi;
            if (!lw_job_emit_label(job, &job->current, 1))
                return false;
        }
    }
    return true;
}

bool lw_job_add_page(lw_job *job, lw_bitmap *page, int page_number)
{
    if (!job->begun && !lw_job_begin(job))
        return false;
    const lw_settings *s = &job->s;
    const int rotation = lw_settings_effective_rotation(s);

    /* (0) 90°/270° im Uhrzeigersinn drehen – alle Sprachen, vor dem Abschneiden */
    if ((rotation == 90 || rotation == 270) && !lw_bitmap_rotate_quarter(page, rotation)) {
        lw_log(job->hooks.log, LW_LOG_ERROR, "Nicht genügend Speicher zum Drehen der Seite.");
        return false;
    }
    /* (1) rechts abschneiden */
    lw_bitmap_crop_width(page, job->max_print_width);
    if (page->width <= 0 || page->height <= 0) {
        lw_log(job->hooks.log, LW_LOG_WARNING,
               "Seite %d hat keine druckbare Fläche (%d × %d Punkte) und wird übersprungen.",
               page_number, page->width, page->height);
        job->pages_skipped_empty++;
        return true;
    }
    /* (1b) Endlosmaterial: nach dem letzten Element (+ Stoppversatz) beenden */
    if (s->stop_at_last && s->tracking == LW_TRACKING_CONTINUOUS) {
        long height = (long)lw_bitmap_last_black_row(page) + 1 + s->stop_offset;
        if (height < 1)
            height = 1;
        if (!lw_bitmap_set_height(page, (int)height)) {
            lw_log(job->hooks.log, LW_LOG_ERROR, "Nicht genügend Speicher für die Seitenlänge %ld.", height);
            return false;
        }
    }
    /* (2) Negativ */
    if (s->negative)
        lw_bitmap_invert(page);
    /* (3) leere Seiten überspringen */
    if (s->skip_blank && lw_bitmap_is_blank(page)) {
        lw_log(job->hooks.log, LW_LOG_INFO, "Seite %d ist leer und wird übersprungen.", page_number);
        job->pages_skipped_blank++;
        return true;
    }
    /* (4) Spiegeln – nur EPL/CPCL (ZPL nutzt ^PM) */
    if (s->mirror && s->language != LW_LANGUAGE_ZPL && !lw_bitmap_mirror(page)) {
        lw_log(job->hooks.log, LW_LOG_ERROR, "Nicht genügend Speicher zum Spiegeln der Seite.");
        return false;
    }
    /* (5) 180° – nur CPCL in Software (ZPL nutzt ^PO, EPL ZB) */
    if (rotation == 180 && s->language == LW_LANGUAGE_CPCL && !lw_bitmap_rotate180(page)) {
        lw_log(job->hooks.log, LW_LOG_ERROR, "Nicht genügend Speicher zum Drehen der Seite.");
        return false;
    }

    lw_buf_reset(&job->current.body);
    job->current.page_number = page_number;
    job->current.height = page->height;
    job->current.resolution_dpi = job->resolution_dpi;
    if (!lw_job_encode_body(job, page, &job->current.body))
        return false;
    job->pages_accepted++;

    if (!job->collate_mode)
        return lw_job_emit_label(job, &job->current, job->quantity);

    /* Sortiermodus: erste Seite zurückhalten – bleibt sie die einzige, gilt Menge = Kopien. */
    if (job->pages_accepted == 1) {
        record_swap(&job->current, &job->pending);
        job->have_pending = true;
        return true;
    }
    if (job->have_pending) {
        job->have_pending = false;
        if (!lw_job_emit_label(job, &job->pending, 1) || !spool_write(job, &job->pending))
            return false;
        lw_buf_free(&job->pending.body);
    }
    return lw_job_emit_label(job, &job->current, 1) && spool_write(job, &job->current);
}

bool lw_job_finish(lw_job *job, bool canceled)
{
    if (job->finished)
        return true;
    job->finished = true;
    if (!job->begun) {
        /* Abbruch, bevor irgendetwas geschrieben wurde: weder Auftragskopf (Startbefehle, ~SD,
         * ~TA und vor allem ~JC, das eine Kalibrierung mit Etikettenvorschub auslöst) noch
         * Endbefehle senden – Endbefehle gehören nur zu einem geschriebenen Kopf. Ohne Kopf gibt
         * es auch keine zurückgehaltene Seite und keine Zwischendatei. */
        if (canceled)
            return true;
        if (!lw_job_begin(job))
            return false;
    }

    bool ok = true;
    if (job->have_pending) {
        job->have_pending = false;
        ok = lw_job_emit_label(job, &job->pending, canceled ? 1 : job->quantity);
    } else if (job->spool != NULL && !canceled) {
        ok = spool_replay(job, job->quantity - 1);
    }
    if (!ok)
        return false;

    const lw_settings *s = &job->s;
    if (s->language == LW_LANGUAGE_ZPL || s->language == LW_LANGUAGE_EPL)
        write_commands_line(job, s->end_commands, s->end_commands_len);
    lw_sink_flush(job->out);
    return report_output_failure(job);
}
