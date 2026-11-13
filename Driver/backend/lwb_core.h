/*
 * lwb_core.h – Reine Logik des CUPS-Backends „labelwerk“ (ohne Ein-/Ausgabe, unter Linux getestet).
 *
 * Das Backend schickt einen Auftrag nicht wie `socket` in einem Stück an den Drucker, sondern
 * Etikett für Etikett (ARCHITECTURE.md §10 „Backend labelwerk“):
 *
 *   - lwb_next_segment zerlegt den Datenstrom in Rohdaten außerhalb von Formaten (Auftragskopf mit
 *     ~SD, ~TA, ~JA …) und vollständige Formate ^XA … ^XZ – mit den Steuerzeichen des Auftrags
 *     (eigene Zeichen „Intern“, Wechsel per ^CC/~CC, ^CT/~CT, ^CD/~CD im Datenstrom) und ohne
 *     Fehltreffer in Binärdaten von ^GFB;
 *   - lwb_format_analyze erkennt, ob ein Format druckt und wie viele Etiketten (^PQ);
 *   - lwb_format_with_quantity setzt die Menge eines Formats neu (Wiederholung nach Neustart);
 *   - lwb_parse_host_status liest die Antwort auf ~HS (drei STX…ETX-Zeilen, wie
 *     LabelWerkStatus.HostStatusParser) aus einem Empfangspuffer, auch zwischen fremden Antworten;
 *   - lwb_parse_uri zerlegt labelwerk://host[:port][/][?optionen].
 *
 * Copyright (c) LabelWerk-Projekt. Zebra ist eine Marke der Zebra Technologies Corp.
 */

#ifndef LWB_CORE_H
#define LWB_CORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "lw_util.h"

/** Standardport der Zebra-Netzwerkdrucker (Rohdaten). */
#define LWB_DEFAULT_PORT 9100

/** Steuerzeichen des ZPL-Datenstroms (^ ~ , oder eigene Zeichen 33…126). */
typedef struct lwb_prefixes {
    uint8_t format;     /* ^ */
    uint8_t control;    /* ~ */
    uint8_t delimiter;  /* , */
} lwb_prefixes;

/** Standardzeichen ^ ~ ,. */
lwb_prefixes lwb_prefixes_standard(void);

/** Art eines Abschnitts des Datenstroms. */
typedef enum lwb_segment_kind {
    LWB_SEGMENT_NONE = 0,   /* noch kein vollständiger Abschnitt – mehr Daten lesen */
    LWB_SEGMENT_RAW,        /* Daten außerhalb eines Formats (sofort senden) */
    LWB_SEGMENT_FORMAT      /* vollständiges Format ^XA … ^XZ (samt folgendem Zeilenende) */
} lwb_segment_kind;

/**
 * Nächster Abschnitt am Anfang von data[0, len).
 *
 * `prefixes` sind die am Anfang gültigen Steuerzeichen; nach einem gelieferten Abschnitt enthält
 * es die an dessen Ende gültigen (Wechsel per ^CC/~CC, ^CT/~CT, ^CD/~CD). `final` = es folgen keine
 * Daten mehr: Dann wird nie LWB_SEGMENT_NONE geliefert, solange len > 0 ist, und ein
 * unvollständiges Format kommt als Rohdaten. Ohne `final` liefert die Funktion LWB_SEGMENT_NONE,
 * wenn der Abschnitt noch nicht vollständig ist (z. B. ^XA ohne ^XZ oder ein abgeschnittener
 * Befehlsname am Ende).
 */
lwb_segment_kind lwb_next_segment(const uint8_t *data, size_t len, bool final, lwb_prefixes *prefixes,
                                  size_t *segment_len);

/** Ergebnis von lwb_format_analyze. */
typedef struct lwb_format_info {
    bool prints;        /* druckt Etiketten (Feld- oder Grafikbefehle, kein ^DF) */
    long quantity;      /* Etiketten laut ^PQ (mindestens 1; 0, wenn das Format nicht druckt) */
    bool has_quantity;  /* ^PQ vorhanden */
} lwb_format_info;

/**
 * Enthält der Abschnitt Daten, in die das Backend keine ~HS-Abfrage einschieben darf? Das sind
 * Downloads (~DG, ~DY, ~DB, ~DS, ~DT, ~DU, ~DN: deren Daten können Binärdaten mit „^XA“ enthalten)
 * und Binärdaten außerhalb von ^GFB (Bytes < 0x09 bzw. 0x0E…0x1F, z. B. eine Firmware). Solche
 * Aufträge sendet das Backend ab dieser Stelle am Stück.
 */
