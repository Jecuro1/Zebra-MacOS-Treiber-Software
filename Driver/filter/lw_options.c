/*
 * lw_options.c – Zerlegung und Vorrangauflösung der lw*-Optionen (ARCHITECTURE.md §9).
 */

#if !defined(__APPLE__) && !defined(_DEFAULT_SOURCE)
#  define _DEFAULT_SOURCE 1
#endif

#include "lw_options.h"

#include <stdlib.h>
#include <string.h>

#include "lw_encode.h"

/* ------------------------------------------------------------------------------------------ */
/* Standardwerte                                                                              */
/* ------------------------------------------------------------------------------------------ */

void lw_settings_init(lw_settings *s)
{
    memset(s, 0, sizeof(*s));
    s->language = LW_LANGUAGE_ZPL;
    s->darkness = LW_UNSET;
    s->speed = LW_UNSET;
    s->media_type = LW_MEDIA_TYPE_UNSET;
    s->tracking = LW_TRACKING_UNSET;
    s->print_mode = LW_PRINT_MODE_UNSET;
    s->label_top = LW_UNSET;
    s->label_left = LW_UNSET;
    s->tear_off = LW_UNSET;
    s->backfeed = LW_BACKFEED_UNSET;
    s->mirror = false;
    s->negative = false;
    s->rotate180 = false;
    s->dither = LW_DITHER_THRESHOLD;
    s->threshold = 128;
    s->compression = LW_COMPRESSION_Z64;
    s->cut_every = 0;
    s->calibrate = false;
    s->save_settings = false;
    s->skip_blank = false;
    s->start_commands = NULL;
    s->start_commands_len = 0;
    s->end_commands = NULL;
    s->end_commands_len = 0;
    s->rotation = 0;
    s->mark_offset = LW_UNSET;
    s->stop_at_last = false;
    s->stop_offset = 0;
    s->pause_every = 0;
    s->control_printer = false;
    s->format_prefix = LW_FORMAT_PREFIX_STANDARD;
    s->control_prefix = LW_CONTROL_PREFIX_STANDARD;
    s->delimiter = LW_DELIMITER_STANDARD;
    s->rtc = LW_RTC_UNSET;
    s->cancel_before = false;
    s->cancel_delay = 1000;
    s->label_start_commands = NULL;
    s->label_start_commands_len = 0;
    s->label_end_commands = NULL;
    s->label_end_commands_len = 0;
    s->power_up_action = LW_MEDIA_ACTION_UNSET;
    s->head_close_action = LW_MEDIA_ACTION_UNSET;
    s->fit_to_label = LW_FIT_AUTO;
    s->label_width = 0;
    s->label_height = 0;
}

void lw_settings_free(lw_settings *s)
{
    free(s->start_commands);
    free(s->end_commands);
    free(s->label_start_commands);
    free(s->label_end_commands);
    lw_settings_init(s);
}

static int clamp_int(int v, int lo, int hi)
{
    return v < lo ? lo : (v > hi ? hi : v);
}

void lw_settings_clamp(lw_settings *s)
{
    if (s->darkness != LW_UNSET)
        s->darkness = clamp_int(s->darkness, 0, 30);
    if (s->speed != LW_UNSET)
        s->speed = clamp_int(s->speed, 1, 14);
    if (s->label_top != LW_UNSET)
        s->label_top = clamp_int(s->label_top, -120, 120);
    if (s->label_left != LW_UNSET)
        s->label_left = clamp_int(s->label_left, -9999, 9999);
    if (s->tear_off != LW_UNSET)
        s->tear_off = clamp_int(s->tear_off, -120, 120);
    s->threshold = clamp_int(s->threshold, 1, 254);
    s->cut_every = clamp_int(s->cut_every, 0, 9999);
    if (s->rotation != 0 && s->rotation != 90 && s->rotation != 180 && s->rotation != 270)
        s->rotation = 0;
    if (s->mark_offset != LW_UNSET)
        s->mark_offset = clamp_int(s->mark_offset, -80, 283);
    s->stop_offset = clamp_int(s->stop_offset, 0, 32000);
    s->pause_every = clamp_int(s->pause_every, 0, 9999);
    s->cancel_delay = clamp_int(s->cancel_delay, 0, 10000);
    s->label_width = clamp_int(s->label_width, 0, LW_LABEL_SIZE_MAX);
    s->label_height = clamp_int(s->label_height, 0, LW_LABEL_SIZE_MAX);
    if (s->fit_to_label != LW_FIT_AUTO && s->fit_to_label != LW_FIT_OFF)
        s->fit_to_label = LW_FIT_AUTO;
    /* Steuerzeichen außerhalb von 33…126 gelten als Standardzeichen dieser Stelle. */
    if (s->format_prefix < LW_CONTROL_CHAR_MIN || s->format_prefix > LW_CONTROL_CHAR_MAX)
        s->format_prefix = LW_FORMAT_PREFIX_STANDARD;
    if (s->control_prefix < LW_CONTROL_CHAR_MIN || s->control_prefix > LW_CONTROL_CHAR_MAX)
        s->control_prefix = LW_CONTROL_PREFIX_STANDARD;
    if (s->delimiter < LW_CONTROL_CHAR_MIN || s->delimiter > LW_CONTROL_CHAR_MAX)
        s->delimiter = LW_DELIMITER_STANDARD;
}

