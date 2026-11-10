/*
 * lw_util.h – Gemeinsame Hilfen der LabelWerk-CUPS-Filter.
 *
 * Enthält:
 *   - Protokollierung im CUPS-Format ("DEBUG:", "INFO:", "WARNING:", "ERROR:" auf stderr),
 *   - einen wachsenden Bytepuffer (lw_buf) mit „klebrigem“ Fehlerzustand,
 *   - eine Ausgabesenke (lw_sink) für Datei oder Puffer,
 *   - kleine Zeichenkettenhilfen (ASCII, unabhängig von der Locale).
 *
 * Alle Funktionen sind frei von globalem Zustand und damit in Unit-Tests direkt nutzbar.
 *
 * Copyright (c) LabelWerk-Projekt. Zebra ist eine Marke der Zebra Technologies Corp.
 */

#ifndef LW_UTIL_H
#define LW_UTIL_H

#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

#if defined(__GNUC__) || defined(__clang__)
#  define LW_PRINTF(fmt, args) __attribute__((format(printf, fmt, args)))
#else
#  define LW_PRINTF(fmt, args)
#endif

/* ------------------------------------------------------------------------------------------ */
/* Protokollierung                                                                            */
/* ------------------------------------------------------------------------------------------ */

/** Schweregrad einer Meldung; entspricht den CUPS-Präfixen auf stderr. */
typedef enum lw_log_level {
    LW_LOG_DEBUG = 0,
    LW_LOG_INFO,
    LW_LOG_WARNING,
    LW_LOG_ERROR
} lw_log_level;

/**
 * Ziel für Meldungen. `emit` erhält die fertig formatierte Meldung ohne Präfix und ohne
 * Zeilenende. Ein NULL-Logger (oder `emit == NULL`) verwirft alle Meldungen.
 */
typedef struct lw_logger {
    void (*emit)(void *ctx, lw_log_level level, const char *message);
    void *ctx;
} lw_logger;

/** CUPS-Präfix ohne Doppelpunkt ("DEBUG", "INFO", "WARNING", "ERROR"). */
const char *lw_log_prefix(lw_log_level level);

/** Formatiert und meldet eine Nachricht (printf-Syntax). Lange Meldungen werden gekürzt. */
void lw_log(const lw_logger *logger, lw_log_level level, const char *fmt, ...) LW_PRINTF(3, 4);

/** Wie lw_log, mit va_list. */
void lw_logv(const lw_logger *logger, lw_log_level level, const char *fmt, va_list ap) LW_PRINTF(3, 0);

/**
 * Standard-Ausgabe für Filter: schreibt "PRÄFIX: meldung\n" nach `ctx` (FILE *, NULL = stderr).
 * Zeilenumbrüche innerhalb der Meldung werden durch Leerzeichen ersetzt, damit CUPS jede
 * Meldung als genau eine Zeile erhält.
 */
void lw_logger_file_emit(void *ctx, lw_log_level level, const char *message);

/* ------------------------------------------------------------------------------------------ */
/* Bytepuffer                                                                                 */
/* ------------------------------------------------------------------------------------------ */

/**
 * Wachsender Bytepuffer. Schlägt eine Speicheranforderung fehl, wird `failed` gesetzt und alle
 * weiteren Anhänge-Operationen werden ignoriert (klebriger Fehler) – Aufrufer prüfen den Zustand
 * einmal am Ende. `data` ist nach jedem erfolgreichen Anhängen zusätzlich NUL-terminiert
 * (das NUL-Byte zählt nicht zu `len`).
 */
typedef struct lw_buf {
    uint8_t *data;
    size_t len;
    size_t cap;
    bool failed;
} lw_buf;

void lw_buf_init(lw_buf *b);
void lw_buf_free(lw_buf *b);
/** Leert den Puffer, behält aber den Speicher; setzt auch `failed` zurück. */
void lw_buf_reset(lw_buf *b);
/** Stellt Platz für `extra` weitere Bytes (+ NUL) sicher. */
bool lw_buf_reserve(lw_buf *b, size_t extra);
bool lw_buf_append(lw_buf *b, const void *data, size_t len);
bool lw_buf_append_byte(lw_buf *b, uint8_t byte);
bool lw_buf_append_str(lw_buf *b, const char *s);
bool lw_buf_printf(lw_buf *b, const char *fmt, ...) LW_PRINTF(2, 3);

/* ------------------------------------------------------------------------------------------ */
/* Ausgabesenke                                                                               */
/* ------------------------------------------------------------------------------------------ */

/**
 * Abstrakte Ausgabe. `write` liefert 0 bei Erfolg, sonst einen Fehlerwert; danach ist
 * `failed` gesetzt und weitere Schreibversuche werden ignoriert.
 */
typedef struct lw_sink {
    int (*write)(void *ctx, const void *data, size_t len);
    int (*flush)(void *ctx);
    void *ctx;
    bool failed;
} lw_sink;

/** Senke auf einen FILE-Strom (z. B. stdout). */
void lw_sink_init_file(lw_sink *s, FILE *file);
/** Senke in einen Speicherpuffer (für Tests und Zwischenablagen). */
void lw_sink_init_buf(lw_sink *s, lw_buf *buffer);
bool lw_sink_write(lw_sink *s, const void *data, size_t len);
bool lw_sink_puts(lw_sink *s, const char *str);
bool lw_sink_printf(lw_sink *s, const char *fmt, ...) LW_PRINTF(2, 3);
bool lw_sink_flush(lw_sink *s);

/* ------------------------------------------------------------------------------------------ */
/* Zeichenketten (ASCII, Locale-unabhängig)                                                   */
/* ------------------------------------------------------------------------------------------ */

/** Groß-/Kleinschreibung ignorierender Vergleich (nur ASCII). NULL ist nur zu NULL gleich. */
bool lw_str_ieq(const char *a, const char *b);
/** Wie lw_str_ieq, aber nur die ersten `n` Zeichen. */
bool lw_str_nieq(const char *a, const char *b, size_t n);
/** true für Leerraum im Sinne von CUPS-Optionen: Leerzeichen, Tab, CR, LF, VT, FF. */
bool lw_is_space(int c);
/**
 * Kopiert `src` ohne führenden/abschließenden Leerraum nach `dst` (Größe `size`, immer
 * NUL-terminiert). Liefert false, wenn die Zeichenkette gekürzt werden musste.
 */
bool lw_trim_copy(char *dst, size_t size, const char *src);

#endif /* LW_UTIL_H */
