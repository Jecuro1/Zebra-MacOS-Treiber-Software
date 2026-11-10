/*
 * lw_encode.c – Hex, ACS, Base64, CRC-16/XMODEM, Z64, Base64url und UTF-8.
 */

#if !defined(__APPLE__) && !defined(_DEFAULT_SOURCE)
#  define _DEFAULT_SOURCE 1
#endif

#include "lw_encode.h"

#include <stdlib.h>
#include <string.h>
#include <zlib.h>

static const char hex_digits[16] = {
    '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'A', 'B', 'C', 'D', 'E', 'F'
};

/* ------------------------------------------------------------------------------------------ */
/* Hex                                                                                        */
/* ------------------------------------------------------------------------------------------ */

bool lw_hex_append(lw_buf *out, const uint8_t *data, size_t len)
{
    if (len > (SIZE_MAX - 1) / 2) {
        out->failed = true;
        return false;
    }
    if (!lw_buf_reserve(out, len * 2))
        return false;
    uint8_t *dst = out->data + out->len;
    for (size_t i = 0; i < len; i++) {
        dst[2 * i] = (uint8_t)hex_digits[data[i] >> 4];
        dst[2 * i + 1] = (uint8_t)hex_digits[data[i] & 0x0F];
    }
    out->len += len * 2;
    out->data[out->len] = 0;
    return true;
}

/* ------------------------------------------------------------------------------------------ */
/* ACS                                                                                        */
/* ------------------------------------------------------------------------------------------ */

static inline uint8_t nibble_at(const uint8_t *row, size_t index)
{
    uint8_t b = row[index >> 1];
    return (index & 1) == 0 ? (uint8_t)(b >> 4) : (uint8_t)(b & 0x0F);
}

/* Hängt einen Lauf von `count` gleichen Nibbles an (Gruppen zu höchstens 419). */
static void acs_run(lw_buf *out, uint8_t value, size_t count)
{
    uint8_t digit = (uint8_t)hex_digits[value & 0x0F];
    while (count > 0) {
        size_t n = count < 419 ? count : 419;
        if (n <= 2) {
            for (size_t i = 0; i < n; i++)
                lw_buf_append_byte(out, digit);
        } else {
            size_t twenties = n / 20, ones = n % 20;
            if (twenties > 0)
                lw_buf_append_byte(out, (uint8_t)('g' + twenties - 1));
            if (ones > 0)
                lw_buf_append_byte(out, (uint8_t)('G' + ones - 1));
            lw_buf_append_byte(out, digit);
        }
        count -= n;
    }
}

bool lw_acs_append(lw_buf *out, const uint8_t *data, int bpr, int height)
{
    if (bpr <= 0 || height <= 0)
        return !out->failed;
    const size_t row_bytes = (size_t)bpr;
    const size_t row_nibbles = row_bytes * 2;
    for (int y = 0; y < height; y++) {
        const uint8_t *row = data + (size_t)y * row_bytes;
        if (y > 0 && memcmp(row, row - row_bytes, row_bytes) == 0) {
            lw_buf_append_byte(out, ':');
            continue;
        }
        /* Abschließenden Lauf bestimmen. */
        uint8_t last = nibble_at(row, row_nibbles - 1);
        size_t tail_start = row_nibbles - 1;
        while (tail_start > 0 && nibble_at(row, tail_start - 1) == last)
            tail_start--;
        size_t tail_length = row_nibbles - tail_start;
        size_t body_end = row_nibbles;
        uint8_t terminator = 0;
        if ((last == 0x0 || last == 0xF) && tail_length >= 2) {
            body_end = tail_start;
            terminator = last == 0 ? ',' : '!';
        }
        /* Lauflängen im Rumpf. */
        size_t i = 0;
        while (i < body_end) {
            uint8_t value = nibble_at(row, i);
            size_t j = i + 1;
            while (j < body_end && nibble_at(row, j) == value)
                j++;
            acs_run(out, value, j - i);
            i = j;
        }
        if (terminator != 0)
            lw_buf_append_byte(out, terminator);
    }
    return !out->failed;
}