int lw_settings_effective_rotation(const lw_settings *s)
{
    if (s->rotation == 90 || s->rotation == 180 || s->rotation == 270)
        return s->rotation;
    return s->rotate180 ? 180 : 0;
}

/* ------------------------------------------------------------------------------------------ */
/* Zerleger                                                                                   */
/* ------------------------------------------------------------------------------------------ */

typedef struct enum_entry {
    const char *name;
    int value;
} enum_entry;

static lw_parse_result parse_enum(const char *text, const enum_entry *table, int *value)
{
    if (lw_str_ieq(text, LW_VALUE_DEFAULT))
        return LW_PARSE_DEFAULT;
    for (const enum_entry *e = table; e->name != NULL; e++) {
        if (lw_str_ieq(text, e->name)) {
            *value = e->value;
            return LW_PARSE_OK;
        }
    }
    return LW_PARSE_INVALID;
}

static const enum_entry language_table[] = {
    { "ZPL", LW_LANGUAGE_ZPL }, { "ZPL2", LW_LANGUAGE_ZPL }, { "ZPLII", LW_LANGUAGE_ZPL },
    { "EPL", LW_LANGUAGE_EPL }, { "EPL2", LW_LANGUAGE_EPL },
    { "CPCL", LW_LANGUAGE_CPCL },
    { NULL, 0 }
};

static const enum_entry media_type_table[] = {
    { "DirectThermal", LW_MEDIA_TYPE_DIRECT_THERMAL },
    { "ThermalTransfer", LW_MEDIA_TYPE_THERMAL_TRANSFER },
    { NULL, 0 }
};

static const enum_entry tracking_table[] = {
    { "Gap", LW_TRACKING_GAP }, { "BlackMark", LW_TRACKING_BLACK_MARK },
    { "Continuous", LW_TRACKING_CONTINUOUS }, { "Auto", LW_TRACKING_AUTO },
    { "Notch", LW_TRACKING_NOTCH },
    { NULL, 0 }
};

static const enum_entry print_mode_table[] = {
    { "TearOff", LW_PRINT_MODE_TEAR_OFF }, { "PeelOff", LW_PRINT_MODE_PEEL_OFF },
    { "Cutter", LW_PRINT_MODE_CUTTER }, { "DelayedCut", LW_PRINT_MODE_DELAYED_CUT },
    { "Rewind", LW_PRINT_MODE_REWIND }, { "Applicator", LW_PRINT_MODE_APPLICATOR },
    { "Kiosk", LW_PRINT_MODE_KIOSK },
    { "LinerlessPeel", LW_PRINT_MODE_LINERLESS_PEEL }, { "LinerlessCut", LW_PRINT_MODE_LINERLESS_CUT },
    { "LinerlessDelayedCut", LW_PRINT_MODE_LINERLESS_DELAYED_CUT },
    { "LinerlessRewind", LW_PRINT_MODE_LINERLESS_REWIND }, { "LinerlessTear", LW_PRINT_MODE_LINERLESS_TEAR },
    { NULL, 0 }
};

/* SGD-Werte für media.printmode je Druckmodus (Index = lw_print_mode), wie getvar sie meldet. */
static const char *const print_mode_sgd[] = {
    NULL, "tear off", "peel off", "cutter", "delayed cut", "rewind", "applicator", "kiosk",
    "linerless peel", "linerless cut", "linerless delayed cut", "linerless rewind", "linerless tear"
};

/* Setzwerte für setvar "media.printmode" laut Zebra-SGD-Referenz: Kennbuchstaben; Linerless
 * schneiden/verzögert schneiden haben keinen dokumentierten Buchstaben (dort das Wort). */
static const char *const print_mode_sgd_set[] = {
    NULL, "T", "P", "C", "D", "R", "A", "K",
    "L", "linerless cut", "linerless delayed cut", "U", "V"
};

static const enum_entry rotation_table[] = {
    { "0", 0 }, { "90", 90 }, { "180", 180 }, { "270", 270 },
    { NULL, 0 }
};

static const enum_entry rtc_table[] = {
    { "JobStart", LW_RTC_JOB_START }, { "EveryLabel", LW_RTC_EVERY_LABEL },
    { "EveryMinute", LW_RTC_EVERY_MINUTE },
    { NULL, 0 }
};

