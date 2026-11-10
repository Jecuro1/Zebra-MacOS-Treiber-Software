/*
 * lw_encode.h – Kodierungen für Grafikdaten und Optionswerte.
 *
 *   - ASCII-Hex (Großbuchstaben, ohne Trenner),
 *   - Zebra „Alternative Compression Scheme“ (ACS) – identische Kodierentscheidungen wie
 *     `ACS.encode` in LabelWerkImaging,
 *   - Base64 (Standardalphabet, mit Padding, ohne Zeilenumbrüche),
 *   - CRC-16/XMODEM (Polynom 0x1021, Startwert 0),
 *   - Z64 (`:Z64:` + Base64(zlib compress2, Z_DEFAULT_COMPRESSION) + `:` + CRC als %04X),
 *   - Base64url-Dekodierung (Optionen lwStartCmd/lwEndCmd) und UTF-8-Prüfung.
 *
 * Alle Anhänge-Funktionen schreiben in einen lw_buf und liefern false bei Speichermangel.
 */

#ifndef LW_ENCODE_H
#define LW_ENCODE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "lw_util.h"

/** Hängt `len` Bytes als ASCII-Hex in Großbuchstaben an. */
bool lw_hex_append(lw_buf *out, const uint8_t *data, size_t len);

/**
 * Hängt Bitmapdaten (`height` Zeilen à `bpr` Bytes) ACS-komprimiert an.
 *
 * Regeln je Zeile (identisch zur Swift-Implementierung):
 *   - Zeile identisch zur Vorzeile → `:`.
 *   - Sonst Lauflängen über die Hex-Nibbles. Ein abschließender Lauf aus `0` bzw. `F` mit
 *     mindestens zwei Nibbles wird durch `,` bzw. `!` ersetzt.
 *   - Läufe ≤ 2 werden als Ziffern ausgeschrieben, längere als Zähler + Ziffer:
 *     `g`…`z` = 20…400 (Vielfache von 20), danach `G`…`Y` = 1…19. Läufe > 419 werden in
 *     Gruppen zu höchstens 419 geteilt.
 */
bool lw_acs_append(lw_buf *out, const uint8_t *data, int bpr, int height);

/** Hängt Base64 (Standardalphabet, mit Padding) an. */
bool lw_base64_append(lw_buf *out, const uint8_t *data, size_t len);

/** CRC-16/XMODEM, fortsetzbar: Start mit crc = 0. Prüfwert "123456789" → 0x31C3. */
uint16_t lw_crc16_xmodem(uint16_t crc, const uint8_t *data, size_t len);

/** Ergebnis von lw_z64_append bei Speichermangel (zlib-Codes sind ≤ 2). */
#define LW_Z64_NOMEM (-100)

/**
 * Hängt `:Z64:<base64>:<CRC>` an. Liefert 0 (Z_OK) bei Erfolg, sonst den zlib-Fehlercode
 * oder LW_Z64_NOMEM; der Puffer ist dann unverändert in der Länge vor dem Aufruf.
 */
int lw_z64_append(lw_buf *out, const uint8_t *data, size_t len);

/**
 * Dekodiert Base64url (Alphabet A–Z a–z 0–9 - _; zusätzlich + / akzeptiert) mit optionalem
 * Padding – Regeln wie `CUPSCommandEncoding.decode` in Swift. Hängt die Bytes an `out` an.
 * Liefert false bei ungültigen Zeichen oder unmöglicher Länge (`out` bleibt dann unverändert).
 */
bool lw_base64url_decode(const char *text, size_t len, lw_buf *out);

/** Prüft auf gültiges UTF-8 (keine Überlängen, keine Surrogate, ≤ U+10FFFF). */
bool lw_utf8_valid(const uint8_t *s, size_t len);

#endif /* LW_ENCODE_H */
