/*
 * lw_cups.h – Anbindung an libcups für beide Filter: Optionen aus argv[5], PPD-Datei ($PPD),
 * Vorrangauflösung (argv > markierte Auswahl > PPD-Standard), PPD-Attribute, Kopien, Sortierung.
 */

#ifndef LW_CUPS_H
#define LW_CUPS_H

#include <cups/cups.h>
#include <cups/ppd.h>

#include <stdbool.h>

#include "lw_options.h"
#include "lw_util.h"

typedef struct lw_cups_options {
    int num_options;
    cups_option_t *options;
    ppd_file_t *ppd;            /* NULL, wenn keine (lesbare) PPD vorhanden ist */
    char custom_value[256];     /* Puffer für den Wert einer markierten Custom-Auswahl */
} lw_cups_options;

/**
 * Zerlegt die Optionen (argv[5]), öffnet die PPD aus der Umgebungsvariablen PPD und markiert
 * Standards und Auftragsoptionen (ppdMarkDefaults + cupsMarkOptions). Eine fehlende oder
 * unlesbare PPD ist kein Fehler (Warnung, dann gelten Auftragsoptionen und Standardwerte).
 */
void lw_cups_options_open(lw_cups_options *o, const char *argv_options, const lw_logger *log);

void lw_cups_options_close(lw_cups_options *o);

/** Nachschlagefunktion für lw_settings_resolve (`ctx` = lw_cups_options *). */
const char *lw_cups_lookup(void *ctx, const char *name, lw_option_level level);

/** Ganzzahliges PPD-Attribut (z. B. *lwMaxPrintWidthDots: "832"); `fallback`, wenn es fehlt
 *  oder kleiner als `minimum` bzw. ungültig ist (dann mit Warnung). */
int lw_cups_ppd_int(const lw_cups_options *o, const char *name, int minimum, int fallback,
                    const lw_logger *log);

/** Text-PPD-Attribut oder NULL. */
const char *lw_cups_ppd_string(const lw_cups_options *o, const char *name);

/** Kopien aus argv[4] (ungültig → 1 mit Warnung; begrenzt auf LW_MAX_QUANTITY). */
int lw_cups_copies(const char *arg, const lw_logger *log);

/** Sortieren: Option "collate" > "multiple-document-handling" > PPD *Collate > true. */
bool lw_cups_collate(lw_cups_options *o, const lw_logger *log);

/** Auflösung in dpi aus der markierten PPD-Auswahl *Resolution (z. B. "203dpi"); 0 = unbekannt. */
int lw_cups_ppd_resolution(const lw_cups_options *o);

/** Länge der markierten Seitengröße in PostScript-Punkten; 0 = unbekannt. */
float lw_cups_ppd_page_length(const lw_cups_options *o);

#endif /* LW_CUPS_H */