static const enum_entry media_action_table[] = {
    { "Feed", LW_MEDIA_ACTION_FEED }, { "Calibrate", LW_MEDIA_ACTION_CALIBRATE },
    { "Length", LW_MEDIA_ACTION_LENGTH }, { "NoMotion", LW_MEDIA_ACTION_NO_MOTION },
    { "ShortCal", LW_MEDIA_ACTION_SHORT_CAL },
    { NULL, 0 }
};

static const enum_entry fit_mode_table[] = {
    { "Auto", LW_FIT_AUTO }, { "Off", LW_FIT_OFF },
    { NULL, 0 }
};

static const enum_entry control_chars_table[] = {
    { "Standard", 0 }, { "Printer", 1 },
    { NULL, 0 }
};

static const enum_entry backfeed_table[] = {
    { "After", LW_BACKFEED_AFTER }, { "Before", LW_BACKFEED_BEFORE },
    { "Normal", LW_BACKFEED_NORMAL }, { "Off", LW_BACKFEED_OFF },
    { NULL, 0 }
};

static const enum_entry dither_table[] = {
    { "Threshold", LW_DITHER_THRESHOLD }, { "Ordered", LW_DITHER_ORDERED },
    { "Halftone", LW_DITHER_HALFTONE }, { "FloydSteinberg", LW_DITHER_FLOYD_STEINBERG },
    { "Atkinson", LW_DITHER_ATKINSON }, { "Stucki", LW_DITHER_STUCKI },
    { NULL, 0 }
};

static const enum_entry compression_table[] = {
    { "Z64", LW_COMPRESSION_Z64 }, { "ACS", LW_COMPRESSION_ACS }, { "Hex", LW_COMPRESSION_HEX },
    { NULL, 0 }
};

lw_parse_result lw_parse_bool(const char *text, bool *value)
{
    static const char *const yes[] = { "true", "yes", "on", "1" };
    static const char *const no[] = { "false", "no", "off", "0" };
    if (lw_str_ieq(text, LW_VALUE_DEFAULT))
        return LW_PARSE_DEFAULT;
    for (size_t i = 0; i < 4; i++) {
        if (lw_str_ieq(text, yes[i])) {
            *value = true;
            return LW_PARSE_OK;
        }
        if (lw_str_ieq(text, no[i])) {
            *value = false;
            return LW_PARSE_OK;
        }
    }
    return LW_PARSE_INVALID;
}

lw_parse_result lw_parse_int(const char *text, int *value)
{
    if (lw_str_ieq(text, LW_VALUE_DEFAULT))
        return LW_PARSE_DEFAULT;
    const char *p = text;
    if (lw_str_nieq(p, "Custom.", 7))
        p += 7;
    bool negative = false;
    if (*p == '+' || *p == '-') {
        negative = *p == '-';
        p++;
    }
    if (*p == '\0')
        return LW_PARSE_INVALID;
    /* Wie Swift Int(): nur Ziffern; Werte bis ±2^63 werden akzeptiert und auf int gesättigt. */
    unsigned long long magnitude = 0;
    const unsigned long long limit = 9223372036854775808ULL;   /* 2^63 */
    for (; *p != '\0'; p++) {
        if (*p < '0' || *p > '9')
            return LW_PARSE_INVALID;
        magnitude = magnitude * 10 + (unsigned long long)(*p - '0');
        if (magnitude > limit)
            return LW_PARSE_INVALID;
    }
    if (!negative && magnitude == limit)
        return LW_PARSE_INVALID;
    /* LW_UNSET (INT_MIN) bleibt dem Zustand „nicht gesetzt“ vorbehalten. */
    if (negative)
        *value = magnitude >= (unsigned long long)INT_MAX ? -INT_MAX : -(int)magnitude;
    else
        *value = magnitude >= (unsigned long long)INT_MAX ? INT_MAX : (int)magnitude;
    return LW_PARSE_OK;
}

#define DEFINE_ENUM_PARSER(fn, type, table)                         \
    lw_parse_result fn(const char *text, type *value)               \
    {                                                               \
        int v = 0;                                                  \
        lw_parse_result r = parse_enum(text, table, &v);            \
        if (r == LW_PARSE_OK)                                       \
            *value = (type)v;                                       \
        return r;                                                   \
    }

