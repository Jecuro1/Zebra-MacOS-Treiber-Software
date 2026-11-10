/*
 * lw_cups.c – Optionen, PPD und Auftragsparameter über libcups.
 */

#if !defined(__APPLE__) && !defined(_DEFAULT_SOURCE)
#  define _DEFAULT_SOURCE 1
#endif

#include "lw_cups.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lw_job.h"

void lw_cups_options_open(lw_cups_options *o, const char *argv_options, const lw_logger *log)
{
    memset(o, 0, sizeof(*o));
    o->num_options = cupsParseOptions(argv_options != NULL ? argv_options : "", 0, &o->options);

    const char *ppd_path = getenv("PPD");
    if (ppd_path == NULL || ppd_path[0] == '\0') {
        lw_log(log, LW_LOG_DEBUG, "Keine PPD-Datei angegeben – es gelten Auftragsoptionen und Standardwerte.");
        return;
    }
    o->ppd = ppdOpenFile(ppd_path);
    if (o->ppd == NULL) {
        int line = 0;
        ppd_status_t status = ppdLastError(&line);
        lw_log(log, LW_LOG_WARNING,
               "PPD-Datei „%s“ konnte nicht gelesen werden (%s, Zeile %d) – es gelten "
               "Auftragsoptionen und Standardwerte.",
               ppd_path, ppdErrorString(status), line);
        return;
    }
    ppdMarkDefaults(o->ppd);
    cupsMarkOptions(o->ppd, o->num_options, o->options);
}

void lw_cups_options_close(lw_cups_options *o)
{
    if (o->ppd != NULL)
        ppdClose(o->ppd);
    cupsFreeOptions(o->num_options, o->options);
    memset(o, 0, sizeof(*o));
}

/* Aktueller Wert einer markierten "Custom"-Auswahl (erster Parameter) als Text. */
static const char *custom_choice_value(lw_cups_options *o, const char *name)
{
    ppd_coption_t *copt = ppdFindCustomOption(o->ppd, name);
    if (copt == NULL)
        return NULL;
    ppd_cparam_t *param = ppdFirstCustomParam(copt);
    if (param == NULL)
        return NULL;
    switch (param->type) {
    case PPD_CUSTOM_INT:
        snprintf(o->custom_value, sizeof(o->custom_value), "%d", param->current.custom_int);
        return o->custom_value;
    case PPD_CUSTOM_REAL:
    case PPD_CUSTOM_POINTS:
    case PPD_CUSTOM_CURVE:
    case PPD_CUSTOM_INVCURVE: {
        float v = param->type == PPD_CUSTOM_REAL ? param->current.custom_real
                : param->type == PPD_CUSTOM_POINTS ? param->current.custom_points
                : param->type == PPD_CUSTOM_CURVE ? param->current.custom_curve
                : param->current.custom_invcurve;
        long rounded = (long)(v < 0 ? v - 0.5f : v + 0.5f);
        snprintf(o->custom_value, sizeof(o->custom_value), "%ld", rounded);
        return o->custom_value;
    }
    case PPD_CUSTOM_STRING:
    case PPD_CUSTOM_PASSCODE:
    case PPD_CUSTOM_PASSWORD:
        return param->current.custom_string;
    default:
        return NULL;
    }
}

const char *lw_cups_lookup(void *ctx, const char *name, lw_option_level level)
{
    lw_cups_options *o = ctx;
    switch (level) {
    case LW_LEVEL_ARGV:
        return cupsGetOption(name, o->num_options, o->options);
    case LW_LEVEL_MARKED: {
        if (o->ppd == NULL)
            return NULL;
        ppd_choice_t *choice = ppdFindMarkedChoice(o->ppd, name);
        if (choice == NULL)
            return NULL;
        if (strcmp(choice->choice, "Custom") == 0)
            return custom_choice_value(o, name);
        return choice->choice;
    }
    case LW_LEVEL_DEFAULT: {
        if (o->ppd == NULL)
            return NULL;
        ppd_option_t *option = ppdFindOption(o->ppd, name);
        if (option == NULL || option->defchoice[0] == '\0')
            return NULL;
        return option->defchoice;
    }
    }
    return NULL;
}

