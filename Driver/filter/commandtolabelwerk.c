/*
 * commandtolabelwerk – CUPS-Befehlsfilter (application/vnd.cups-command) für LabelWerk.
 *
 * Aufruf (CUPS-Konvention):
 *     commandtolabelwerk job-id user title copies options [file]
 *
 * Liest eine CUPS-Befehlsdatei (erste Zeile "#CUPS-COMMAND", danach ein Befehl je Zeile,
 * Kommentare mit "#") und erzeugt Druckerbefehle in der Sprache aus lwLanguage:
 *
 *   PrintSelfTestPage  ZPL: ~WC (Konfigurationsetikett)   EPL: U   CPCL: Selbsttest-Etikett
 *                      (Kopfdaten, Modell, Auflösung, Druckbreite, Druckkopf-Testmuster)
 *   Calibrate          ZPL: ~JC                           EPL: xa  CPCL: SGD
 *                      ! U1 do "ezpl.manual_calibration" ""
 *   Clean              Thermodrucker reinigen den Druckkopf nicht per Befehl: keine Daten,
 *                      nur eine INFO-Meldung mit der Anleitung (sicherer No-op – kein
 *                      Vorschub, keine Kalibrierung).
 *   AutoConfigure      keine Daten; INFO-Meldung (Einstellungen kommen aus PPD/LabelWerk.app).
 *   ReportLevels       keine Daten (Thermodrucker haben keine Füllstände).
 *   unbekannt          DEBUG-Meldung, wird ignoriert.
 *
 * Mit lwControlChars=Printer (eigene Steuerzeichen des Druckers) beginnen die ZPL-Befehle ~WC
 * und ~JC mit lwControlPrefix statt ~.
 *
 * Exitcode: 0 = Erfolg, 1 = Fehler (Datei nicht lesbar, keine Befehlsdatei, Ausgabefehler).
 */

#if !defined(__APPLE__) && !defined(_DEFAULT_SOURCE)
#  define _DEFAULT_SOURCE 1
#endif

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lw_cups.h"
#include "lw_job.h"
#include "lw_options.h"
#include "lw_util.h"

#define COMMAND_LINE_MAX 1024

/** Standarddruckbreite für das CPCL-Selbsttest-Etikett (2-Zoll-Mobildrucker, 203 dpi). */
#define CPCL_DEFAULT_WIDTH 384

typedef struct command_context {
    lw_sink *out;
    const lw_logger *log;
    lw_language language;
    char control_prefix;        /* ZPL-Steuerpräfix: '~' bzw. lwControlPrefix */
    const char *model;
    int resolution_dpi;
    int print_width;
    float page_length_points;
    int commands_written;
} command_context;

/* Ersetzt nicht druckbare bzw. Nicht-ASCII-Zeichen (CPCL-Schriften kennen nur ASCII sicher). */
static void ascii_copy(char *dst, size_t size, const char *src)
{
    size_t n = 0;
    for (const char *p = src; p != NULL && *p != '\0' && n + 1 < size; p++) {
        unsigned char c = (unsigned char)*p;
        dst[n++] = (c >= 0x20 && c < 0x7F) ? (char)c : '?';
    }
    dst[n] = '\0';
}