DEFINE_ENUM_PARSER(lw_parse_language, lw_language, language_table)
DEFINE_ENUM_PARSER(lw_parse_media_type, lw_media_type, media_type_table)
DEFINE_ENUM_PARSER(lw_parse_tracking, lw_tracking, tracking_table)
DEFINE_ENUM_PARSER(lw_parse_print_mode, lw_print_mode, print_mode_table)
DEFINE_ENUM_PARSER(lw_parse_backfeed, lw_backfeed, backfeed_table)
DEFINE_ENUM_PARSER(lw_parse_dither, lw_dither_algorithm, dither_table)
DEFINE_ENUM_PARSER(lw_parse_compression, lw_compression, compression_table)
DEFINE_ENUM_PARSER(lw_parse_rotation, int, rotation_table)
DEFINE_ENUM_PARSER(lw_parse_rtc, lw_rtc, rtc_table)
DEFINE_ENUM_PARSER(lw_parse_media_action, lw_media_action, media_action_table)
DEFINE_ENUM_PARSER(lw_parse_fit_mode, lw_fit_mode, fit_mode_table)

lw_parse_result lw_parse_control_chars(const char *text, bool *printer)
{
    int v = 0;
    lw_parse_result r = parse_enum(text, control_chars_table, &v);
    if (r == LW_PARSE_OK)
        *printer = v != 0;
    return r;
}

lw_parse_result lw_parse_control_char(const char *text, int *value)
{
    int v = 0;
    lw_parse_result r = lw_parse_int(text, &v);
    if (r != LW_PARSE_OK)
        return r;
    if (v < LW_CONTROL_CHAR_MIN || v > LW_CONTROL_CHAR_MAX)
        return LW_PARSE_INVALID;
    *value = v;
    return LW_PARSE_OK;
}

lw_parse_result lw_parse_commands(const char *text, lw_buf *out)
{
    if (text[0] == '\0' || lw_str_ieq(text, LW_VALUE_DEFAULT) || lw_str_ieq(text, "None"))
        return LW_PARSE_DEFAULT;
    lw_buf decoded;
    lw_buf_init(&decoded);
    if (!lw_base64url_decode(text, strlen(text), &decoded) ||
        !lw_utf8_valid(decoded.data, decoded.len)) {
        lw_buf_free(&decoded);
        return LW_PARSE_INVALID;
    }
    lw_buf_reset(out);
    lw_buf_append(out, decoded.data, decoded.len);
    lw_buf_free(&decoded);
    return out->failed ? LW_PARSE_INVALID : LW_PARSE_OK;
}

/* ------------------------------------------------------------------------------------------ */
/* Namen und Codes                                                                            */
/* ------------------------------------------------------------------------------------------ */

const char *lw_language_name(lw_language l)
{
    switch (l) {
    case LW_LANGUAGE_ZPL: return "ZPL";
    case LW_LANGUAGE_EPL: return "EPL";
    case LW_LANGUAGE_CPCL: return "CPCL";
    }
    return "?";
}

const char *lw_dither_name(lw_dither_algorithm a)
{
    for (const enum_entry *e = dither_table; e->name != NULL; e++)
        if (e->value == (int)a)
            return e->name;
    return "?";
}

const char *lw_compression_name(lw_compression c)
{
    for (const enum_entry *e = compression_table; e->name != NULL; e++)
        if (e->value == (int)c)
            return e->name;
    return "?";
}

char lw_media_type_code(lw_media_type t)
{
    switch (t) {
    case LW_MEDIA_TYPE_DIRECT_THERMAL: return 'D';
    case LW_MEDIA_TYPE_THERMAL_TRANSFER: return 'T';
    case LW_MEDIA_TYPE_UNSET: break;
    }
    return 0;
}

char lw_tracking_code(lw_tracking t)
{
    switch (t) {
    case LW_TRACKING_GAP: return 'Y';
    case LW_TRACKING_BLACK_MARK: return 'M';
    case LW_TRACKING_CONTINUOUS: return 'N';
    case LW_TRACKING_AUTO: return 'A';
    case LW_TRACKING_NOTCH: return 'W';
    case LW_TRACKING_UNSET: break;
    }
    return 0;
}

char lw_print_mode_code(lw_print_mode m)
{
    switch (m) {
    case LW_PRINT_MODE_TEAR_OFF: return 'T';
    case LW_PRINT_MODE_PEEL_OFF: return 'P';
    case LW_PRINT_MODE_CUTTER: return 'C';
    case LW_PRINT_MODE_DELAYED_CUT: return 'D';
    case LW_PRINT_MODE_REWIND: return 'R';
    case LW_PRINT_MODE_APPLICATOR: return 'A';
    case LW_PRINT_MODE_KIOSK: return 'K';
    case LW_PRINT_MODE_LINERLESS_PEEL:
    case LW_PRINT_MODE_LINERLESS_CUT:
    case LW_PRINT_MODE_LINERLESS_DELAYED_CUT:
    case LW_PRINT_MODE_LINERLESS_REWIND:
    case LW_PRINT_MODE_LINERLESS_TEAR:
    case LW_PRINT_MODE_UNSET: break;
    }
    return 0;
}