/* ------------------------------------------------------------------------------------------ */
/* Base64                                                                                     */
/* ------------------------------------------------------------------------------------------ */

static const char b64_alphabet[65] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

bool lw_base64_append(lw_buf *out, const uint8_t *data, size_t len)
{
    if (len / 3 >= (SIZE_MAX - 8) / 4) {
        out->failed = true;
        return false;
    }
    size_t out_len = (len + 2) / 3 * 4;
    if (!lw_buf_reserve(out, out_len))
        return false;
    uint8_t *dst = out->data + out->len;
    size_t i = 0, o = 0;
    while (i + 3 <= len) {
        uint32_t v = (uint32_t)data[i] << 16 | (uint32_t)data[i + 1] << 8 | data[i + 2];
        dst[o++] = (uint8_t)b64_alphabet[v >> 18];
        dst[o++] = (uint8_t)b64_alphabet[(v >> 12) & 63];
        dst[o++] = (uint8_t)b64_alphabet[(v >> 6) & 63];
        dst[o++] = (uint8_t)b64_alphabet[v & 63];
        i += 3;
    }
    size_t rest = len - i;
    if (rest == 1) {
        uint32_t v = (uint32_t)data[i] << 16;
        dst[o++] = (uint8_t)b64_alphabet[v >> 18];
        dst[o++] = (uint8_t)b64_alphabet[(v >> 12) & 63];
        dst[o++] = '=';
        dst[o++] = '=';
    } else if (rest == 2) {
        uint32_t v = (uint32_t)data[i] << 16 | (uint32_t)data[i + 1] << 8;
        dst[o++] = (uint8_t)b64_alphabet[v >> 18];
        dst[o++] = (uint8_t)b64_alphabet[(v >> 12) & 63];
        dst[o++] = (uint8_t)b64_alphabet[(v >> 6) & 63];
        dst[o++] = '=';
    }
    out->len += o;
    out->data[out->len] = 0;
    return true;
}

/* ------------------------------------------------------------------------------------------ */
/* CRC-16/XMODEM                                                                              */
/* ------------------------------------------------------------------------------------------ */

uint16_t lw_crc16_xmodem(uint16_t crc, const uint8_t *data, size_t len)
{
    static uint16_t table[256];
    static bool ready = false;
    if (!ready) {
        /* Tabelle deterministisch berechnen; mehrfaches gleichzeitiges Füllen wäre harmlos,
         * die Filter sind aber ohnehin einfädig. */
        for (unsigned n = 0; n < 256; n++) {
            uint16_t c = (uint16_t)(n << 8);
            for (int k = 0; k < 8; k++)
                c = (c & 0x8000u) != 0 ? (uint16_t)((c << 1) ^ 0x1021u) : (uint16_t)(c << 1);
            table[n] = c;
        }
        ready = true;
    }
    for (size_t i = 0; i < len; i++)
        crc = (uint16_t)((crc << 8) ^ table[((crc >> 8) ^ data[i]) & 0xFFu]);
    return crc;
}

/* ------------------------------------------------------------------------------------------ */
/* Z64                                                                                        */
/* ------------------------------------------------------------------------------------------ */