bool lwb_segment_is_download(const uint8_t *data, size_t len, lwb_prefixes prefixes);

/** Wertet ein Format aus (Steuerzeichen am Formatanfang in `prefixes`). */
void lwb_format_analyze(const uint8_t *data, size_t len, lwb_prefixes prefixes, lwb_format_info *info);

/**
 * Schreibt das Format mit der Menge `quantity` nach `out` (ersetzt den ersten Wert von ^PQ bzw.
 * fügt ^PQ vor ^XZ ein). Liefert false bei Speicherfehler oder wenn das Format kein ^XZ hat.
 */
bool lwb_format_with_quantity(const uint8_t *data, size_t len, lwb_prefixes prefixes, long quantity,
                              lw_buf *out);

/** Felder der ~HS-Antwort, die das Backend braucht. */
typedef struct lwb_host_status {
    /* Zeile 1: aaa,b,c,dddd,eee,f,g,h,iii,j,k,l */
    bool paper_out;
    bool paused;
    int formats_in_buffer;
    bool buffer_full;
    bool partial_format;
    bool corrupt_ram;
    bool under_temperature;
    bool over_temperature;
    /* Zeile 2: mmm,n,o,p,q,r,s,t,uuuuuuuu,v,www */
    bool head_open;
    bool ribbon_out;
    bool thermal_transfer;  /* Thermotransfer gewählt: nur dann zählt „Farbband leer“ */
    bool label_waiting;     /* Etikett wartet auf Entnahme (Spendemodus) */
    long labels_remaining;
} lwb_host_status;

/**
 * Sucht die erste vollständige ~HS-Antwort in data[0, len). Liefert true und in `consumed` die
 * Länge bis einschließlich der Antwort (Zeile 3 und CR LF, soweit vorhanden). Ohne vollständige
 * Antwort false; `consumed` nennt dann die Bytes, die sicher verworfen werden können (fremde
 * Antworten, Rauschen vor einem möglichen Anfang).
 */
bool lwb_parse_host_status(const uint8_t *data, size_t len, lwb_host_status *status, size_t *consumed);

/**
 * Sucht in data[0, len) die erste vollständige ^HW-Antwort (STX … ETX mit „DIR“- bzw.
 * „bytes free“-Zeile; andere Rahmen wie ~HS-Antworten werden übersprungen) und prüft, ob sie die
 * Datei `name` (z. B. „R:LWJOB.GRF“) als Eintrag („*R:LWJOB.GRF  1“) enthält. Liefert 1 =
 * vorhanden, 0 = nicht vorhanden, -1 = noch keine vollständige Antwort. `consumed` nennt die Bytes,
 * die verworfen werden können (bei -1 nur die sicher fremden).
 */
int lwb_parse_directory(const uint8_t *data, size_t len, const char *name, size_t *consumed);

/** Gründe, aus denen der Drucker nicht druckt (CUPS printer-state-reasons). */
enum {
    LWB_REASON_MEDIA_EMPTY = 1u << 0,   /* Papier/Etiketten leer   → media-empty-error */
    LWB_REASON_RIBBON_EMPTY = 1u << 1,  /* Farbband leer (nur Thermotransfer) → marker-supply-empty-error */
    LWB_REASON_COVER_OPEN = 1u << 2,    /* Druckkopf offen         → cover-open-error */
    LWB_REASON_PAUSED = 1u << 3         /* Pause am Drucker        → other-warning (siehe labelwerk.c) */
};

unsigned lwb_status_reasons(const lwb_host_status *status);

/** Der Drucker hat nichts mehr zu tun: keine Formate im Puffer, keine Restetiketten, kein Fehler. */
bool lwb_status_idle(const lwb_host_status *status);

/**
 * Zerlegt eine Geräte-URI labelwerk://host[:port][/pfad][?optionen]. IPv6 in eckigen Klammern,
 * Zone als %25 (wird zu %). Ohne Port gilt LWB_DEFAULT_PORT. `options` erhält den Text nach „?“
 * (leer ohne). Liefert false bei fehlendem Host, ungültigem Port oder zu kleinen Puffern.
 */
bool lwb_parse_uri(const char *uri, char *host, size_t host_size, int *port, char *options,
                   size_t options_size);

/**
 * Wert einer Option „name=wert“ aus einer Optionsliste „a=1&b=2“ bzw. „a=1+b=2“ (CUPS-Stil);
 * false, wenn sie fehlt.
 */
bool lwb_uri_option(const char *options, const char *name, char *value, size_t value_size);

#endif /* LWB_CORE_H */