bool lw_print_mode_is_linerless(lw_print_mode m)
{
    return m >= LW_PRINT_MODE_LINERLESS_PEEL && m <= LW_PRINT_MODE_LINERLESS_TEAR;
}

const char *lw_print_mode_sgd(lw_print_mode m)
{
    if ((int)m < 0 || (size_t)m >= sizeof(print_mode_sgd) / sizeof(print_mode_sgd[0]))
        return NULL;
    return print_mode_sgd[m];
}

const char *lw_print_mode_sgd_set(lw_print_mode m)
{
    if ((int)m < 0 || (size_t)m >= sizeof(print_mode_sgd_set) / sizeof(print_mode_sgd_set[0]))
        return NULL;
    return print_mode_sgd_set[m];
}

char lw_media_action_code(lw_media_action a)
{
    switch (a) {
    case LW_MEDIA_ACTION_FEED: return 'F';
    case LW_MEDIA_ACTION_CALIBRATE: return 'C';
    case LW_MEDIA_ACTION_LENGTH: return 'L';
    case LW_MEDIA_ACTION_NO_MOTION: return 'N';
    case LW_MEDIA_ACTION_SHORT_CAL: return 'S';
    case LW_MEDIA_ACTION_UNSET: break;
    }
    return 0;
}

const char *lw_fit_mode_name(lw_fit_mode m)
{
    for (const enum_entry *e = fit_mode_table; e->name != NULL; e++)
        if (e->value == (int)m)
            return e->name;
    return "?";
}

const char *lw_rtc_name(lw_rtc r)
{
    for (const enum_entry *e = rtc_table; e->name != NULL; e++)
        if (e->value == (int)r)
            return e->name;
    return "-";
}

char lw_backfeed_code(lw_backfeed b)
{
    switch (b) {
    case LW_BACKFEED_AFTER: return 'A';
    case LW_BACKFEED_BEFORE: return 'B';
    case LW_BACKFEED_NORMAL: return 'N';
    case LW_BACKFEED_OFF: return 'O';
    case LW_BACKFEED_UNSET: break;
    }
    return 0;
}

/* ------------------------------------------------------------------------------------------ */
/* Vorrangauflösung                                                                           */
/* ------------------------------------------------------------------------------------------ */

typedef enum value_kind {
    KIND_LANGUAGE,
    KIND_OPT_INT,       /* Ganzzahl, "Default" → LW_UNSET */
    KIND_INT,           /* Ganzzahl, "Default" → eingebauter Standard */
    KIND_BOOL,
    KIND_MEDIA_TYPE,
    KIND_TRACKING,
    KIND_PRINT_MODE,
    KIND_BACKFEED,
    KIND_DITHER,
    KIND_COMPRESSION,
    KIND_ROTATION,
    KIND_RTC,
    KIND_MEDIA_ACTION,
    KIND_CONTROL_CHARS,
    KIND_CONTROL_CHAR,
    KIND_FIT_MODE
} value_kind;

typedef struct resolver {
    lw_option_lookup_fn lookup;
    void *ctx;
    const lw_logger *log;
    int invalid;
} resolver;

static const char *level_name(lw_option_level level)
{
    switch (level) {
    case LW_LEVEL_ARGV: return "Auftragsoption";
    case LW_LEVEL_MARKED: return "PPD-Auswahl";
    case LW_LEVEL_DEFAULT: return "PPD-Standard";
    }
    return "?";
}

/* Leerraum am Rand abtrennen: Zeiger auf den Anfang, Länge des Kerns. */
static const char *trim_span(const char *v, size_t *len)
{
    while (*v != '\0' && lw_is_space((unsigned char)*v))
        v++;
    size_t n = strlen(v);
    while (n > 0 && lw_is_space((unsigned char)v[n - 1]))
        n--;
    *len = n;
    return v;
}