/* Selbsttest-Etikett in CPCL (Mobildrucker haben kein ~WC-Gegenstück). */
static void cpcl_self_test(command_context *c)
{
    int dpi = c->resolution_dpi > 0 ? c->resolution_dpi : 203;
    int res = lw_cpcl_resolution(dpi);
    int width = c->print_width > 0 ? c->print_width : CPCL_DEFAULT_WIDTH;
    int height = 400;
    if (c->page_length_points > 0.0f) {
        height = (int)(c->page_length_points * (float)dpi / 72.0f + 0.5f);
        if (height < 280)
            height = 280;
        if (height > 1600)
            height = 1600;
    }
    char model[48];
    ascii_copy(model, sizeof(model), c->model != NULL ? c->model : "Zebra");

    lw_sink *o = c->out;
    lw_sink_printf(o, "! 0 %d %d %d 1\r\n", res, res, height);
    lw_sink_printf(o, "PAGE-WIDTH %d\r\n", width);
    lw_sink_printf(o, "BOX 0 0 %d %d 2\r\n", width - 1, height - 1);
    lw_sink_puts(o, "TEXT 4 0 16 12 LabelWerk Selbsttest\r\n");
    lw_sink_printf(o, "TEXT 7 0 16 70 Modell: %s\r\n", model);
    lw_sink_printf(o, "TEXT 7 0 16 96 Aufloesung: %d dpi\r\n", dpi);
    lw_sink_printf(o, "TEXT 7 0 16 122 Druckbreite: %d Punkte\r\n", width);
    lw_sink_puts(o, "TEXT 7 0 16 148 Druckkopf-Test:\r\n");
    /* Durchgehender Balken über die volle Breite – fehlende Heizpunkte zeigen sich als
     * weiße Linien; darunter ein Treppenmuster für die Gleichmäßigkeit. */
    lw_sink_printf(o, "LINE 0 176 %d 176 24\r\n", width - 1);
    int step = width / 8 > 0 ? width / 8 : 1;
    for (int i = 0; i < 8; i++) {
        int x0 = i * step;
        int x1 = (i == 7 ? width : (i + 1) * step) - 1;
        if (x1 > x0)
            lw_sink_printf(o, "LINE %d %d %d %d %d\r\n", x0, 208 + (i % 2) * 12, x1, 208 + (i % 2) * 12, 12);
    }
    lw_sink_puts(o, "FORM\r\n");
    lw_sink_puts(o, "PRINT\r\n");
}

static void cmd_print_self_test(command_context *c)
{
    switch (c->language) {
    case LW_LANGUAGE_ZPL:
        lw_sink_printf(c->out, "%cWC\n", c->control_prefix);
        break;
    case LW_LANGUAGE_EPL:
        lw_sink_puts(c->out, "\nU\n");
        break;
    case LW_LANGUAGE_CPCL:
        cpcl_self_test(c);
        break;
    }
    c->commands_written++;
    lw_log(c->log, LW_LOG_INFO, "Selbsttest-/Konfigurationsetikett wird gedruckt.");
}

static void cmd_calibrate(command_context *c)
{
    switch (c->language) {
    case LW_LANGUAGE_ZPL:
        lw_sink_printf(c->out, "%cJC\n", c->control_prefix);
        break;
    case LW_LANGUAGE_EPL:
        lw_sink_puts(c->out, "\nxa\n");
        break;
    case LW_LANGUAGE_CPCL:
        lw_sink_puts(c->out, "! U1 do \"ezpl.manual_calibration\" \"\"\r\n");
        break;
    }
    c->commands_written++;
    lw_log(c->log, LW_LOG_INFO, "Medienkalibrierung wurde gestartet.");
}

static void cmd_clean(command_context *c)
{
    lw_log(c->log, LW_LOG_INFO,
           "Druckkopfreinigung ist bei Thermodruckern nicht per Befehl möglich: Drucker "
           "ausschalten, Druckkopf abkühlen lassen und mit einem Reinigungsstift "
           "(Isopropanol) von der Mitte nach außen reinigen.");
}

static void cmd_auto_configure(command_context *c)
{
    lw_log(c->log, LW_LOG_INFO,
           "Automatische Konfiguration: Die Einstellungen stammen aus der Warteschlange – "
           "Anpassungen bitte in LabelWerk vornehmen.");
}

static void cmd_report_levels(command_context *c)
{
    lw_log(c->log, LW_LOG_DEBUG, "ReportLevels: Thermodrucker melden keine Füllstände.");
}

typedef struct command_entry {
    const char *name;
    void (*handler)(command_context *c);
} command_entry;

static const command_entry commands[] = {
    { "PrintSelfTestPage", cmd_print_self_test },
    { "Calibrate", cmd_calibrate },
    { "Clean", cmd_clean },
    { "AutoConfigure", cmd_auto_configure },
    { "ReportLevels", cmd_report_levels },
    { NULL, NULL }
};