const char *lw_cups_ppd_string(const lw_cups_options *o, const char *name)
{
    if (o->ppd == NULL)
        return NULL;
    ppd_attr_t *attr = ppdFindAttr(o->ppd, name, NULL);
    if (attr == NULL || attr->value == NULL || attr->value[0] == '\0')
        return NULL;
    return attr->value;
}

int lw_cups_ppd_int(const lw_cups_options *o, const char *name, int minimum, int fallback,
                    const lw_logger *log)
{
    const char *raw = lw_cups_ppd_string(o, name);
    if (raw == NULL)
        return fallback;
    char text[64];
    int value = 0;
    if (!lw_trim_copy(text, sizeof(text), raw) || lw_parse_int(text, &value) != LW_PARSE_OK ||
        value < minimum) {
        lw_log(log, LW_LOG_WARNING, "PPD-Attribut *%s: „%.40s“ ist ungültig und wird ignoriert.", name, raw);
        return fallback;
    }
    return value;
}

int lw_cups_copies(const char *arg, const lw_logger *log)
{
    char text[64];
    int copies = 1;
    if (arg == NULL || !lw_trim_copy(text, sizeof(text), arg) || lw_parse_int(text, &copies) != LW_PARSE_OK) {
        lw_log(log, LW_LOG_WARNING, "Ungültige Kopienzahl „%.40s“ – es wird 1 Kopie gedruckt.",
               arg != NULL ? arg : "");
        return 1;
    }
    if (copies < 1)
        copies = 1;
    if (copies > LW_MAX_QUANTITY) {
        lw_log(log, LW_LOG_WARNING, "Kopienzahl %d auf %d begrenzt.", copies, LW_MAX_QUANTITY);
        copies = LW_MAX_QUANTITY;
    }
    return copies;
}

bool lw_cups_collate(lw_cups_options *o, const lw_logger *log)
{
    char text[64];
    bool value = true;
    const char *v = cupsGetOption("collate", o->num_options, o->options);
    if (v != NULL) {
        if (lw_trim_copy(text, sizeof(text), v) && lw_parse_bool(text, &value) == LW_PARSE_OK)
            return value;
        lw_log(log, LW_LOG_WARNING, "Ungültiger Wert „%.40s“ für collate – wird ignoriert.", v);
    }
    v = cupsGetOption("multiple-document-handling", o->num_options, o->options);
    if (v != NULL) {
        if (strstr(v, "uncollated") != NULL)
            return false;
        if (strstr(v, "collated") != NULL || strncmp(v, "single-document", 15) == 0)
            return true;
    }
    if (o->ppd != NULL) {
        ppd_choice_t *choice = ppdFindMarkedChoice(o->ppd, "Collate");
        if (choice != NULL && lw_trim_copy(text, sizeof(text), choice->choice) &&
            lw_parse_bool(text, &value) == LW_PARSE_OK)
            return value;
    }
    return true;
}

int lw_cups_ppd_resolution(const lw_cups_options *o)
{
    if (o->ppd == NULL)
        return 0;
    const char *text = NULL;
    ppd_choice_t *choice = ppdFindMarkedChoice(o->ppd, "Resolution");
    if (choice != NULL)
        text = choice->choice;
    if (text == NULL) {
        ppd_attr_t *attr = ppdFindAttr(o->ppd, "DefaultResolution", NULL);
        if (attr != NULL)
            text = attr->value;
    }
    if (text == NULL)
        return 0;
    /* "203dpi" oder "203x203dpi" → 203 */
    int dpi = 0;
    for (const char *p = text; *p >= '0' && *p <= '9'; p++) {
        dpi = dpi * 10 + (*p - '0');
        if (dpi > 100000)
            return 0;
    }
    return dpi;
}

float lw_cups_ppd_page_length(const lw_cups_options *o)
{
    if (o->ppd == NULL)
        return 0.0f;
    ppd_size_t *size = ppdPageSize(o->ppd, NULL);
    if (size == NULL || size->length <= 0.0f)
        return 0.0f;
    return size->length;
}
