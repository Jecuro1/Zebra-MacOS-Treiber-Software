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
}

void lw_settings_free(lw_settings *s)
{
    free(s->start_commands);
    free(s->end_commands);
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
    { NULL, 0 }
};

static const enum_entry print_mode_table[] = {
    { "TearOff", LW_PRINT_MODE_TEAR_OFF }, { "PeelOff", LW_PRINT_MODE_PEEL_OFF },
    { "Cutter", LW_PRINT_MODE_CUTTER }, { "DelayedCut", LW_PRINT_MODE_DELAYED_CUT },
    { "Rewind", LW_PRINT_MODE_REWIND }, { "Applicator", LW_PRINT_MODE_APPLICATOR },
    { "Kiosk", LW_PRINT_MODE_KIOSK },
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
    case LW_PRINT_MODE_UNSET: break;
    }
    return 0;
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
    KIND_COMPRESSION
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
    char dark[16], speed[16], top[16], left[16], tear[16];
    fmt_opt_int(dark, sizeof(dark), s->darkness);
    fmt_opt_int(speed, sizeof(speed), s->speed);
    fmt_opt_int(top, sizeof(top), s->label_top);
    fmt_opt_int(left, sizeof(left), s->label_left);
    fmt_opt_int(tear, sizeof(tear), s->tear_off);
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
}