/* Verarbeitet eine Zeile; liefert false nur bei Ausgabefehlern. */
static bool handle_line(command_context *c, char *line)
{
    char trimmed[COMMAND_LINE_MAX];
    lw_trim_copy(trimmed, sizeof(trimmed), line);
    if (trimmed[0] == '\0' || trimmed[0] == '#')
        return true;
    /* Befehlsname bis zum ersten Leerraum; Argumente werden von keinem Befehl benötigt. */
    size_t n = 0;
    while (trimmed[n] != '\0' && !lw_is_space((unsigned char)trimmed[n]))
        n++;
    trimmed[n] = '\0';
    for (const command_entry *e = commands; e->name != NULL; e++) {
        if (lw_str_ieq(trimmed, e->name)) {
            lw_log(c->log, LW_LOG_DEBUG, "Befehl %s (%s)", e->name, lw_language_name(c->language));
            e->handler(c);
            return !c->out->failed;
        }
    }
    lw_log(c->log, LW_LOG_DEBUG, "Unbekannter Befehl „%.80s“ wird ignoriert.", trimmed);
    return true;
}

/* Liest eine Zeile beliebiger Länge; überlange Zeilen werden gekürzt. false bei EOF. */
static bool read_line(FILE *in, char *buf, size_t size)
{
    if (fgets(buf, (int)size, in) == NULL)
        return false;
    size_t len = strlen(buf);
    if (len > 0 && buf[len - 1] != '\n' && !feof(in)) {
        int ch;
        while ((ch = fgetc(in)) != EOF && ch != '\n')
            ;
    }
    return true;
}

int main(int argc, char *argv[])
{
    lw_logger log = { lw_logger_file_emit, stderr };

    if (argc < 6 || argc > 7) {
        fprintf(stderr, "Usage: %s job-id user title copies options [file]\n",
                argc > 0 ? argv[0] : "commandtolabelwerk");
        return 1;
    }

    lw_cups_options opts;
    lw_cups_options_open(&opts, argv[5], &log);
    lw_settings settings;
    lw_settings_init(&settings);
    lw_settings_resolve(&settings, lw_cups_lookup, &opts, &log);

    FILE *in = stdin;
    if (argc == 7) {
        in = fopen(argv[6], "rb");
        if (in == NULL) {
            lw_log(&log, LW_LOG_ERROR, "Befehlsdatei „%s“ kann nicht geöffnet werden: %s", argv[6], strerror(errno));
            lw_settings_free(&settings);
            lw_cups_options_close(&opts);
            return 1;
        }
    }

    lw_sink out;
    lw_sink_init_file(&out, stdout);
    command_context ctx = {
        .out = &out,
        .log = &log,
        .language = settings.language,
        .control_prefix = settings.control_printer ? (char)settings.control_prefix : '~',
        .model = lw_cups_ppd_string(&opts, LW_ATTR_MODEL),
        .resolution_dpi = lw_cups_ppd_resolution(&opts),
        .print_width = lw_cups_ppd_int(&opts, LW_ATTR_MAX_PRINT_WIDTH, 1, 0, &log),
        .page_length_points = lw_cups_ppd_page_length(&opts),
        .commands_written = 0,
    };

    int status = 0;
    char line[COMMAND_LINE_MAX];
    bool header_seen = false;
    while (read_line(in, line, sizeof(line))) {
        if (!header_seen) {
            char trimmed[COMMAND_LINE_MAX];
            lw_trim_copy(trimmed, sizeof(trimmed), line);
            if (trimmed[0] == '\0')
                continue;
            if (strncmp(trimmed, "#CUPS-COMMAND", 13) != 0) {
                lw_log(&log, LW_LOG_ERROR, "Ungültige Befehlsdatei: „#CUPS-COMMAND“ fehlt in der ersten Zeile.");
                status = 1;
                break;
            }
            header_seen = true;
            continue;
        }
        if (!handle_line(&ctx, line)) {
            status = 1;
            break;
        }
    }
    if (status == 0 && ferror(in)) {
        lw_log(&log, LW_LOG_ERROR, "Die Befehlsdatei konnte nicht gelesen werden.");
        status = 1;
    } else if (status == 0 && !header_seen) {
        lw_log(&log, LW_LOG_ERROR, "Leere Befehlsdatei (erwartet „#CUPS-COMMAND“).");
        status = 1;
    }
    if (status == 0 && (!lw_sink_flush(&out) || out.failed)) {
        lw_log(&log, LW_LOG_ERROR, "Die Druckerbefehle konnten nicht geschrieben werden.");
        status = 1;
    }
    if (status == 0 && ctx.commands_written == 0)
        lw_log(&log, LW_LOG_DEBUG, "Keine Druckerbefehle erzeugt.");

    if (in != stdin)
        fclose(in);
    lw_settings_free(&settings);
    lw_cups_options_close(&opts);
    return status;
}