int lw_z64_append(lw_buf *out, const uint8_t *data, size_t len)
{
    if (out->failed)
        return LW_Z64_NOMEM;
    if ((uLong)len != len)
        return Z_BUF_ERROR;
    size_t restore = out->len;
    uLong bound = compressBound((uLong)len);
    Bytef *tmp = malloc(bound > 0 ? bound : 1);
    if (tmp == NULL)
        return LW_Z64_NOMEM;
    uLongf dest_len = bound;
    static const Bytef empty = 0;
    int rc = compress2(tmp, &dest_len, len > 0 ? data : &empty, (uLong)len, Z_DEFAULT_COMPRESSION);
    if (rc != Z_OK) {
        free(tmp);
        return rc;
    }
    lw_buf_append_str(out, ":Z64:");
    size_t start = out->len;
    lw_base64_append(out, tmp, (size_t)dest_len);
    free(tmp);
    if (out->failed) {
        out->len = restore;
        if (out->data != NULL)
            out->data[restore] = 0;
        return LW_Z64_NOMEM;
    }
    uint16_t crc = lw_crc16_xmodem(0, out->data + start, out->len - start);
    if (!lw_buf_printf(out, ":%04X", (unsigned)crc)) {
        out->len = restore;
        if (out->data != NULL)
            out->data[restore] = 0;
        return LW_Z64_NOMEM;
    }
    return Z_OK;
}

/* ------------------------------------------------------------------------------------------ */
/* Base64url                                                                                  */
/* ------------------------------------------------------------------------------------------ */

static int b64url_value(unsigned char c)
{
    if (c >= 'A' && c <= 'Z')
        return c - 'A';
    if (c >= 'a' && c <= 'z')
        return c - 'a' + 26;
    if (c >= '0' && c <= '9')
        return c - '0' + 52;
    if (c == '-' || c == '+')
        return 62;
    if (c == '_' || c == '/')
        return 63;
    return -1;
}

bool lw_base64url_decode(const char *text, size_t len, lw_buf *out)
{
    size_t padding = 0;
    while (padding < len && text[len - 1 - padding] == '=')
        padding++;
    size_t core = len - padding;
    size_t rem = core % 4;
    if (rem == 1)
        return false;
    /* Wie Swift: auf ein Vielfaches von 4 auffüllen, dann streng dekodieren → höchstens so viele
     * '=' wie zum Auffüllen nötig sind. */
    if (padding > (4 - rem) % 4)
        return false;
    for (size_t i = 0; i < core; i++)
        if (b64url_value((unsigned char)text[i]) < 0)
            return false;
    size_t restore = out->len;
    if (!lw_buf_reserve(out, core / 4 * 3 + 3))
        return false;
    uint32_t acc = 0;
    int bits = 0;
    for (size_t i = 0; i < core; i++) {
        acc = (acc << 6) | (uint32_t)b64url_value((unsigned char)text[i]);
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            lw_buf_append_byte(out, (uint8_t)(acc >> bits));
            acc &= (1u << bits) - 1u;
        }
    }
    if (out->failed) {
        out->len = restore;
        return false;
    }
    return true;
}

/* ------------------------------------------------------------------------------------------ */
/* UTF-8                                                                                      */
/* ------------------------------------------------------------------------------------------ */

bool lw_utf8_valid(const uint8_t *s, size_t len)
{
    size_t i = 0;
    while (i < len) {
        uint8_t c = s[i];
        if (c < 0x80) {
            i++;
            continue;
        }
        size_t need;
        uint32_t cp, min;
        if (c >= 0xC2 && c <= 0xDF) {
            need = 1;
            cp = c & 0x1Fu;
            min = 0x80;
        } else if (c >= 0xE0 && c <= 0xEF) {
            need = 2;
            cp = c & 0x0Fu;
            min = 0x800;
        } else if (c >= 0xF0 && c <= 0xF4) {
            need = 3;
            cp = c & 0x07u;
            min = 0x10000;
        } else {
            return false;   /* 0x80–0xC1 (Fortsetzung/Überlänge) oder > 0xF4 */
        }
        if (len - i - 1 < need)
            return false;
        for (size_t k = 1; k <= need; k++) {
            uint8_t cc = s[i + k];
            if ((cc & 0xC0u) != 0x80u)
                return false;
            cp = (cp << 6) | (cc & 0x3Fu);
        }
        if (cp < min || cp > 0x10FFFFu || (cp >= 0xD800u && cp <= 0xDFFFu))
            return false;
        i += need + 1;
    }
    return true;
}
