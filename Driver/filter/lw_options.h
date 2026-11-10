/*
 * lw_options.h – Druckeinstellungen und CUPS-Optionen (ARCHITECTURE.md §9).
 *
 * Entspricht `PrintSettings` + `CUPSOptionName` in LabelWerkCore. Die Auflösung der Werte ist
 * unabhängig von libcups: Der Filter liefert eine Nachschlagefunktion, die je Option und Ebene
 * (Auftragsoption aus argv[5], markierte PPD-Auswahl, PPD-Standard) einen Wert oder NULL
 * zurückgibt. Vorrang: argv[5] vor markierter Auswahl vor PPD-Standard vor eingebautem Standard.
 * Ein ungültiger Wert wird mit einer Warnung übergangen; dann gilt die nächste Ebene.
 */

#ifndef LW_OPTIONS_H
#define LW_OPTIONS_H

#include <limits.h>
#include <stdbool.h>
#include <stddef.h>

#include "lw_dither.h"
#include "lw_util.h"

/* Optionsnamen – identisch zu CUPSOptionName (Swift) und den PPD-Dateien. */
#define LW_OPT_LANGUAGE      "lwLanguage"
#define LW_OPT_DARKNESS      "lwDarkness"
#define LW_OPT_SPEED         "lwSpeed"
#define LW_OPT_MEDIA_TYPE    "lwMediaType"
#define LW_OPT_TRACKING      "lwMediaTracking"
#define LW_OPT_PRINT_MODE    "lwPrintMode"
#define LW_OPT_LABEL_TOP     "lwLabelTop"
#define LW_OPT_LABEL_LEFT    "lwLabelLeft"
#define LW_OPT_TEAR_OFF      "lwTearOff"
#define LW_OPT_BACKFEED      "lwBackfeed"
#define LW_OPT_MIRROR        "lwMirror"
#define LW_OPT_NEGATIVE      "lwNegative"
#define LW_OPT_ROTATE180     "lwRotate180"
#define LW_OPT_DITHER        "lwDither"
#define LW_OPT_THRESHOLD     "lwThreshold"
#define LW_OPT_COMPRESSION   "lwCompression"
#define LW_OPT_CUT_EVERY     "lwCutEvery"
#define LW_OPT_CALIBRATE     "lwCalibrate"
#define LW_OPT_SAVE_SETTINGS "lwSaveSettings"
#define LW_OPT_SKIP_BLANK    "lwSkipBlank"
#define LW_OPT_START_CMD     "lwStartCmd"
#define LW_OPT_END_CMD       "lwEndCmd"

/* Zusätzliche PPD-Attribute (*lwModel: "zd421t" …). */
#define LW_ATTR_MODEL           "lwModel"
#define LW_ATTR_MAX_PRINT_WIDTH "lwMaxPrintWidthDots"
#define LW_ATTR_DEFAULT_GAP     "lwDefaultGapDots"

/** Wert für „Druckereinstellung beibehalten“. */
#define LW_VALUE_DEFAULT "Default"

/** Markiert eine nicht gesetzte optionale Ganzzahl (kein Befehl wird gesendet). */
#define LW_UNSET INT_MIN

typedef enum lw_language {
    LW_LANGUAGE_ZPL = 0,
    LW_LANGUAGE_EPL,
    LW_LANGUAGE_CPCL
} lw_language;

typedef enum lw_compression {
    LW_COMPRESSION_Z64 = 0,
    LW_COMPRESSION_ACS,
    LW_COMPRESSION_HEX
} lw_compression;

typedef enum lw_media_type {
    LW_MEDIA_TYPE_UNSET = 0,
    LW_MEDIA_TYPE_DIRECT_THERMAL,     /* ^MTD */
    LW_MEDIA_TYPE_THERMAL_TRANSFER    /* ^MTT */
} lw_media_type;

typedef enum lw_tracking {
    LW_TRACKING_UNSET = 0,
    LW_TRACKING_GAP,          /* ^MNY */
    LW_TRACKING_BLACK_MARK,   /* ^MNM */
    LW_TRACKING_CONTINUOUS,   /* ^MNN */
    LW_TRACKING_AUTO          /* ^MNA */
} lw_tracking;

typedef enum lw_print_mode {
    LW_PRINT_MODE_UNSET = 0,
    LW_PRINT_MODE_TEAR_OFF,     /* T */
    LW_PRINT_MODE_PEEL_OFF,     /* P */
    LW_PRINT_MODE_CUTTER,       /* C */
    LW_PRINT_MODE_DELAYED_CUT,  /* D */
    LW_PRINT_MODE_REWIND,       /* R */
    LW_PRINT_MODE_APPLICATOR,   /* A */
    LW_PRINT_MODE_KIOSK         /* K */
} lw_print_mode;

typedef enum lw_backfeed {
    LW_BACKFEED_UNSET = 0,
    LW_BACKFEED_AFTER,    /* ^JSA */
    LW_BACKFEED_BEFORE,   /* ^JSB */
    LW_BACKFEED_NORMAL,   /* ^JSN */
    LW_BACKFEED_OFF       /* ^JSO */
} lw_backfeed;