static lw_parse_result parse_kind(value_kind kind, const char *text, int *value)
{
    lw_parse_result r = LW_PARSE_INVALID;
    switch (kind) {
    case KIND_LANGUAGE: {
        lw_language v = LW_LANGUAGE_ZPL;
        r = lw_parse_language(text, &v);
        *value = (int)v;
        break;
    }
    case KIND_OPT_INT:
    case KIND_INT:
        r = lw_parse_int(text, value);
        break;
    case KIND_BOOL: {
        bool b = false;
        r = lw_parse_bool(text, &b);
        *value = b ? 1 : 0;
        break;
    }
    case KIND_MEDIA_TYPE: {
        lw_media_type v = LW_MEDIA_TYPE_UNSET;
        r = lw_parse_media_type(text, &v);
        *value = (int)v;
        break;
    }
    case KIND_TRACKING: {
        lw_tracking v = LW_TRACKING_UNSET;
        r = lw_parse_tracking(text, &v);
        *value = (int)v;
        break;
    }
    case KIND_PRINT_MODE: {
        lw_print_mode v = LW_PRINT_MODE_UNSET;
        r = lw_parse_print_mode(text, &v);
        *value = (int)v;
        break;
    }
    case KIND_BACKFEED: {
        lw_backfeed v = LW_BACKFEED_UNSET;
        r = lw_parse_backfeed(text, &v);
        *value = (int)v;
        break;
    }
    case KIND_DITHER: {
        lw_dither_algorithm v = LW_DITHER_THRESHOLD;
        r = lw_parse_dither(text, &v);
        *value = (int)v;
        break;
    }
    case KIND_COMPRESSION: {
        lw_compression v = LW_COMPRESSION_Z64;
        r = lw_parse_compression(text, &v);
        *value = (int)v;
        break;
    }
    case KIND_ROTATION:
        r = lw_parse_rotation(text, value);
        break;
    case KIND_RTC: {
        lw_rtc v = LW_RTC_UNSET;
        r = lw_parse_rtc(text, &v);
        *value = (int)v;
        break;
    }
    case KIND_MEDIA_ACTION: {
        lw_media_action v = LW_MEDIA_ACTION_UNSET;
        r = lw_parse_media_action(text, &v);
        *value = (int)v;
        break;
    }
    case KIND_CONTROL_CHARS: {
        bool b = false;
        r = lw_parse_control_chars(text, &b);
        *value = b ? 1 : 0;
        break;
    }
    case KIND_CONTROL_CHAR:
        r = lw_parse_control_char(text, value);
        break;
    case KIND_FIT_MODE: {
        lw_fit_mode v = LW_FIT_AUTO;
        r = lw_parse_fit_mode(text, &v);
        *value = (int)v;
        break;
    }
    }
    return r;
}

/*
 * Sucht den ersten gültigen Wert in Vorrangreihenfolge. Liefert `fallback`, wenn keine Ebene
 * einen gültigen Wert hat oder der gefundene Wert "Default" ist.
 */
static int resolve_value(resolver *r, const char *name, value_kind kind, int fallback)
{
    const char *last_invalid = NULL;
    for (int level = 0; level < LW_LEVEL_COUNT; level++) {
        const char *raw = r->lookup(r->ctx, name, (lw_option_level)level);
        if (raw == NULL)
            continue;
        size_t len;
        const char *start = trim_span(raw, &len);
        if (len == 0)
            continue;
        char text[128];
        lw_parse_result result = LW_PARSE_INVALID;
        int value = fallback;
        if (len < sizeof(text)) {
            memcpy(text, start, len);
            text[len] = '\0';
            result = parse_kind(kind, text, &value);
        }
        if (result == LW_PARSE_OK)
            return value;
        if (result == LW_PARSE_DEFAULT)
            return fallback;
        if (last_invalid == NULL || strcmp(last_invalid, raw) != 0) {
            lw_log(r->log, LW_LOG_WARNING, "Ungültiger Wert „%.60s“ für %s (%s) – wird ignoriert.",
                   raw, name, level_name((lw_option_level)level));
            r->invalid++;
        }
        last_invalid = raw;
    }
    return fallback;
}

/* Wie resolve_value, für die Base64url-kodierten Rohbefehle. */
static void resolve_commands(resolver *r, const char *name, char **out, size_t *out_len)
{
    free(*out);
    *out = NULL;
    *out_len = 0;
    const char *last_invalid = NULL;
    lw_buf decoded;
    lw_buf_init(&decoded);
    for (int level = 0; level < LW_LEVEL_COUNT; level++) {
        const char *raw = r->lookup(r->ctx, name, (lw_option_level)level);
        if (raw == NULL)
            continue;
        size_t len;
        const char *start = trim_span(raw, &len);
        if (len == 0)
            continue;
        char *text = malloc(len + 1);
        if (text == NULL)
            break;
        memcpy(text, start, len);
        text[len] = '\0';
        lw_parse_result result = lw_parse_commands(text, &decoded);
        free(text);
        if (result == LW_PARSE_OK) {
            if (decoded.len > 0) {
                *out = malloc(decoded.len + 1);
                if (*out != NULL) {
                    memcpy(*out, decoded.data, decoded.len);
                    (*out)[decoded.len] = '\0';
                    *out_len = decoded.len;
                }
            }
            break;
        }
        if (result == LW_PARSE_DEFAULT)
            break;
        if (last_invalid == NULL || strcmp(last_invalid, raw) != 0) {
            lw_log(r->log, LW_LOG_WARNING,
                   "Ungültiger Wert für %s (%s): kein Base64url-kodiertes UTF-8 – wird ignoriert.",
                   name, level_name((lw_option_level)level));
            r->invalid++;
        }
        last_invalid = raw;
    }
    lw_buf_free(&decoded);
}

