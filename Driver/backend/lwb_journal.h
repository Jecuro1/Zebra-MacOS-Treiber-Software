/*
 * lwb_journal.h – Druckjournal des CUPS-Backends „labelwerk“ (ARCHITECTURE.md §10 „Druckjournal“).
 *
 * Jeder Auftrag landet nach dem Druck in einem Journal, aus dem die App („Nachdrucken“, „Letztes
 * Etikett nochmal“) einzelne Etiketten erneut drucken kann – auch Aufträge aus anderen Programmen.
 *
 *   <dir>/<warteschlange>/<UTC yyyyMMdd-HHmmss>-<auftrag>/job.zpl    Auftrag wie gesendet
 *                                                       /meta.json   Beschreibung (Version 1)
 *
 * <dir> ist /Users/Shared/LabelWerk/Journal (vom Paket angelegt; die CUPS-Sandbox erlaubt Schreiben
 * unter /Users/Shared/), für Tests LW_JOURNAL_DIR. Ein Eintrag entsteht unter „.<name>.tmp“ und wird
 * erst vollständig umbenannt – Leser übergehen Namen mit Punkt am Anfang. Aufbewahrt werden je
 * Warteschlange die neuesten LWB_JOURNAL_MAX_ENTRIES Einträge und höchstens LWB_JOURNAL_MAX_BYTES;
 * Aufträge über LWB_JOURNAL_MAX_JOB_BYTES kommen nicht ins Journal.
 *
 * Copyright (c) LabelWerk-Projekt. Zebra ist eine Marke der Zebra Technologies Corp.
 */

#ifndef LWB_JOURNAL_H
#define LWB_JOURNAL_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <time.h>

#include "lw_util.h"
#include "lwb_core.h"

#define LWB_JOURNAL_DEFAULT_DIR "/Users/Shared/LabelWerk/Journal"
#define LWB_JOURNAL_MAX_ENTRIES 30
#define LWB_JOURNAL_MAX_BYTES (50LL * 1024 * 1024)
#define LWB_JOURNAL_MAX_JOB_BYTES (20u * 1024u * 1024u)

/** Ein druckendes Format in job.zpl. */
typedef struct lwb_journal_label {
    size_t offset;
    size_t length;
    long quantity;
} lwb_journal_label;

/** Formate eines Auftrags (lwb_journal_scan). */
typedef struct lwb_journal_scan_result {
    lwb_journal_label *labels;
    size_t count;
    /** Bytes vor dem ersten druckenden Format (Auftragskopf samt nicht druckender Formate). */
    size_t prologue_length;
} lwb_journal_scan_result;

/**
 * Zerlegt den Auftrag data[0, len) (Steuerzeichen am Anfang `prefixes`) in druckende Formate.
 * false bei Speicherfehler. Freigeben mit lwb_journal_scan_free.
 */
bool lwb_journal_scan(const uint8_t *data, size_t len, lwb_prefixes prefixes, lwb_journal_scan_result *result);
void lwb_journal_scan_free(lwb_journal_scan_result *result);

/** Beschreibung eines Eintrags (meta.json). */
typedef struct lwb_journal_meta {
    const char *queue;
    long job_id;
    const char *title;
    const char *user;
    time_t date;
    const char *printer_uri;
    long printed;        /* gedruckte Etiketten des Auftrags (ohne Nachdrucke) */
    long reprinted;      /* Nachdrucke nach Etiketten-/Farbbandende */
    int copies;
    const char *status;  /* "completed", "cancelled", "failed" */
} lwb_journal_meta;

/** Schreibt meta.json (UTF-8, ungültige Bytes als „?“) nach `out`. */
bool lwb_journal_meta_json(const lwb_journal_meta *meta, const lwb_journal_scan_result *scan, lw_buf *out);

/** Ordnername eines Eintrags: „20261113-221503-42“ (UTC). */
void lwb_journal_entry_name(time_t date, long job_id, char *out, size_t size);

/**
 * Warteschlangenname als Ordnername: „/“, Steuerzeichen und ein Punkt am Anfang werden zu „_“;
 * leer → „unbekannt“.
 */
void lwb_journal_safe_name(const char *queue, char *out, size_t size);

/**
 * Schreibt einen Eintrag unter root/<queue>/ (Ordner werden bei Bedarf angelegt, 0755, Dateien
 * 0644) und räumt danach auf (lwb_journal_prune). `meta->printed` < 0 = alle Etiketten (Summe der
 * Mengen × Kopien). 0 = geschrieben, 1 = nichts zu schreiben (kein druckendes Format); sonst -1 und
 * eine Beschreibung in `error`.
 */
int lwb_journal_write(const char *root, const lwb_journal_meta *meta, const uint8_t *data, size_t len,
                      lwb_prefixes prefixes, char *error, size_t error_size);

/**
 * Behält in `queue_dir` die neuesten `max_entries` Einträge (nach Namen) und löscht ältere sowie
 * alle, mit denen die Summe (vom neuesten an) `max_bytes` überschritte. Liefert die Zahl der
 * gelöschten Einträge, -1 bei Fehler.
 */
int lwb_journal_prune(const char *queue_dir, int max_entries, long long max_bytes);

#endif /* LWB_JOURNAL_H */