/** Aufgelöste Druckeinstellungen eines Auftrags. */
typedef struct lw_settings {
    lw_language language;
    int darkness;            /* 0…30 oder LW_UNSET */
    int speed;               /* 1…14 oder LW_UNSET */
    lw_media_type media_type;
    lw_tracking tracking;
    lw_print_mode print_mode;
    int label_top;           /* −120…120 oder LW_UNSET */
    int label_left;          /* −9999…9999 oder LW_UNSET */
    int tear_off;            /* −120…120 oder LW_UNSET */
    lw_backfeed backfeed;
    bool mirror;
    bool negative;
    bool rotate180;
    lw_dither_algorithm dither;
    int threshold;           /* 1…254 */
    lw_compression compression;
    int cut_every;           /* 0…9999 */
    bool calibrate;
    bool save_settings;
    bool skip_blank;
    /* Dekodierte Rohbefehle (UTF-8, eigener Speicher, NUL-terminiert; Länge ohne NUL). */
    char *start_commands;
    size_t start_commands_len;
    char *end_commands;
    size_t end_commands_len;
} lw_settings;

/** Ebene, aus der ein Optionswert stammt (in Vorrangreihenfolge). */
typedef enum lw_option_level {
    LW_LEVEL_ARGV = 0,   /* argv[5]: Auftrags- und Warteschlangenoptionen */
    LW_LEVEL_MARKED,     /* markierte PPD-Auswahl (ppdMarkDefaults + cupsMarkOptions) */
    LW_LEVEL_DEFAULT     /* *Default… der PPD */
} lw_option_level;

#define LW_LEVEL_COUNT 3

/** Liefert den Rohwert einer Option auf einer Ebene oder NULL. */
typedef const char *(*lw_option_lookup_fn)(void *ctx, const char *name, lw_option_level level);

/** Ergebnis der Wertzerlegung. */
typedef enum lw_parse_result {
    LW_PARSE_OK = 0,
    LW_PARSE_DEFAULT,   /* "Default" → eingebauter Standard bzw. nicht setzen */
    LW_PARSE_INVALID
} lw_parse_result;

/** Eingebaute Standards (= PrintSettings.default): ZPL, Schwelle 128, Z64, alles andere aus. */
void lw_settings_init(lw_settings *s);
/** Gibt die Befehlspuffer frei und setzt auf Standard zurück. */
void lw_settings_free(lw_settings *s);

/**
 * Löst alle Optionen aus §9 auf und begrenzt die Werte (lw_settings_clamp).
 * `s` muss mit lw_settings_init vorbereitet sein. Liefert die Anzahl übergangener ungültiger
 * Werte (jeweils mit WARNING gemeldet).
 */
int lw_settings_resolve(lw_settings *s, lw_option_lookup_fn lookup, void *ctx, const lw_logger *log);

/** Begrenzt alle Werte auf gültige Bereiche (wie PrintSettings.clamped()). */
void lw_settings_clamp(lw_settings *s);

/** Meldet die wirksamen Einstellungen als DEBUG-Zeile. */
void lw_settings_log(const lw_settings *s, const lw_logger *log);

/* Einzelne Zerleger (öffentlich für Tests). Eingaben ohne führenden/abschließenden Leerraum. */
lw_parse_result lw_parse_bool(const char *text, bool *value);
/** Ganzzahl mit optionalem Vorzeichen und optionalem Präfix "Custom." – sättigt auf int. */
lw_parse_result lw_parse_int(const char *text, int *value);
lw_parse_result lw_parse_language(const char *text, lw_language *value);
lw_parse_result lw_parse_media_type(const char *text, lw_media_type *value);
lw_parse_result lw_parse_tracking(const char *text, lw_tracking *value);
lw_parse_result lw_parse_print_mode(const char *text, lw_print_mode *value);
lw_parse_result lw_parse_backfeed(const char *text, lw_backfeed *value);
lw_parse_result lw_parse_dither(const char *text, lw_dither_algorithm *value);
lw_parse_result lw_parse_compression(const char *text, lw_compression *value);
/**
 * Base64url-kodierte Rohbefehle (UTF-8). "Default"/"None"/"" → leer (LW_PARSE_DEFAULT).
 * Bei LW_PARSE_OK erhält `out` die dekodierten Bytes (ersetzt den Inhalt).
 */
lw_parse_result lw_parse_commands(const char *text, lw_buf *out);

/* Namen für Meldungen und Befehle. */
const char *lw_language_name(lw_language l);          /* "ZPL", "EPL", "CPCL" */
const char *lw_dither_name(lw_dither_algorithm a);    /* "Threshold" … */
const char *lw_compression_name(lw_compression c);    /* "Z64", "ACS", "Hex" */
char lw_media_type_code(lw_media_type t);             /* 'D' / 'T' / 0 */
char lw_tracking_code(lw_tracking t);                 /* 'Y' / 'M' / 'N' / 'A' / 0 */
char lw_print_mode_code(lw_print_mode m);             /* 'T' … 'K' / 0 */
char lw_backfeed_code(lw_backfeed b);                 /* 'A' / 'B' / 'N' / 'O' / 0 */

#endif /* LW_OPTIONS_H */