int lw_settings_resolve(lw_settings *s, lw_option_lookup_fn lookup, void *ctx, const lw_logger *log)
{
    resolver r = { lookup, ctx, log, 0 };
    lw_settings def;
    lw_settings_init(&def);

    s->language = (lw_language)resolve_value(&r, LW_OPT_LANGUAGE, KIND_LANGUAGE, (int)def.language);
    s->darkness = resolve_value(&r, LW_OPT_DARKNESS, KIND_OPT_INT, LW_UNSET);
    s->speed = resolve_value(&r, LW_OPT_SPEED, KIND_OPT_INT, LW_UNSET);
    s->media_type = (lw_media_type)resolve_value(&r, LW_OPT_MEDIA_TYPE, KIND_MEDIA_TYPE, LW_MEDIA_TYPE_UNSET);
    s->tracking = (lw_tracking)resolve_value(&r, LW_OPT_TRACKING, KIND_TRACKING, LW_TRACKING_UNSET);
    s->print_mode = (lw_print_mode)resolve_value(&r, LW_OPT_PRINT_MODE, KIND_PRINT_MODE, LW_PRINT_MODE_UNSET);
    s->label_top = resolve_value(&r, LW_OPT_LABEL_TOP, KIND_OPT_INT, LW_UNSET);
    s->label_left = resolve_value(&r, LW_OPT_LABEL_LEFT, KIND_OPT_INT, LW_UNSET);
    s->tear_off = resolve_value(&r, LW_OPT_TEAR_OFF, KIND_OPT_INT, LW_UNSET);
    s->backfeed = (lw_backfeed)resolve_value(&r, LW_OPT_BACKFEED, KIND_BACKFEED, LW_BACKFEED_UNSET);
    s->mirror = resolve_value(&r, LW_OPT_MIRROR, KIND_BOOL, 0) != 0;
    s->negative = resolve_value(&r, LW_OPT_NEGATIVE, KIND_BOOL, 0) != 0;
    s->rotate180 = resolve_value(&r, LW_OPT_ROTATE180, KIND_BOOL, 0) != 0;
    s->dither = (lw_dither_algorithm)resolve_value(&r, LW_OPT_DITHER, KIND_DITHER, (int)def.dither);
    s->threshold = resolve_value(&r, LW_OPT_THRESHOLD, KIND_INT, def.threshold);
    s->compression = (lw_compression)resolve_value(&r, LW_OPT_COMPRESSION, KIND_COMPRESSION, (int)def.compression);
    s->cut_every = resolve_value(&r, LW_OPT_CUT_EVERY, KIND_INT, def.cut_every);
    s->calibrate = resolve_value(&r, LW_OPT_CALIBRATE, KIND_BOOL, 0) != 0;
    s->save_settings = resolve_value(&r, LW_OPT_SAVE_SETTINGS, KIND_BOOL, 0) != 0;
    s->skip_blank = resolve_value(&r, LW_OPT_SKIP_BLANK, KIND_BOOL, 0) != 0;
    resolve_commands(&r, LW_OPT_START_CMD, &s->start_commands, &s->start_commands_len);
    resolve_commands(&r, LW_OPT_END_CMD, &s->end_commands, &s->end_commands_len);
    s->rotation = resolve_value(&r, LW_OPT_ROTATION, KIND_ROTATION, def.rotation);
    s->mark_offset = resolve_value(&r, LW_OPT_MARK_OFFSET, KIND_OPT_INT, LW_UNSET);
    s->stop_at_last = resolve_value(&r, LW_OPT_STOP_AT_LAST, KIND_BOOL, 0) != 0;
    s->stop_offset = resolve_value(&r, LW_OPT_STOP_OFFSET, KIND_INT, def.stop_offset);
    s->pause_every = resolve_value(&r, LW_OPT_PAUSE_EVERY, KIND_INT, def.pause_every);
    s->control_printer = resolve_value(&r, LW_OPT_CONTROL_CHARS, KIND_CONTROL_CHARS, 0) != 0;
    s->format_prefix = resolve_value(&r, LW_OPT_FORMAT_PREFIX, KIND_CONTROL_CHAR, def.format_prefix);
    s->control_prefix = resolve_value(&r, LW_OPT_CONTROL_PREFIX, KIND_CONTROL_CHAR, def.control_prefix);
    s->delimiter = resolve_value(&r, LW_OPT_DELIMITER, KIND_CONTROL_CHAR, def.delimiter);
    s->rtc = (lw_rtc)resolve_value(&r, LW_OPT_RTC, KIND_RTC, LW_RTC_UNSET);
    s->cancel_before = resolve_value(&r, LW_OPT_CANCEL_BEFORE, KIND_BOOL, 0) != 0;
    s->cancel_delay = resolve_value(&r, LW_OPT_CANCEL_DELAY, KIND_INT, def.cancel_delay);
    resolve_commands(&r, LW_OPT_LABEL_START_CMD, &s->label_start_commands, &s->label_start_commands_len);
    resolve_commands(&r, LW_OPT_LABEL_END_CMD, &s->label_end_commands, &s->label_end_commands_len);
    s->power_up_action = (lw_media_action)resolve_value(&r, LW_OPT_POWER_UP_ACTION, KIND_MEDIA_ACTION,
                                                        LW_MEDIA_ACTION_UNSET);
    s->head_close_action = (lw_media_action)resolve_value(&r, LW_OPT_HEAD_CLOSE_ACTION, KIND_MEDIA_ACTION,
                                                          LW_MEDIA_ACTION_UNSET);
    s->fit_to_label = (lw_fit_mode)resolve_value(&r, LW_OPT_FIT_TO_LABEL, KIND_FIT_MODE, (int)def.fit_to_label);
    s->label_width = resolve_value(&r, LW_OPT_LABEL_WIDTH, KIND_INT, def.label_width);
    s->label_height = resolve_value(&r, LW_OPT_LABEL_HEIGHT, KIND_INT, def.label_height);

    lw_settings_clamp(s);
    return r.invalid;
}

