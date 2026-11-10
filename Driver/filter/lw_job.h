/*
 * lw_job.h – Druckauftragsformat für ZPL II, EPL2 und CPCL (ARCHITECTURE.md §8).
 *
 * Byte-identisch zu `JobEncoder` (LabelWerkImaging). Ablauf:
 *
 *   lw_job_init → lw_job_begin → lw_job_add_page (je Seite) → lw_job_finish → lw_job_free
 *
 * Seiten werden einzeln verarbeitet und sofort kodiert; der Speicherbedarf bleibt unabhängig
 * von der Seitenzahl auf eine Seite begrenzt:
 *
 *   - Vorverarbeitung je Seite (§8): (1) rechts abschneiden auf max_print_width,
 *     (2) negative → invertieren, (3) skip_blank und leer → überspringen,
 *     (4) nur EPL/CPCL: mirror → spiegeln, (5) nur CPCL: rotate180 → drehen.
 *     Seiten ohne Fläche (Breite oder Höhe 0) werden mit einer Warnung übersprungen.
 *   - Kopien: collate == false oder nur eine Seite → je Seite Menge `copies`.
 *     collate == true und > 1 Seite → gesamte Seitenfolge `copies`-mal, je Menge 1.
 *     Da die Seitenzahl erst am Ende feststeht, wird im Sortiermodus die erste Seite
 *     zurückgehalten, bis eine zweite folgt; ab dann werden alle kodierten Seiten zusätzlich in
 *     eine Zwischendatei geschrieben und am Ende `copies − 1`-mal wiederholt.
 */

#ifndef LW_JOB_H
#define LW_JOB_H

#include <stdbool.h>
#include <stdio.h>

#include "lw_bitmap.h"
#include "lw_options.h"
#include "lw_util.h"

/** Höchstmenge je Etikett (^PQ erlaubt bis 99 999 999). */
#define LW_MAX_QUANTITY 99999999

/** Standardlücke in Punkten (EPL `Q`), falls *lwDefaultGapDots fehlt. */
#define LW_DEFAULT_GAP_DOTS 24

typedef struct lw_job_config {
    /** Aufgelöste Einstellungen (werden kopiert und begrenzt; Befehlstexte werden nur
     *  referenziert und müssen bis lw_job_free gültig bleiben). */
    const lw_settings *settings;
    /** Auflösung in dpi (HWResolution); CPCL-Kopfzeile: 203 → 200, sonst dpi. */
    int resolution_dpi;
    /** Maximale Druckbreite in Punkten (≤ 0 = keine Begrenzung). */
    int max_print_width;
    /** Lücke bzw. Markenhöhe in Punkten für EPL `Q` (< 0 = LW_DEFAULT_GAP_DOTS). */
    int gap_dots;
    /** Kopien (Werte < 1 gelten als 1, > LW_MAX_QUANTITY werden begrenzt). */
    int copies;
    /** Sortieren (ganze Seitenfolge wiederholen). */
    bool collate;
} lw_job_config;

typedef struct lw_job_hooks {
    /** Wird nach jedem ausgegebenen Etikett aufgerufen (z. B. für "PAGE: n m"). */
    void (*label_emitted)(void *ctx, int page_number, int quantity);
    /** Öffnet eine leere Zwischendatei (lesen + schreiben). NULL → tmpfile(). */
    FILE *(*open_spool)(void *ctx);
    /** Liefert true, sobald der Auftrag abgebrochen wurde (beendet Sortierwiederholungen). */
    bool (*is_canceled)(void *ctx);
    void *ctx;
    const lw_logger *log;
} lw_job_hooks;

/** Kodierte Seite: CPCL braucht Höhe und Auflösung für die Kopfzeile; der Rest steckt in `body`. */
typedef struct lw_page_record {
    int page_number;
    int height;
    int resolution_dpi;
    lw_buf body;
} lw_page_record;

typedef struct lw_job {
    lw_settings s;              /* begrenzte Kopie (Befehlstexte referenziert) */
    int resolution_dpi;         /* für folgende Seiten; darf je Seite angepasst werden */
    int max_print_width;
    int gap_dots;
    int quantity;               /* begrenzte Kopienzahl */
    bool collate_mode;          /* collate && quantity > 1 */
    lw_sink *out;
    lw_job_hooks hooks;

    bool begun;
    bool finished;
    bool have_pending;          /* Sortiermodus: erste Seite zurückgehalten */
    lw_page_record pending;
    lw_page_record current;
    FILE *spool;
    int spooled_pages;

    long labels_emitted;        /* ausgegebene Etiketten (für ^JUS beim ersten) */
    long pages_accepted;        /* kodierte (nicht übersprungene) Seiten */
    long pages_skipped_blank;
    long pages_skipped_empty;
} lw_job;

/** Initialisiert den Auftrag. Liefert false bei ungültiger Konfiguration. */
bool lw_job_init(lw_job *job, const lw_job_config *config, lw_sink *out, const lw_job_hooks *hooks);

/** Schreibt den Auftragskopf (ZPL: Startbefehle, ~SD, ~TA, ~JC; EPL: Startbefehle). */
bool lw_job_begin(lw_job *job);

/**
 * Verarbeitet eine gerasterte Seite (1 = schwarz). Die Bitmap wird dabei verändert
 * (abgeschnitten, invertiert, gespiegelt, gedreht). Liefert false bei Fehlern (Ausgabe,
 * Speicher, zlib); eine Meldung wurde dann bereits ausgegeben.
 */
bool lw_job_add_page(lw_job *job, lw_bitmap *page, int page_number);

/**
 * Schließt den Auftrag ab: zurückgehaltene Seite ausgeben, Sortierwiederholungen schreiben,
 * Endbefehle anhängen, Ausgabe leeren. Mit `canceled` werden keine Wiederholungen mehr
 * geschrieben und eine zurückgehaltene Seite nur einmal ausgegeben.
 */
bool lw_job_finish(lw_job *job, bool canceled);

void lw_job_free(lw_job *job);

/* Bausteine (öffentlich für Tests) ---------------------------------------------------------- */

/** CPCL-Auflösungswert für "! 0 {res} {res} …": 203 → 200, sonst dpi (≤ 0 → 200). */
int lw_cpcl_resolution(int dpi);

/** Kodiert den Rumpf eines Etiketts (ohne Menge) für die Sprache des Auftrags. */
bool lw_job_encode_body(lw_job *job, const lw_bitmap *page, lw_buf *body);

/** Gibt ein Etikett mit Menge `quantity` aus. */
bool lw_job_emit_label(lw_job *job, const lw_page_record *record, int quantity);

#endif /* LW_JOB_H */