/* ------------------------------------------------------------------------------------------ */
/* Protokoll                                                                                  */
/* ------------------------------------------------------------------------------------------ */

static void fmt_opt_int(char *buf, size_t size, int v)
{
    if (v == LW_UNSET)
        snprintf(buf, size, "Drucker");
    else
        snprintf(buf, size, "%d", v);
}

void lw_settings_log(const lw_settings *s, const lw_logger *log)
{
    char dark[16], speed[16], top[16], left[16], tear[16], mark[16];
    fmt_opt_int(dark, sizeof(dark), s->darkness);
    fmt_opt_int(speed, sizeof(speed), s->speed);
    fmt_opt_int(top, sizeof(top), s->label_top);
    fmt_opt_int(left, sizeof(left), s->label_left);
    fmt_opt_int(tear, sizeof(tear), s->tear_off);
    fmt_opt_int(mark, sizeof(mark), s->mark_offset);
    char mt = lw_media_type_code(s->media_type), tr = lw_tracking_code(s->tracking);
    char pm = lw_print_mode_code(s->print_mode), bf = lw_backfeed_code(s->backfeed);
    lw_log(log, LW_LOG_DEBUG,
           "Einstellungen: Sprache=%s Schwärzung=%s Geschwindigkeit=%s Medium=%c Erkennung=%c "
           "Modus=%c Oben=%s Links=%s Abriss=%s Rückzug=%c Spiegeln=%d Negativ=%d 180°=%d "
           "Rasterung=%s Schwelle=%d Kompression=%s Schnitt=%d Kalibrieren=%d Speichern=%d "
           "LeereÜberspringen=%d Startbefehle=%zu B Endbefehle=%zu B",
           lw_language_name(s->language), dark, speed, mt ? mt : '-', tr ? tr : '-',
           pm ? pm : '-', top, left, tear, bf ? bf : '-', s->mirror, s->negative, s->rotate180,
           lw_dither_name(s->dither), s->threshold, lw_compression_name(s->compression),
           s->cut_every, s->calibrate, s->save_settings, s->skip_blank, s->start_commands_len,
           s->end_commands_len);
    char pu = lw_media_action_code(s->power_up_action), hc = lw_media_action_code(s->head_close_action);
    const char *sgd = lw_print_mode_is_linerless(s->print_mode) ? lw_print_mode_sgd_set(s->print_mode) : "-";
    lw_log(log, LW_LOG_DEBUG,
           "Einstellungen (erweitert): Drehung=%d Markenversatz=%s BeiLetztemStoppen=%d Stoppversatz=%d "
           "Pause=%d Steuerzeichen=%s(%c%c%c) RTC=%s Abbrechen=%d Verzögerung=%d ms "
           "Etikettenanfang=%zu B Etikettenende=%zu B Einschalten=%c Kopf=%c Linerless=%s",
           lw_settings_effective_rotation(s), mark, s->stop_at_last, s->stop_offset, s->pause_every,
           s->control_printer ? "Drucker" : "Standard", s->format_prefix, s->control_prefix, s->delimiter,
           lw_rtc_name(s->rtc), s->cancel_before, s->cancel_delay, s->label_start_commands_len,
           s->label_end_commands_len, pu ? pu : '-', hc ? hc : '-', sgd);
    lw_log(log, LW_LOG_DEBUG, "Einstellungen (Etikett): AnEtikettAnpassen=%s Etikett=%d × %d (1/100 mm)",
           lw_fit_mode_name(s->fit_to_label), s->label_width, s->label_height);
}
