/*
 * test_main.c – C-Unit-Tests der LabelWerk-Filterbibliothek (ohne externes Framework).
 *
 * Aufruf:  test_main [Namensfilter …]   (ohne Filter laufen alle Tests)
 * Exitcode 0, wenn alle Prüfungen bestehen.
 *
 * Abgedeckt: CRC-16, Base64, Hex, Base64url, UTF-8, ACS (bekannte Kodierungen + Rundreise),
 * Z64 (Rundreise mit zlib), Bitmap-Operationen, alle sechs Rasterverfahren (gegen eine
 * unabhängige Naivimplementierung), Rasterumrechnung aller Farbräume/Bittiefen/Anordnungen,
 * Optionszerlegung und Vorrangregeln, ZPL/EPL/CPCL-Schreiber byte-genau, Kopien/Sortierung,
 * Abbruch, leere und flächenlose Seiten; Windows-Optionen: Drehung 90/180/270°, Markenversatz,
 * Bei letztem Element stoppen, Pause, eigene Steuerzeichen, RTC (^ST) mit fester/schrittweiser
 * Uhr, ~JA mit Wartezeit, Etikettenbefehle, ^MF, Linerless-Modi (SGD), Seitenkerben.
 */

#if !defined(__APPLE__) && !defined(_DEFAULT_SOURCE)
#  define _DEFAULT_SOURCE 1
#endif

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <zlib.h>

#include "lw_bitmap.h"
#include "lw_dither.h"
#include "lw_encode.h"
#include "lw_job.h"
#include "lw_options.h"
#include "lw_raster.h"
#include "lw_util.h"

/* ------------------------------------------------------------------------------------------ */
/* Mini-Testrahmen                                                                            */
/* ------------------------------------------------------------------------------------------ */

static long g_checks = 0;
static long g_failures = 0;
static const char *g_current = "";

#define CHECK(cond)                                                                        \
    do {                                                                                   \
        g_checks++;                                                                        \
        if (!(cond)) {                                                                     \
            g_failures++;                                                                  \
            fprintf(stderr, "  FEHLER [%s] %s:%d: %s\n", g_current, __FILE__, __LINE__, #cond); \
        }                                                                                  \
    } while (0)

#define CHECK_INT(actual, expected)                                                        \
    do {                                                                                   \
        long long a_ = (long long)(actual), e_ = (long long)(expected);                    \
        g_checks++;                                                                        \
        if (a_ != e_) {                                                                    \
            g_failures++;                                                                  \
            fprintf(stderr, "  FEHLER [%s] %s:%d: %s = %lld, erwartet %lld\n", g_current,  \
                    __FILE__, __LINE__, #actual, a_, e_);                                  \
        }                                                                                  \
    } while (0)

static void check_bytes(const char *file, int line, const void *actual, size_t actual_len,
                        const void *expected, size_t expected_len)
{
    g_checks++;
    if (actual_len == expected_len && (expected_len == 0 || memcmp(actual, expected, expected_len) == 0))
        return;
    g_failures++;
    const uint8_t *a = actual, *e = expected;
    size_t i = 0;
    while (i < actual_len && i < expected_len && a[i] == e[i])
        i++;
    fprintf(stderr, "  FEHLER [%s] %s:%d: Bytes verschieden (Länge %zu, erwartet %zu, erste Abweichung bei %zu)\n",
            g_current, file, line, actual_len, expected_len, i);
    fprintf(stderr, "    ist:      ");
    for (size_t k = 0; k < actual_len && k < 160; k++)
        fputc(a[k] >= 0x20 && a[k] < 0x7F ? a[k] : '.', stderr);
    fprintf(stderr, "\n    erwartet: ");
    for (size_t k = 0; k < expected_len && k < 160; k++)
        fputc(e[k] >= 0x20 && e[k] < 0x7F ? e[k] : '.', stderr);
    fputc('\n', stderr);
}

#define CHECK_BYTES(actual, alen, expected, elen) check_bytes(__FILE__, __LINE__, actual, alen, expected, elen)
#define CHECK_BUF_STR(buf, str) check_bytes(__FILE__, __LINE__, (buf).data, (buf).len, str, strlen(str))

/* Deterministischer Zufall (xorshift32). */
static uint32_t g_rng = 0x12345678u;
static uint32_t rnd(void)
{
    uint32_t x = g_rng;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    g_rng = x;
    return x;
}

/* ------------------------------------------------------------------------------------------ */
/* Kodierungen                                                                                */
/* ------------------------------------------------------------------------------------------ */

static void test_crc16(void)
{
    const char *s = "123456789";
    CHECK_INT(lw_crc16_xmodem(0, (const uint8_t *)s, 9), 0x31C3);
    CHECK_INT(lw_crc16_xmodem(0, NULL, 0), 0);
    uint16_t part = lw_crc16_xmodem(0, (const uint8_t *)s, 4);
    CHECK_INT(lw_crc16_xmodem(part, (const uint8_t *)s + 4, 5), 0x31C3);
    CHECK_INT(lw_crc16_xmodem(0, (const uint8_t *)"A", 1), 0x58E5);
}

static void test_base64(void)
{
    static const char *in[] = { "", "f", "fo", "foo", "foob", "fooba", "foobar" };
    static const char *out[] = { "", "Zg==", "Zm8=", "Zm9v", "Zm9vYg==", "Zm9vYmE=", "Zm9vYmFy" };
    for (int i = 0; i < 7; i++) {
        lw_buf b;
        lw_buf_init(&b);
        CHECK(lw_base64_append(&b, (const uint8_t *)in[i], strlen(in[i])));
        CHECK_BYTES(b.data, b.len, out[i], strlen(out[i]));
        lw_buf_free(&b);
    }
    lw_buf b;
    lw_buf_init(&b);
    const uint8_t bin[] = { 0xFB, 0xFF, 0xBF };
    lw_base64_append(&b, bin, 3);
    CHECK_BUF_STR(b, "+/+/");
    lw_buf_free(&b);
}

static void test_hex(void)
{
    lw_buf b;
    lw_buf_init(&b);
    const uint8_t data[] = { 0x00, 0xAB, 0xFF, 0x10, 0x9c };
    CHECK(lw_hex_append(&b, data, sizeof(data)));
    CHECK_BUF_STR(b, "00ABFF109C");
    CHECK(b.data[b.len] == 0);
    lw_buf_free(&b);
}

static bool decode_url(const char *text, lw_buf *out)
{
    lw_buf_reset(out);
    return lw_base64url_decode(text, strlen(text), out);
}

static void test_base64url(void)
{
    lw_buf b;
    lw_buf_init(&b);
    CHECK(decode_url("XlhB", &b));
    CHECK_BUF_STR(b, "^XA");
    CHECK(decode_url("Zg", &b));
    CHECK_BUF_STR(b, "f");
    CHECK(decode_url("Zg==", &b));
    CHECK_BUF_STR(b, "f");
    CHECK(decode_url("Zg=", &b));          /* Swift füllt auf "Zg==" auf */
    CHECK_BUF_STR(b, "f");
    CHECK(decode_url("Zm8", &b));
    CHECK_BUF_STR(b, "fo");
    CHECK(!decode_url("Zm8==", &b));       /* zu viel Padding */
    CHECK(!decode_url("Zm9v=", &b));
    CHECK(!decode_url("Z", &b));           /* Länge mod 4 = 1 */
    CHECK(!decode_url("Zm9v!", &b));
    CHECK(!decode_url("Zm 9v", &b));       /* Leerraum ist ungültig */
    CHECK(!decode_url("Zg===", &b));
    CHECK(decode_url("", &b));
    CHECK_INT(b.len, 0);
    CHECK(decode_url("-_-_", &b));         /* url-sicheres Alphabet */
    const uint8_t e1[] = { 0xFB, 0xFF, 0xBF };
    CHECK_BYTES(b.data, b.len, e1, 3);
    CHECK(decode_url("+/+/", &b));         /* Standardalphabet wird ebenfalls akzeptiert */
    CHECK_BYTES(b.data, b.len, e1, 3);
    /* Rundreise über alle Längen 0…40 */
    for (size_t len = 0; len <= 40; len++) {
        uint8_t src[40];
        for (size_t i = 0; i < len; i++)
            src[i] = (uint8_t)rnd();
        lw_buf enc;
        lw_buf_init(&enc);
        lw_base64_append(&enc, src, len);
        for (size_t i = 0; i < enc.len; i++) {
            if (enc.data[i] == '+') enc.data[i] = '-';
            else if (enc.data[i] == '/') enc.data[i] = '_';
        }
        while (enc.len > 0 && enc.data[enc.len - 1] == '=')
            enc.data[--enc.len] = 0;
        CHECK(decode_url((const char *)enc.data, &b));
        CHECK_BYTES(b.data, b.len, src, len);
        lw_buf_free(&enc);
    }
    lw_buf_free(&b);
}

static void test_utf8(void)
{
    CHECK(lw_utf8_valid((const uint8_t *)"Hallo ^XA", 9));
    CHECK(lw_utf8_valid((const uint8_t *)"\xC3\xA4", 2));               /* ä */
    CHECK(lw_utf8_valid((const uint8_t *)"\xE2\x82\xAC", 3));           /* € */
    CHECK(lw_utf8_valid((const uint8_t *)"\xF0\x9F\x98\x80", 4));       /* 😀 */
    CHECK(lw_utf8_valid((const uint8_t *)"\x00", 1));                   /* NUL ist gültig */
    CHECK(!lw_utf8_valid((const uint8_t *)"\xC0\x80", 2));              /* Überlänge */
    CHECK(!lw_utf8_valid((const uint8_t *)"\xE0\x80\xAF", 3));          /* Überlänge */
    CHECK(!lw_utf8_valid((const uint8_t *)"\xED\xA0\x80", 3));          /* Surrogat */
    CHECK(!lw_utf8_valid((const uint8_t *)"\xF4\x90\x80\x80", 4));      /* > U+10FFFF */
    CHECK(!lw_utf8_valid((const uint8_t *)"\x80", 1));
    CHECK(!lw_utf8_valid((const uint8_t *)"\xE2\x82", 2));              /* abgeschnitten */
    CHECK(!lw_utf8_valid((const uint8_t *)"\xF5\x80\x80\x80", 4));
    CHECK(!lw_utf8_valid((const uint8_t *)"\xC3\x28", 2));
}

/* --- ACS --------------------------------------------------------------------------------- */

static void acs_expect(const uint8_t *data, int bpr, int height, const char *expected)
{
    lw_buf b;
    lw_buf_init(&b);
    CHECK(lw_acs_append(&b, data, bpr, height));
    CHECK_BUF_STR(b, expected);
    lw_buf_free(&b);
}

/* Unabhängiger ACS-Dekodierer (für Rundreisen). */
static void acs_decode(const char *s, size_t len, int bpr, size_t total, uint8_t *out)
{
    size_t total_nibbles = total * 2, row = (size_t)bpr * 2, pos = 0;
    int pending = 0;
    memset(out, 0, total);
#define PUT(v) do { if (pos < total_nibbles) { if ((pos & 1) == 0) out[pos >> 1] = (uint8_t)((out[pos >> 1] & 0x0F) | ((v) << 4)); else out[pos >> 1] = (uint8_t)((out[pos >> 1] & 0xF0) | (v)); } pos++; } while (0)
#define GETN(i) (((i) & 1) == 0 ? (out[(i) >> 1] >> 4) : (out[(i) >> 1] & 0x0F))
    for (size_t i = 0; i < len && pos < total_nibbles; i++) {
        char c = s[i];
        if ((c >= '0' && c <= '9') || (c >= 'A' && c <= 'F')) {
            int v = c <= '9' ? c - '0' : c - 'A' + 10;
            int n = pending > 0 ? pending : 1;
            for (int k = 0; k < n; k++)
                PUT(v);
            pending = 0;
        } else if (c >= 'G' && c <= 'Y') {
            pending += c - 'G' + 1;
        } else if (c >= 'g' && c <= 'z') {
            pending += (c - 'g' + 1) * 20;
        } else if (c == ',' || c == '!') {
            size_t end = (pos / row + 1) * row;
            while (pos < end)
                PUT(c == ',' ? 0 : 15);
            pending = 0;
        } else if (c == ':') {
            size_t r = pos / row, end = (r + 1) * row;
            while (pos < end) {
                int v = r == 0 ? 0 : GETN(pos - row);
                PUT(v);
            }
            pending = 0;
        }
    }
#undef PUT
#undef GETN
}

static void test_acs_known(void)
{
    const uint8_t white[2] = { 0, 0 }, black[2] = { 0xFF, 0xFF };
    acs_expect(white, 2, 1, ",");
    acs_expect(black, 2, 1, "!");
    const uint8_t r1[] = { 0xFF, 0x00 };
    acs_expect(r1, 2, 1, "FF,");
    const uint8_t r2[] = { 0x0F };
    acs_expect(r2, 1, 1, "0F");
    const uint8_t r3[] = { 0x12, 0x34 };
    acs_expect(r3, 2, 1, "1234");
    const uint8_t r4[] = { 0x00, 0x00, 0xA0, 0x00 };
    acs_expect(r4, 4, 1, "J0A,");
    const uint8_t r5[] = { 0xF0 };          /* Lauf F×1, dann 0×1 → kein Abschluss */
    acs_expect(r5, 1, 1, "F0");
    const uint8_t r6[] = { 0x12, 0x34, 0x12, 0x34, 0x00, 0x00 };   /* Wiederholung → ':' */
    acs_expect(r6, 2, 3, "1234:,");
    const uint8_t r7[] = { 0x00, 0x00, 0x00, 0x00 };               /* zweite Zeile ':' */
    acs_expect(r7, 2, 2, ",:");
    uint8_t r8[25];
    memset(r8, 0x33, sizeof(r8));            /* 50 × '3' → h (40) + P (10) + 3 */
    acs_expect(r8, 25, 1, "hP3");
    uint8_t r9[250];
    memset(r9, 0x77, sizeof(r9));            /* 500 × '7' → zY7 (419) + jG7 (81) */
    acs_expect(r9, 250, 1, "zY7jG7");
    uint8_t r10[10];
    memset(r10, 0x55, sizeof(r10));          /* 20 × '5' → g5 */
    acs_expect(r10, 10, 1, "g5");
    const uint8_t r11[] = { 0x55, 0x5A };    /* 3 × '5' → I5 */
    acs_expect(r11, 2, 1, "I5A");
    const uint8_t r12[] = { 0xAB, 0xAB };
    acs_expect(r12, 2, 1, "ABAB");
    uint8_t r13[21];
    memset(r13, 0xFF, sizeof(r13));
    r13[0] = 0x0F;                           /* 0 + 41 × F → Abschluss '!' */
    acs_expect(r13, 21, 1, "0!");
    uint8_t r14[210];                        /* 419 × '0' + 1 × '1' → zY0 1 */
    memset(r14, 0, sizeof(r14));
    r14[209] = 0x01;
    acs_expect(r14, 210, 1, "zY01");
    uint8_t r15[211];                        /* 421 × '0' + '1' → zY0 + 00 (2 einzeln) + 1 */
    memset(r15, 0, sizeof(r15));
    r15[210] = 0x01;
    acs_expect(r15, 211, 1, "zY0001");
}

static void test_acs_roundtrip(void)
{
    for (int iter = 0; iter < 400; iter++) {
        int bpr = 1 + (int)(rnd() % 40);
        int height = 1 + (int)(rnd() % 12);
        size_t total = (size_t)bpr * (size_t)height;
        uint8_t *data = malloc(total);
        uint8_t *back = malloc(total);
        int style = (int)(rnd() % 4);
        for (size_t i = 0; i < total; i++) {
            switch (style) {
            case 0: data[i] = (uint8_t)rnd(); break;
            case 1: data[i] = (rnd() % 5 == 0) ? (uint8_t)rnd() : 0; break;
            case 2: data[i] = (rnd() % 3 == 0) ? 0xFF : 0x00; break;
            default: data[i] = (uint8_t)(i / (size_t)bpr % 3 == 0 ? 0xAA : (rnd() % 7 == 0 ? 0x0F : 0xF0)); break;
            }
        }
        /* Zeilen gelegentlich wiederholen */
        for (int y = 1; y < height; y++)
            if (rnd() % 3 == 0)
                memcpy(data + (size_t)y * (size_t)bpr, data + (size_t)(y - 1) * (size_t)bpr, (size_t)bpr);
        lw_buf b;
        lw_buf_init(&b);
        CHECK(lw_acs_append(&b, data, bpr, height));
        for (size_t i = 0; i < b.len; i++) {
            char c = (char)b.data[i];
            CHECK((c >= '0' && c <= '9') || (c >= 'A' && c <= 'Y') || (c >= 'g' && c <= 'z') ||
                  c == ',' || c == '!' || c == ':');
        }
        acs_decode((const char *)b.data, b.len, bpr, total, back);
        CHECK_BYTES(back, total, data, total);
        lw_buf_free(&b);
        free(data);
        free(back);
    }
}

/* --- Z64 --------------------------------------------------------------------------------- */

static int b64_value(int c)
{
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
}

static void test_z64(void)
{
    size_t sizes[] = { 0, 1, 2, 3, 100, 4096, 100000 };
    for (size_t si = 0; si < sizeof(sizes) / sizeof(sizes[0]); si++) {
        size_t n = sizes[si];
        uint8_t *src = malloc(n > 0 ? n : 1);
        for (size_t i = 0; i < n; i++)
            src[i] = (uint8_t)((i % 97 < 50) ? 0 : rnd());
        lw_buf b;
        lw_buf_init(&b);
        lw_buf_append_str(&b, "^GFA,");
        CHECK_INT(lw_z64_append(&b, src, n), Z_OK);
        const char *text = (const char *)b.data + 5;
        size_t len = b.len - 5;
        CHECK(strncmp(text, ":Z64:", 5) == 0);
        const char *colon = strrchr(text, ':');
        CHECK(colon != NULL && (size_t)(text + len - colon) == 5);
        const char *b64 = text + 5;
        size_t b64len = (size_t)(colon - b64);
        unsigned crc = 0;
        CHECK(sscanf(colon + 1, "%4X", &crc) == 1);
        CHECK_INT(crc, lw_crc16_xmodem(0, (const uint8_t *)b64, b64len));
        for (int k = 1; k <= 4; k++) {
            char c = colon[k];
            CHECK((c >= '0' && c <= '9') || (c >= 'A' && c <= 'F'));
        }
        /* Base64 dekodieren und entpacken */
        CHECK(b64len % 4 == 0);
        uint8_t *packed = malloc(b64len / 4 * 3 + 3);
        size_t plen = 0;
        uint32_t acc = 0;
        int bits = 0;
        for (size_t i = 0; i < b64len && b64[i] != '='; i++) {
            int v = b64_value((unsigned char)b64[i]);
            CHECK(v >= 0);
            acc = (acc << 6) | (uint32_t)v;
            bits += 6;
            if (bits >= 8) {
                bits -= 8;
                packed[plen++] = (uint8_t)(acc >> bits);
                acc &= (1u << bits) - 1u;
            }
        }
        uint8_t *unpacked = malloc(n + 16);
        uLongf ulen = (uLongf)(n + 16);
        CHECK_INT(uncompress(unpacked, &ulen, packed, (uLong)plen), Z_OK);
        CHECK_BYTES(unpacked, (size_t)ulen, src, n);
        /* identisch zu compress2(Z_DEFAULT_COMPRESSION) */
        uLongf clen = compressBound((uLong)n);
        uint8_t *ref = malloc(clen);
        compress2(ref, &clen, n > 0 ? src : (const Bytef *)"", (uLong)n, Z_DEFAULT_COMPRESSION);
        CHECK_BYTES(packed, plen, ref, (size_t)clen);
        free(ref);
        free(unpacked);
        free(packed);
        free(src);
        lw_buf_free(&b);
    }
}

/* ------------------------------------------------------------------------------------------ */
/* Bitmaps                                                                                    */
/* ------------------------------------------------------------------------------------------ */

static void random_bitmap(lw_bitmap *bm, int w, int h)
{
    lw_bitmap_alloc(bm, w, h);
    for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++)
            lw_bitmap_set(bm, x, y, rnd() % 3 == 0);
}

static bool padding_clear(const lw_bitmap *bm)
{
    if (bm->bpr == 0)
        return true;
    uint8_t mask = (uint8_t)~lw_bitmap_last_mask(bm->width);
    for (int y = 0; y < bm->height; y++)
        if ((lw_bitmap_row(bm, y)[bm->bpr - 1] & mask) != 0)
            return false;
    return true;
}

static void test_bitmap_ops(void)
{
    for (int w = 1; w <= 40; w++) {
        for (int h = 1; h <= 5; h += 2) {
            lw_bitmap a, b;
            lw_bitmap_init(&a);
            lw_bitmap_init(&b);
            random_bitmap(&a, w, h);
            random_bitmap(&b, w, h);
            memcpy(b.data, a.data, lw_bitmap_size(&a));

            /* Spiegeln */
            CHECK(lw_bitmap_mirror(&b));
            bool ok = true;
            for (int y = 0; y < h; y++)
                for (int x = 0; x < w; x++)
                    if (lw_bitmap_get(&a, x, y) != lw_bitmap_get(&b, w - 1 - x, y))
                        ok = false;
            CHECK(ok);
            CHECK(padding_clear(&b));

            /* Drehen */
            memcpy(b.data, a.data, lw_bitmap_size(&a));
            CHECK(lw_bitmap_rotate180(&b));
            ok = true;
            for (int y = 0; y < h; y++)
                for (int x = 0; x < w; x++)
                    if (lw_bitmap_get(&a, x, y) != lw_bitmap_get(&b, w - 1 - x, h - 1 - y))
                        ok = false;
            CHECK(ok);
            CHECK(padding_clear(&b));

            /* Invertieren */
            memcpy(b.data, a.data, lw_bitmap_size(&a));
            lw_bitmap_invert(&b);
            ok = true;
            for (int y = 0; y < h; y++)
                for (int x = 0; x < w; x++)
                    if (lw_bitmap_get(&a, x, y) == lw_bitmap_get(&b, x, y))
                        ok = false;
            CHECK(ok);
            CHECK(padding_clear(&b));

            /* Abschneiden */
            for (int mw = 1; mw <= w + 2; mw += 3) {
                lw_bitmap c;
                lw_bitmap_init(&c);
                random_bitmap(&c, w, h);
                memcpy(c.data, a.data, lw_bitmap_size(&a));
                lw_bitmap_crop_width(&c, mw);
                int ew = mw < w ? mw : w;
                CHECK_INT(c.width, ew);
                CHECK_INT(c.bpr, (ew + 7) / 8);
                ok = true;
                for (int y = 0; y < h; y++)
                    for (int x = 0; x < ew; x++)
                        if (lw_bitmap_get(&a, x, y) != lw_bitmap_get(&c, x, y))
                            ok = false;
                CHECK(ok);
                CHECK(padding_clear(&c));
                lw_bitmap_free(&c);
            }
            lw_bitmap_free(&a);
            lw_bitmap_free(&b);
        }
    }
    lw_bitmap e;
    lw_bitmap_init(&e);
    CHECK(lw_bitmap_alloc(&e, 13, 3));
    CHECK(lw_bitmap_is_blank(&e));
    lw_bitmap_set(&e, 12, 2, true);
    CHECK(!lw_bitmap_is_blank(&e));
    CHECK(lw_bitmap_get(&e, 12, 2));
    CHECK(!lw_bitmap_get(&e, 13, 2));      /* außerhalb */
    lw_bitmap_crop_width(&e, 0);           /* keine Begrenzung */
    CHECK_INT(e.width, 13);
    lw_bitmap_crop_width(&e, 12);
    CHECK(lw_bitmap_is_blank(&e));
    CHECK(!lw_bitmap_alloc(&e, -1, 2));
    CHECK(!lw_bitmap_alloc(&e, 100000, 100000));   /* > 256 MiB */
    CHECK(lw_bitmap_alloc(&e, 0, 5));
    CHECK(lw_bitmap_is_blank(&e));
    lw_bitmap_free(&e);
    CHECK_INT(lw_bitmap_last_mask(8), 0xFF);
    CHECK_INT(lw_bitmap_last_mask(9), 0x80);
    CHECK_INT(lw_bitmap_last_mask(15), 0xFE);
}

/* ------------------------------------------------------------------------------------------ */
/* Rasterung                                                                                  */
/* ------------------------------------------------------------------------------------------ */

/* Unabhängige Naivimplementierung von §4.1 (ganze Fehlerfelder, keine Ränder). */
static void naive_dither(const uint8_t *lum, int w, int h, lw_dither_algorithm alg, int threshold, lw_bitmap *out)
{
    int t = threshold < 1 ? 1 : (threshold > 254 ? 254 : threshold);
    lw_bitmap_alloc(out, w, h);
    if (alg == LW_DITHER_THRESHOLD || alg == LW_DITHER_ORDERED || alg == LW_DITHER_HALFTONE) {
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++) {
                int l = lum[y * w + x];
                bool black;
                if (alg == LW_DITHER_THRESHOLD) {
                    black = l < t;
                } else {
                    const int32_t *m = alg == LW_DITHER_ORDERED ? lw_bayer_matrix : lw_halftone_matrix;
                    black = l < m[(y % 8) * 8 + (x % 8)] * 4 + 2 + (t - 128);
                }
                lw_bitmap_set(out, x, y, black);
            }
        return;
    }
    static const int fs[][3] = { { 1, 0, 7 }, { -1, 1, 3 }, { 0, 1, 5 }, { 1, 1, 1 } };
    static const int at[][3] = { { 1, 0, 1 }, { 2, 0, 1 }, { -1, 1, 1 }, { 0, 1, 1 }, { 1, 1, 1 }, { 0, 2, 1 } };
    static const int st[][3] = { { 1, 0, 8 }, { 2, 0, 4 }, { -2, 1, 2 }, { -1, 1, 4 }, { 0, 1, 8 }, { 1, 1, 4 },
                                 { 2, 1, 2 }, { -2, 2, 1 }, { -1, 2, 2 }, { 0, 2, 4 }, { 1, 2, 2 }, { 2, 2, 1 } };
    const int (*k)[3];
    int n, d;
    if (alg == LW_DITHER_FLOYD_STEINBERG) { k = fs; n = 4; d = 16; }
    else if (alg == LW_DITHER_ATKINSON) { k = at; n = 6; d = 8; }
    else { k = st; n = 12; d = 42; }
    long *err = calloc((size_t)w * (size_t)h + 1, sizeof(long));
    for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++) {
            long v = lum[y * w + x] + err[y * w + x];
            long o = v < t ? 0 : 255;
            lw_bitmap_set(out, x, y, o == 0);
            long e = v - o;
            for (int i = 0; i < n; i++) {
                int nx = x + k[i][0], ny = y + k[i][1];
                if (nx >= 0 && nx < w && ny < h)
                    err[ny * w + nx] += e * k[i][2] / d;   /* C: Abschneiden Richtung 0 */
            }
        }
    free(err);
}

static void test_dither_threshold(void)
{
    uint8_t lum[] = { 0, 1, 127, 128, 129, 254, 255, 100 };
    lw_bitmap bm;
    lw_bitmap_init(&bm);
    CHECK(lw_dither_image(lum, 8, 1, LW_DITHER_THRESHOLD, 128, &bm));
    CHECK_INT(bm.data[0], 0xE1);   /* 0,1,127 schwarz; 128,129,254,255 weiß; 100 schwarz */
    CHECK(lw_dither_image(lum, 8, 1, LW_DITHER_THRESHOLD, 0, &bm));     /* T → 1 */
    CHECK_INT(bm.data[0], 0x80);
    CHECK(lw_dither_image(lum, 8, 1, LW_DITHER_THRESHOLD, 999, &bm));   /* T → 254 */
    CHECK_INT(bm.data[0], 0xF9);
    CHECK_INT(lw_dither_clamp_threshold(-5), 1);
    CHECK_INT(lw_dither_clamp_threshold(254), 254);
    lw_bitmap_free(&bm);
}

static void test_dither_matrix(void)
{
    /* Konstantes Mittelgrau: genau die Zellen mit M ≥ 32 sind schwarz (128 < 4M + 2). */
    uint8_t lum[16 * 16];
    memset(lum, 128, sizeof(lum));
    for (int a = 0; a < 2; a++) {
        lw_dither_algorithm alg = a == 0 ? LW_DITHER_ORDERED : LW_DITHER_HALFTONE;
        const int32_t *m = a == 0 ? lw_bayer_matrix : lw_halftone_matrix;
        lw_bitmap bm;
        lw_bitmap_init(&bm);
        CHECK(lw_dither_image(lum, 16, 16, alg, 128, &bm));
        int black = 0;
        bool ok = true;
        for (int y = 0; y < 16; y++)
            for (int x = 0; x < 16; x++) {
                bool b = lw_bitmap_get(&bm, x, y);
                black += b;
                if (b != (m[(y % 8) * 8 + x % 8] >= 32))
                    ok = false;
            }
        CHECK(ok);
        CHECK_INT(black, 128);
        /* T verschiebt die Matrix: T = 1 → schwarz ⇔ 128 < 4M + 2 − 127 ⇔ M ≥ 64 → nie. */
        CHECK(lw_dither_image(lum, 16, 16, alg, 1, &bm));
        CHECK(lw_bitmap_is_blank(&bm));
        lw_bitmap_free(&bm);
    }
}

static void test_dither_fs_hand(void)
{
    /* L = 100,100,100, T = 128:
     * x0: v=100 → schwarz, e=100 → x1 += 700/16 = 43
     * x1: v=143 → weiß, e=−112 → x2 += −784/16 = −49
     * x2: v=51 → schwarz */
    uint8_t lum[] = { 100, 100, 100 };
    lw_bitmap bm;
    lw_bitmap_init(&bm);
    CHECK(lw_dither_image(lum, 3, 1, LW_DITHER_FLOYD_STEINBERG, 128, &bm));
    CHECK_INT(bm.data[0], 0xA0);
    /* Negative Anteile werden Richtung 0 abgeschnitten: e = −1 → −7/16 = 0. */
    uint8_t lum2[] = { 254, 0 };
    CHECK(lw_dither_image(lum2, 2, 1, LW_DITHER_FLOYD_STEINBERG, 255, &bm));  /* T → 254 */
    CHECK_INT(bm.data[0], 0x40);
    lw_bitmap_free(&bm);
}

static void test_dither_vs_naive(void)
{
    const int sizes[][2] = { { 1, 1 }, { 1, 9 }, { 9, 1 }, { 7, 5 }, { 8, 8 }, { 33, 17 }, { 64, 3 }, { 3, 40 } };
    const int thresholds[] = { 1, 64, 128, 200, 254 };
    for (size_t si = 0; si < sizeof(sizes) / sizeof(sizes[0]); si++) {
        int w = sizes[si][0], h = sizes[si][1];
        uint8_t *lum = malloc((size_t)w * (size_t)h);
        for (int i = 0; i < w * h; i++)
            lum[i] = (uint8_t)(i % 3 == 0 ? rnd() : (i * 37 + si * 11) & 0xFF);
        for (int a = 0; a < LW_DITHER_COUNT; a++)
            for (size_t ti = 0; ti < sizeof(thresholds) / sizeof(thresholds[0]); ti++) {
                lw_bitmap fast, slow;
                lw_bitmap_init(&fast);
                lw_bitmap_init(&slow);
                CHECK(lw_dither_image(lum, w, h, (lw_dither_algorithm)a, thresholds[ti], &fast));
                naive_dither(lum, w, h, (lw_dither_algorithm)a, thresholds[ti], &slow);
                CHECK_BYTES(fast.data, lw_bitmap_size(&fast), slow.data, lw_bitmap_size(&slow));
                CHECK(padding_clear(&fast));
                lw_bitmap_free(&fast);
                lw_bitmap_free(&slow);
            }
        free(lum);
    }
    /* Gleichmäßige Flächen: weiß bleibt weiß, schwarz bleibt schwarz. */
    uint8_t white[50], black[50];
    memset(white, 255, sizeof(white));
    memset(black, 0, sizeof(black));
    for (int a = 0; a < LW_DITHER_COUNT; a++) {
        lw_bitmap bm;
        lw_bitmap_init(&bm);
        CHECK(lw_dither_image(white, 10, 5, (lw_dither_algorithm)a, 128, &bm));
        CHECK(lw_bitmap_is_blank(&bm));
        CHECK(lw_dither_image(black, 10, 5, (lw_dither_algorithm)a, 128, &bm));
        int n = 0;
        for (int y = 0; y < 5; y++)
            for (int x = 0; x < 10; x++)
                n += lw_bitmap_get(&bm, x, y);
        CHECK_INT(n, 50);
        lw_bitmap_free(&bm);
    }
    lw_ditherer d;
    CHECK(!lw_ditherer_init(&d, (lw_dither_algorithm)99, 128, 10));
    CHECK(!lw_ditherer_init(&d, LW_DITHER_STUCKI, 128, -1));
}

/* ------------------------------------------------------------------------------------------ */
/* Rasterumrechnung                                                                           */
/* ------------------------------------------------------------------------------------------ */

static bool convert(unsigned width, unsigned bpc, unsigned bpp, unsigned bpl, unsigned order,
                    unsigned cs, const uint8_t *line, uint8_t *lum)
{
    lw_raster_format f = { width, 1, bpc, bpp, bpl, order, cs };
    lw_raster_converter c;
    char err[256];
    if (!lw_raster_converter_init(&c, &f, err, sizeof(err)))
        return false;
    lw_raster_convert_line(&c, line, lum);
    return true;
}

static void test_raster_gray(void)
{
    uint8_t lum[16];
    const uint8_t l8[] = { 0, 1, 128, 255 };
    CHECK(convert(4, 8, 8, 4, LW_ORDER_CHUNKY, LW_CSPACE_W, l8, lum));
    CHECK_BYTES(lum, 4, l8, 4);
    CHECK(convert(4, 8, 8, 4, LW_ORDER_CHUNKY, LW_CSPACE_SW, l8, lum));
    CHECK_BYTES(lum, 4, l8, 4);
    const uint8_t k8[] = { 255, 254, 127, 0 };
    CHECK(convert(4, 8, 8, 4, LW_ORDER_CHUNKY, LW_CSPACE_K, l8, lum));
    CHECK_BYTES(lum, 4, k8, 4);

    const uint8_t b1[] = { 0xA0, 0x80 };      /* 1010 0000 1 */
    const uint8_t w1[] = { 255, 0, 255, 0, 0, 0, 0, 0, 255 };
    const uint8_t kk1[] = { 0, 255, 0, 255, 255, 255, 255, 255, 0 };
    CHECK(convert(9, 1, 1, 2, LW_ORDER_CHUNKY, LW_CSPACE_W, b1, lum));
    CHECK_BYTES(lum, 9, w1, 9);
    CHECK(convert(9, 1, 1, 2, LW_ORDER_CHUNKY, LW_CSPACE_K, b1, lum));
    CHECK_BYTES(lum, 9, kk1, 9);

    const uint8_t b2[] = { 0x1B };            /* 00 01 10 11 */
    const uint8_t w2[] = { 0, 85, 170, 255 };
    CHECK(convert(4, 2, 2, 1, LW_ORDER_CHUNKY, LW_CSPACE_SW, b2, lum));
    CHECK_BYTES(lum, 4, w2, 4);

    const uint8_t b4[] = { 0x0F, 0x80 };
    const uint8_t k4[] = { 255, 0, 119 };     /* K: 255 − v·17 */
    CHECK(convert(3, 4, 4, 2, LW_ORDER_CHUNKY, LW_CSPACE_K, b4, lum));
    CHECK_BYTES(lum, 3, k4, 3);

    uint16_t s16[3] = { 0x1234, 0xFF00, 0x00FF };   /* Host-Byte-Reihenfolge */
    const uint8_t w16[] = { 0x12, 0xFF, 0x00 };
    CHECK(convert(3, 16, 16, 6, LW_ORDER_CHUNKY, LW_CSPACE_SW, (const uint8_t *)s16, lum));
    CHECK_BYTES(lum, 3, w16, 3);
    const uint8_t k16[] = { 0xED, 0x00, 0xFF };
    CHECK(convert(3, 16, 16, 6, LW_ORDER_CHUNKY, LW_CSPACE_K, (const uint8_t *)s16, lum));
    CHECK_BYTES(lum, 3, k16, 3);

    /* Einkanalig planar = chunky; Füllbytes am Zeilenende werden ignoriert. */
    const uint8_t padded[] = { 10, 20, 0xA5, 0xA5 };
    CHECK(convert(2, 8, 8, 4, LW_ORDER_PLANAR, LW_CSPACE_W, padded, lum));
    CHECK_INT(lum[0], 10);
    CHECK_INT(lum[1], 20);
}

static void test_raster_color(void)
{
    uint8_t lum[16];
    const uint8_t rgb[] = { 255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255, 0, 0, 0 };
    const uint8_t lrgb[] = { 76, 149, 29, 255, 0 };
    CHECK(convert(5, 8, 24, 15, LW_ORDER_CHUNKY, LW_CSPACE_RGB, rgb, lum));
    CHECK_BYTES(lum, 5, lrgb, 5);
    CHECK(convert(5, 8, 24, 15, LW_ORDER_CHUNKY, LW_CSPACE_SRGB, rgb, lum));
    CHECK_BYTES(lum, 5, lrgb, 5);
    CHECK(convert(5, 8, 24, 15, LW_ORDER_CHUNKY, LW_CSPACE_ADOBERGB, rgb, lum));
    CHECK_BYTES(lum, 5, lrgb, 5);

    /* banded: RRRRR GGGGG BBBBB */
    const uint8_t band[] = { 255, 0, 0, 255, 0, 0, 255, 0, 255, 0, 0, 0, 255, 255, 0 };
    CHECK(convert(5, 8, 8, 15, LW_ORDER_BANDED, LW_CSPACE_RGB, band, lum));
    CHECK_BYTES(lum, 5, lrgb, 5);

    /* 1-Bit-RGB chunky: 4 Bit je Pixel, Füllbit vorn (x R G B). */
    const uint8_t rgb1[] = { 0x7F, 0x84 };
    const uint8_t lrgb1[] = { 255, 255, 0, 76 };
    CHECK(convert(4, 1, 4, 2, LW_ORDER_CHUNKY, LW_CSPACE_RGB, rgb1, lum));
    CHECK_BYTES(lum, 4, lrgb1, 4);

    /* 16-Bit-RGB */
    uint16_t rgb16[3] = { 0xFFFF, 0x0000, 0x0000 };
    CHECK(convert(1, 16, 48, 6, LW_ORDER_CHUNKY, LW_CSPACE_RGB, (const uint8_t *)rgb16, lum));
    CHECK_INT(lum[0], 76);

    /* RGBA: auf Weiß komponiert */
    const uint8_t rgba[] = { 255, 255, 255, 0, 0, 0, 0, 255, 0, 0, 0, 128, 0, 0, 0, 0 };
    const uint8_t lrgba[] = { 255, 0, 127, 255 };
    CHECK(convert(4, 8, 32, 16, LW_ORDER_CHUNKY, LW_CSPACE_RGBA, rgba, lum));
    CHECK_BYTES(lum, 4, lrgba, 4);

    /* CMYK-Varianten */
    const uint8_t cmyk[] = { 0, 0, 0, 255, 255, 255, 255, 0, 30, 60, 90, 10, 0, 0, 0, 0 };
    const uint8_t lcmyk[] = { 0, 0, 185, 255 };
    CHECK(convert(4, 8, 32, 16, LW_ORDER_CHUNKY, LW_CSPACE_CMYK, cmyk, lum));
    CHECK_BYTES(lum, 4, lcmyk, 4);
    const uint8_t ymck[] = { 90, 60, 30, 10 };
    CHECK(convert(1, 8, 32, 4, LW_ORDER_CHUNKY, LW_CSPACE_YMCK, ymck, lum));
    CHECK_INT(lum[0], 185);
    const uint8_t kcmy[] = { 10, 30, 60, 90 };
    CHECK(convert(1, 8, 32, 4, LW_ORDER_CHUNKY, LW_CSPACE_KCMY, kcmy, lum));
    CHECK_INT(lum[0], 185);
    const uint8_t sat[] = { 200, 200, 200, 200 };   /* K + Mittel > 255 → 0 */
    CHECK(convert(1, 8, 32, 4, LW_ORDER_CHUNKY, LW_CSPACE_CMYK, sat, lum));
    CHECK_INT(lum[0], 0);
    const uint8_t cmy[] = { 90, 90, 90 };
    CHECK(convert(1, 8, 24, 3, LW_ORDER_CHUNKY, LW_CSPACE_CMY, cmy, lum));
    CHECK_INT(lum[0], 165);
    CHECK(convert(1, 8, 24, 3, LW_ORDER_CHUNKY, LW_CSPACE_YMC, cmy, lum));
    CHECK_INT(lum[0], 165);
}

static void test_raster_errors(void)
{
    lw_raster_converter c;
    char err[256];
    lw_raster_format planar = { 10, 1, 8, 8, 10, LW_ORDER_PLANAR, LW_CSPACE_RGB };
    CHECK(!lw_raster_converter_init(&c, &planar, err, sizeof(err)));
    CHECK(strstr(err, "Planare") != NULL);
    lw_raster_format lab = { 10, 1, 8, 24, 30, LW_ORDER_CHUNKY, 16 };
    CHECK(!lw_raster_converter_init(&c, &lab, err, sizeof(err)));
    CHECK(strstr(err, "CIELab") != NULL);
    lw_raster_format icc = { 10, 1, 8, 24, 30, LW_ORDER_CHUNKY, 34 };
    CHECK(!lw_raster_converter_init(&c, &icc, err, sizeof(err)));
    CHECK(strstr(err, "ICC3") != NULL);
    lw_raster_format bits3 = { 10, 1, 3, 3, 4, LW_ORDER_CHUNKY, LW_CSPACE_W };
    CHECK(!lw_raster_converter_init(&c, &bits3, err, sizeof(err)));
    lw_raster_format shortline = { 10, 1, 8, 8, 9, LW_ORDER_CHUNKY, LW_CSPACE_W };
    CHECK(!lw_raster_converter_init(&c, &shortline, err, sizeof(err)));
    CHECK(strstr(err, "zu kurz") != NULL);
    lw_raster_format badband = { 10, 1, 8, 8, 31, LW_ORDER_BANDED, LW_CSPACE_RGB };
    CHECK(!lw_raster_converter_init(&c, &badband, err, sizeof(err)));
    lw_raster_format badbpp = { 10, 1, 8, 16, 20, LW_ORDER_CHUNKY, LW_CSPACE_RGB };   /* < 3 Kanäle */
    CHECK(!lw_raster_converter_init(&c, &badbpp, err, sizeof(err)));
    lw_raster_format badorder = { 10, 1, 8, 8, 10, 7, LW_CSPACE_W };
    CHECK(!lw_raster_converter_init(&c, &badorder, err, sizeof(err)));
    lw_raster_format nobpp = { 10, 1, 8, 0, 10, LW_ORDER_CHUNKY, LW_CSPACE_W };       /* tolerant */
    CHECK(lw_raster_converter_init(&c, &nobpp, err, sizeof(err)));
    CHECK(strcmp(lw_raster_color_space_name(18), "SW") == 0);
    CHECK(strcmp(lw_raster_color_space_name(99), "unbekannt") == 0);
}

/* ------------------------------------------------------------------------------------------ */
/* Optionen                                                                                   */
/* ------------------------------------------------------------------------------------------ */

static void test_parse_values(void)
{
    bool b = false;
    CHECK_INT(lw_parse_bool("True", &b), LW_PARSE_OK); CHECK(b);
    CHECK_INT(lw_parse_bool("yes", &b), LW_PARSE_OK); CHECK(b);
    CHECK_INT(lw_parse_bool("ON", &b), LW_PARSE_OK); CHECK(b);
    CHECK_INT(lw_parse_bool("1", &b), LW_PARSE_OK); CHECK(b);
    CHECK_INT(lw_parse_bool("false", &b), LW_PARSE_OK); CHECK(!b);
    CHECK_INT(lw_parse_bool("No", &b), LW_PARSE_OK); CHECK(!b);
    CHECK_INT(lw_parse_bool("off", &b), LW_PARSE_OK); CHECK(!b);
    CHECK_INT(lw_parse_bool("0", &b), LW_PARSE_OK); CHECK(!b);
    CHECK_INT(lw_parse_bool("Default", &b), LW_PARSE_DEFAULT);
    CHECK_INT(lw_parse_bool("maybe", &b), LW_PARSE_INVALID);
    CHECK_INT(lw_parse_bool("", &b), LW_PARSE_INVALID);

    int v = 0;
    CHECK_INT(lw_parse_int("37", &v), LW_PARSE_OK); CHECK_INT(v, 37);
    CHECK_INT(lw_parse_int("-120", &v), LW_PARSE_OK); CHECK_INT(v, -120);
    CHECK_INT(lw_parse_int("+5", &v), LW_PARSE_OK); CHECK_INT(v, 5);
    CHECK_INT(lw_parse_int("-0", &v), LW_PARSE_OK); CHECK_INT(v, 0);
    CHECK_INT(lw_parse_int("Custom.37", &v), LW_PARSE_OK); CHECK_INT(v, 37);
    CHECK_INT(lw_parse_int("custom.-12", &v), LW_PARSE_OK); CHECK_INT(v, -12);
    CHECK_INT(lw_parse_int("default", &v), LW_PARSE_DEFAULT);
    CHECK_INT(lw_parse_int("12abc", &v), LW_PARSE_INVALID);
    CHECK_INT(lw_parse_int("1.5", &v), LW_PARSE_INVALID);
    CHECK_INT(lw_parse_int("-", &v), LW_PARSE_INVALID);
    CHECK_INT(lw_parse_int("", &v), LW_PARSE_INVALID);
    CHECK_INT(lw_parse_int("99999999999", &v), LW_PARSE_OK); CHECK_INT(v, 2147483647);
    CHECK_INT(lw_parse_int("-99999999999", &v), LW_PARSE_OK); CHECK_INT(v, -2147483647);
    CHECK_INT(lw_parse_int("9223372036854775807", &v), LW_PARSE_OK);
    CHECK_INT(lw_parse_int("9223372036854775808", &v), LW_PARSE_INVALID);
    CHECK_INT(lw_parse_int("-9223372036854775808", &v), LW_PARSE_OK);
    CHECK_INT(lw_parse_int("99999999999999999999", &v), LW_PARSE_INVALID);

    lw_language l;
    CHECK_INT(lw_parse_language("epl2", &l), LW_PARSE_OK); CHECK_INT(l, LW_LANGUAGE_EPL);
    CHECK_INT(lw_parse_language("ZPLII", &l), LW_PARSE_OK); CHECK_INT(l, LW_LANGUAGE_ZPL);
    CHECK_INT(lw_parse_language("cpcl", &l), LW_PARSE_OK); CHECK_INT(l, LW_LANGUAGE_CPCL);
    CHECK_INT(lw_parse_language("PCL", &l), LW_PARSE_INVALID);
    lw_dither_algorithm d;
    CHECK_INT(lw_parse_dither("floydsteinberg", &d), LW_PARSE_OK); CHECK_INT(d, LW_DITHER_FLOYD_STEINBERG);
    CHECK_INT(lw_parse_dither("Stucki", &d), LW_PARSE_OK); CHECK_INT(d, LW_DITHER_STUCKI);
    CHECK_INT(lw_parse_dither("Bayer", &d), LW_PARSE_INVALID);
    lw_compression c;
    CHECK_INT(lw_parse_compression("hex", &c), LW_PARSE_OK); CHECK_INT(c, LW_COMPRESSION_HEX);
    lw_media_type mt;
    CHECK_INT(lw_parse_media_type("ThermalTransfer", &mt), LW_PARSE_OK); CHECK_INT(mt, LW_MEDIA_TYPE_THERMAL_TRANSFER);
    CHECK_INT(lw_parse_media_type("Default", &mt), LW_PARSE_DEFAULT);
    lw_tracking tr;
    CHECK_INT(lw_parse_tracking("BlackMark", &tr), LW_PARSE_OK); CHECK_INT(tr, LW_TRACKING_BLACK_MARK);
    lw_print_mode pm;
    CHECK_INT(lw_parse_print_mode("DelayedCut", &pm), LW_PARSE_OK); CHECK_INT(pm, LW_PRINT_MODE_DELAYED_CUT);
    lw_backfeed bf;
    CHECK_INT(lw_parse_backfeed("before", &bf), LW_PARSE_OK); CHECK_INT(bf, LW_BACKFEED_BEFORE);

    lw_buf cmd;
    lw_buf_init(&cmd);
    CHECK_INT(lw_parse_commands("XlhBXkZYw6RYXlha", &cmd), LW_PARSE_OK);   /* ^XA^FXäX^XZ */
    CHECK_BUF_STR(cmd, "^XA^FX\xC3\xA4X^XZ");
    CHECK_INT(lw_parse_commands("None", &cmd), LW_PARSE_DEFAULT);
    CHECK_INT(lw_parse_commands("Default", &cmd), LW_PARSE_DEFAULT);
    CHECK_INT(lw_parse_commands("_w", &cmd), LW_PARSE_INVALID);             /* 0xFF – kein UTF-8 */
    CHECK_INT(lw_parse_commands("Zm9v!", &cmd), LW_PARSE_INVALID);
    lw_buf_free(&cmd);

    CHECK_INT(lw_print_mode_code(LW_PRINT_MODE_KIOSK), 'K');
    CHECK_INT(lw_tracking_code(LW_TRACKING_AUTO), 'A');
    CHECK_INT(lw_media_type_code(LW_MEDIA_TYPE_THERMAL_TRANSFER), 'T');
    CHECK_INT(lw_backfeed_code(LW_BACKFEED_OFF), 'O');
    CHECK_INT(lw_tracking_code(LW_TRACKING_UNSET), 0);
}

/* Tabellengestützte Nachschlagefunktion: name=wert je Ebene. */
typedef struct table_lookup {
    const char *const *levels[LW_LEVEL_COUNT];   /* NULL-terminierte Listen "name", "wert", … */
} table_lookup;

static const char *table_lookup_fn(void *ctx, const char *name, lw_option_level level)
{
    const table_lookup *t = ctx;
    const char *const *list = t->levels[level];
    for (size_t i = 0; list != NULL && list[i] != NULL; i += 2)
        if (strcmp(list[i], name) == 0)
            return list[i + 1];
    return NULL;
}

static void discard_log(void *ctx, lw_log_level level, const char *message)
{
    (void)level;
    (void)message;
    if (ctx != NULL)
        (*(int *)ctx)++;
}

static void test_resolve(void)
{
    /* Ohne jeden Wert: eingebaute Standards. */
    static const char *const empty[] = { NULL };
    table_lookup t0 = { { empty, empty, empty } };
    lw_settings s;
    lw_settings_init(&s);
    CHECK_INT(lw_settings_resolve(&s, table_lookup_fn, &t0, NULL), 0);
    CHECK_INT(s.language, LW_LANGUAGE_ZPL);
    CHECK_INT(s.darkness, LW_UNSET);
    CHECK_INT(s.dither, LW_DITHER_THRESHOLD);
    CHECK_INT(s.threshold, 128);
    CHECK_INT(s.compression, LW_COMPRESSION_Z64);
    CHECK_INT(s.cut_every, 0);
    CHECK(!s.mirror && !s.negative && !s.rotate180 && !s.calibrate && !s.save_settings && !s.skip_blank);
    CHECK(s.start_commands == NULL && s.end_commands == NULL);
    lw_settings_free(&s);

    /* Vorrang argv > markiert > Standard, ungültige Werte fallen durch. */
    static const char *const argv_level[] = {
        "lwDarkness", "12",
        "lwLabelTop", "37",              /* außerhalb der PPD-Auswahl erlaubt */
        "lwDither", "Bogus",             /* ungültig → nächste Ebene */
        "lwSpeed", "Default",            /* "Default" schlägt alle PPD-Werte */
        "lwThreshold", "  160  ",        /* Leerraum wird entfernt */
        "lwMirror", "yes",
        "lwCompression", "   ",          /* leer → nächste Ebene */
        "lwStartCmd", "XlhB",
        "lwEndCmd", "@@@",               /* ungültig → PPD */
        "lwCutEvery", "12345",           /* begrenzt auf 9999 */
        "lwLabelLeft", "-20000",         /* begrenzt auf −9999 */
        NULL
    };
    static const char *const marked_level[] = {
        "lwDarkness", "20", "lwDither", "Ordered", "lwSpeed", "6", "lwLanguage", "Bogus",
        "lwTearOff", "-10", "lwCompression", "ACS", "lwNegative", "nope", NULL
    };
    static const char *const default_level[] = {
        "lwDarkness", "25", "lwDither", "Stucki", "lwSpeed", "4", "lwLanguage", "EPL",
        "lwTearOff", "30", "lwNegative", "True", "lwEndCmd", "fg", "lwMediaTracking", "Continuous",
        "lwPrintMode", "Default", "lwRotate180", "Default", NULL
    };
    table_lookup t1 = { { argv_level, marked_level, default_level } };
    int warnings = 0;
    lw_logger log = { discard_log, &warnings };
    lw_settings_init(&s);
    int invalid = lw_settings_resolve(&s, table_lookup_fn, &t1, &log);
    CHECK_INT(invalid, 4);   /* lwDither=Bogus, lwLanguage=Bogus, lwNegative=nope, lwEndCmd=@@@ */
    CHECK_INT(warnings, 4);
    CHECK_INT(s.darkness, 12);
    CHECK_INT(s.label_top, 37);
    CHECK_INT(s.dither, LW_DITHER_ORDERED);
    CHECK_INT(s.speed, LW_UNSET);
    CHECK_INT(s.threshold, 160);
    CHECK(s.mirror);
    CHECK_INT(s.compression, LW_COMPRESSION_ACS);
    CHECK_INT(s.language, LW_LANGUAGE_EPL);
    CHECK_INT(s.tear_off, -10);
    CHECK(s.negative);
    CHECK_INT(s.tracking, LW_TRACKING_CONTINUOUS);
    CHECK_INT(s.print_mode, LW_PRINT_MODE_UNSET);
    CHECK(!s.rotate180);
    CHECK_INT(s.cut_every, 9999);
    CHECK_INT(s.label_left, -9999);
    CHECK_BYTES(s.start_commands, s.start_commands_len, "^XA", 3);
    CHECK_BYTES(s.end_commands, s.end_commands_len, "~", 1);
    lw_settings_free(&s);

    /* Begrenzungen */
    static const char *const clamp_level[] = {
        "lwDarkness", "99", "lwSpeed", "0", "lwThreshold", "0", "lwTearOff", "500",
        "lwLabelTop", "-121", NULL
    };
    table_lookup t2 = { { clamp_level, empty, empty } };
    lw_settings_init(&s);
    lw_settings_resolve(&s, table_lookup_fn, &t2, NULL);
    CHECK_INT(s.darkness, 30);
    CHECK_INT(s.speed, 1);
    CHECK_INT(s.threshold, 1);
    CHECK_INT(s.tear_off, 120);
    CHECK_INT(s.label_top, -120);
    lw_settings_free(&s);

    /* Gleicher ungültiger Wert auf zwei Ebenen → nur eine Warnung. */
    static const char *const same[] = { "lwDither", "Nope", NULL };
    table_lookup t3 = { { empty, same, same } };
    warnings = 0;
    lw_settings_init(&s);
    CHECK_INT(lw_settings_resolve(&s, table_lookup_fn, &t3, &log), 1);
    CHECK_INT(s.dither, LW_DITHER_THRESHOLD);
    lw_settings_free(&s);
}

/* ------------------------------------------------------------------------------------------ */
/* Auftragsformat                                                                             */
/* ------------------------------------------------------------------------------------------ */

typedef struct job_capture {
    lw_buf out;
    lw_sink sink;
    int labels;
    int pages[64];
    int quantities[64];
    bool cancel_after_first;
} job_capture;

static void capture_label(void *ctx, int page, int quantity)
{
    job_capture *c = ctx;
    if (c->labels < 64) {
        c->pages[c->labels] = page;
        c->quantities[c->labels] = quantity;
    }
    c->labels++;
}

static bool capture_canceled(void *ctx)
{
    job_capture *c = ctx;
    return c->cancel_after_first && c->labels > 0;
}

static void capture_init(job_capture *c)
{
    memset(c, 0, sizeof(*c));
    lw_buf_init(&c->out);
    lw_sink_init_buf(&c->sink, &c->out);
}

/* Seite 10 × 2: Zeile 0 = 1100000001, Zeile 1 leer. */
static void sample_page(lw_bitmap *bm)
{
    lw_bitmap_alloc(bm, 10, 2);   /* gibt vorhandenen Speicher frei */
    lw_bitmap_set(bm, 0, 0, true);
    lw_bitmap_set(bm, 1, 0, true);
    lw_bitmap_set(bm, 9, 0, true);
}

static void run_job(job_capture *cap, const lw_settings *s, int dpi, int max_width, int gap,
                    int copies, bool collate, lw_bitmap *pages, int count, bool cancel)
{
    capture_init(cap);
    lw_job_config cfg = { s, dpi, max_width, gap, copies, collate, false, 0, 0 };
    lw_job_hooks hooks = { capture_label, NULL, capture_canceled, cap, NULL, NULL };
    lw_job job;
    CHECK(lw_job_init(&job, &cfg, &cap->sink, &hooks));
    CHECK(lw_job_begin(&job));
    for (int i = 0; i < count; i++)
        CHECK(lw_job_add_page(&job, &pages[i], i + 1));
    CHECK(lw_job_finish(&job, cancel));
    lw_job_free(&job);
}

static void test_job_zpl(void)
{
    lw_settings s;
    lw_settings_init(&s);
    s.darkness = 8;
    s.tear_off = -5;
    s.calibrate = true;
    s.print_mode = LW_PRINT_MODE_CUTTER;
    s.tracking = LW_TRACKING_BLACK_MARK;
    s.media_type = LW_MEDIA_TYPE_DIRECT_THERMAL;
    s.speed = 4;
    s.backfeed = LW_BACKFEED_BEFORE;
    s.label_top = 20;
    s.label_left = -30;
    s.rotate180 = true;
    s.mirror = true;
    s.compression = LW_COMPRESSION_HEX;
    s.save_settings = true;
    s.start_commands = "^XA^FXstart^XZ";
    s.start_commands_len = strlen(s.start_commands);
    s.end_commands = "~JR";
    s.end_commands_len = 3;
    lw_bitmap page;
    lw_bitmap_init(&page);
    sample_page(&page);
    job_capture cap;
    run_job(&cap, &s, 203, 0, -1, 1, true, &page, 1, false);
    const char *expected =
        "^XA^FXstart^XZ\n~SD08\n~TA-05\n~JSB\n~JC\n"
        "^XA\n^MMC\n^MNM\n^MTD\n^PR4,4,4\n^PW10\n^LL2\n^LH0,0\n^LT20\n^LS-30\n^POI\n^PMY\n"
        "^FO0,0^GFA,4,4,2,C0400000^FS\n^PQ1\n^JUS\n^XZ\n~JR\n";
    CHECK_BUF_STR(cap.out, expected);
    CHECK_INT(cap.labels, 1);
    CHECK_INT(cap.quantities[0], 1);
    lw_buf_free(&cap.out);

    /* Minimal: nur Pflichtzeilen; ACS; Schnitt alle 5 */
    lw_settings_init(&s);
    s.compression = LW_COMPRESSION_ACS;
    s.cut_every = 5;
    s.tear_off = 10;
    sample_page(&page);
    run_job(&cap, &s, 203, 0, -1, 3, true, &page, 1, false);
    CHECK_BUF_STR(cap.out, "~TA010\n^XA\n^PW10\n^LL2\n^LH0,0\n^PON\n^PMN\n^FO0,0^GFA,4,4,2,C040,^FS\n^PQ3,5,0,Y\n^XZ\n");
    CHECK_INT(cap.quantities[0], 3);
    lw_buf_free(&cap.out);

    /* Z64 */
    lw_settings_init(&s);
    sample_page(&page);
    run_job(&cap, &s, 203, 0, -1, 1, true, &page, 1, false);
    lw_buf z;
    lw_buf_init(&z);
    lw_buf_append_str(&z, "^XA\n^PW10\n^LL2\n^LH0,0\n^PON\n^PMN\n^FO0,0^GFA,4,4,2,");
    const uint8_t raw[] = { 0xC0, 0x40, 0x00, 0x00 };
    CHECK_INT(lw_z64_append(&z, raw, 4), Z_OK);
    lw_buf_append_str(&z, "^FS\n^PQ1\n^XZ\n");
    CHECK_BYTES(cap.out.data, cap.out.len, z.data, z.len);
    lw_buf_free(&z);
    lw_buf_free(&cap.out);
    lw_bitmap_free(&page);
}

static void test_job_epl(void)
{
    lw_settings s;
    lw_settings_init(&s);
    s.language = LW_LANGUAGE_EPL;
    s.speed = 9;
    s.darkness = 9;
    s.tracking = LW_TRACKING_GAP;
    s.rotate180 = true;
    s.mirror = true;
    s.media_type = LW_MEDIA_TYPE_DIRECT_THERMAL;
    s.print_mode = LW_PRINT_MODE_PEEL_OFF;
    s.start_commands = "start";
    s.start_commands_len = 5;
    s.end_commands = "end";
    s.end_commands_len = 3;
    s.save_settings = true;    /* kein ^JUS in EPL */
    lw_bitmap page;
    lw_bitmap_init(&page);
    sample_page(&page);
    job_capture cap;
    run_job(&cap, &s, 203, 0, 30, 1, true, &page, 1, false);
    /* gespiegelt: 1000000011 → 80 C0, invertiert: 7F 3F; leere Zeile → FF FF */
    static const char expected[] = "start\n\nN\nq10\nQ2,30\nS6\nD5\nZB\nODP\nGW0,0,2,2,\x7F\x3F\xFF\xFF\nP1\nend\n";
    CHECK_BYTES(cap.out.data, cap.out.len, expected, sizeof(expected) - 1);
    lw_buf_free(&cap.out);

    /* Schwarze Marke, Endlos, Schneider, nur Medium */
    lw_settings_init(&s);
    s.language = LW_LANGUAGE_EPL;
    s.tracking = LW_TRACKING_BLACK_MARK;
    s.print_mode = LW_PRINT_MODE_CUTTER;
    s.darkness = 30;
    s.speed = 1;
    sample_page(&page);
    run_job(&cap, &s, 203, 0, -1, 4, false, &page, 1, false);
    static const char e2[] = "\nN\nq10\nQ2,B24\nS1\nD15\nZT\nOC\nGW0,0,2,2,\x3F\xBF\xFF\xFF\nP4\n";
    CHECK_BYTES(cap.out.data, cap.out.len, e2, sizeof(e2) - 1);
    lw_buf_free(&cap.out);

    lw_settings_init(&s);
    s.language = LW_LANGUAGE_EPL;
    s.tracking = LW_TRACKING_CONTINUOUS;
    s.media_type = LW_MEDIA_TYPE_THERMAL_TRANSFER;
    s.darkness = 0;
    sample_page(&page);
    run_job(&cap, &s, 203, 0, -1, 1, true, &page, 1, false);
    static const char e3[] = "\nN\nq10\nQ2,0\nD0\nZT\nO\nGW0,0,2,2,\x3F\xBF\xFF\xFF\nP1\n";
    CHECK_BYTES(cap.out.data, cap.out.len, e3, sizeof(e3) - 1);
    lw_buf_free(&cap.out);
    lw_bitmap_free(&page);
}

static void test_job_cpcl(void)
{
    lw_settings s;
    lw_settings_init(&s);
    s.language = LW_LANGUAGE_CPCL;
    s.darkness = 15;
    s.speed = 9;
    s.tracking = LW_TRACKING_CONTINUOUS;
    s.rotate180 = true;
    s.mirror = true;
    s.start_commands = "ignored";      /* CPCL kennt laut §8 keine Start-/Endbefehle */
    s.start_commands_len = 7;
    lw_bitmap page;
    lw_bitmap_init(&page);
    sample_page(&page);
    job_capture cap;
    run_job(&cap, &s, 203, 0, -1, 2, true, &page, 1, false);
    /* spiegeln → 1000000011, dann 180° → Zeilen vertauscht und zurückgespiegelt */
    static const char expected[] = "! 0 200 200 2 2\r\nPAGE-WIDTH 10\r\nCONTRAST 2\r\nSPEED 5\r\nCG 2 2 0 0 \x00\x00\xC0\x40\r\nPRINT\r\n";
    CHECK_BYTES(cap.out.data, cap.out.len, expected, sizeof(expected) - 1);
    lw_buf_free(&cap.out);

    lw_settings_init(&s);
    s.language = LW_LANGUAGE_CPCL;
    s.darkness = 0;
    sample_page(&page);
    run_job(&cap, &s, 300, 0, -1, 1, true, &page, 1, false);
    static const char e2[] = "! 0 300 300 2 1\r\nPAGE-WIDTH 10\r\nCONTRAST 0\r\nCG 2 2 0 0 \xC0\x40\x00\x00\r\nFORM\r\nPRINT\r\n";
    CHECK_BYTES(cap.out.data, cap.out.len, e2, sizeof(e2) - 1);
    lw_buf_free(&cap.out);
    lw_bitmap_free(&page);
    CHECK_INT(lw_cpcl_resolution(203), 200);
    CHECK_INT(lw_cpcl_resolution(0), 200);
    CHECK_INT(lw_cpcl_resolution(600), 600);
}

/* Zählt Vorkommen von `needle` in der Ausgabe. */
static int count_occurrences(const lw_buf *b, const char *needle)
{
    int n = 0;
    size_t len = strlen(needle);
    for (size_t i = 0; i + len <= b->len; i++)
        if (memcmp(b->data + i, needle, len) == 0)
            n++;
    return n;
}

static void make_pages(lw_bitmap *pages, int count, int blank_index)
{
    for (int i = 0; i < count; i++) {
        lw_bitmap_init(&pages[i]);
        lw_bitmap_alloc(&pages[i], 16 + i, 3);
        if (i != blank_index)
            lw_bitmap_set(&pages[i], i, 1, true);
    }
}

static void free_pages(lw_bitmap *pages, int count)
{
    for (int i = 0; i < count; i++)
        lw_bitmap_free(&pages[i]);
}

static void test_job_copies(void)
{
    lw_settings s;
    lw_settings_init(&s);
    s.compression = LW_COMPRESSION_HEX;
    lw_bitmap pages[4];
    job_capture cap;

    /* Zwei Seiten, sortiert, 3 Kopien → 1,2,1,2,1,2 je ^PQ1 */
    make_pages(pages, 2, -1);
    run_job(&cap, &s, 203, 0, -1, 3, true, pages, 2, false);
    CHECK_INT(cap.labels, 6);
    for (int i = 0; i < 6 && i < cap.labels; i++) {
        CHECK_INT(cap.pages[i], i % 2 + 1);
        CHECK_INT(cap.quantities[i], 1);
    }
    CHECK_INT(count_occurrences(&cap.out, "^PQ1\n"), 6);
    CHECK_INT(count_occurrences(&cap.out, "^PW16\n"), 3);
    CHECK_INT(count_occurrences(&cap.out, "^PW17\n"), 3);
    lw_buf_free(&cap.out);
    free_pages(pages, 2);

    /* Nicht sortiert → je Seite ^PQ3 */
    make_pages(pages, 2, -1);
    run_job(&cap, &s, 203, 0, -1, 3, false, pages, 2, false);
    CHECK_INT(cap.labels, 2);
    CHECK_INT(count_occurrences(&cap.out, "^PQ3\n"), 2);
    lw_buf_free(&cap.out);
    free_pages(pages, 2);

    /* Leere Seite übersprungen → nur eine Seite übrig → ^PQ3 trotz Sortierung */
    s.skip_blank = true;
    make_pages(pages, 2, 1);
    run_job(&cap, &s, 203, 0, -1, 3, true, pages, 2, false);
    CHECK_INT(cap.labels, 1);
    CHECK_INT(cap.quantities[0], 3);
    lw_buf_free(&cap.out);
    free_pages(pages, 2);

    /* Drei Seiten, mittlere leer, sortiert ×2 → 1,3,1,3 */
    make_pages(pages, 3, 1);
    run_job(&cap, &s, 203, 0, -1, 2, true, pages, 3, false);
    CHECK_INT(cap.labels, 4);
    CHECK_INT(cap.pages[0], 1);
    CHECK_INT(cap.pages[1], 3);
    CHECK_INT(cap.pages[2], 1);
    CHECK_INT(cap.pages[3], 3);
    lw_buf_free(&cap.out);
    free_pages(pages, 3);
    s.skip_blank = false;

    /* ^JUS nur beim ersten Etikett, auch bei Wiederholungen */
    s.save_settings = true;
    make_pages(pages, 2, -1);
    run_job(&cap, &s, 203, 0, -1, 2, true, pages, 2, false);
    CHECK_INT(count_occurrences(&cap.out, "^JUS\n"), 1);
    CHECK(cap.out.len > 0 && strstr((const char *)cap.out.data, "^PQ1\n^JUS\n^XZ\n") != NULL);
    lw_buf_free(&cap.out);
    free_pages(pages, 2);
    s.save_settings = false;

    /* Abbruch: keine Sortierwiederholungen */
    make_pages(pages, 2, -1);
    run_job(&cap, &s, 203, 0, -1, 5, true, pages, 2, true);
    CHECK_INT(cap.labels, 2);
    lw_buf_free(&cap.out);
    free_pages(pages, 2);

    /* Abbruch während der Wiederholungen (Haken meldet Abbruch nach dem ersten Etikett) */
    make_pages(pages, 2, -1);
    capture_init(&cap);
    cap.cancel_after_first = true;
    {
        lw_job_config cfg = { &s, 203, 0, -1, 4, true, false, 0, 0 };
        lw_job_hooks hooks = { capture_label, NULL, capture_canceled, &cap, NULL, NULL };
        lw_job job;
        lw_job_init(&job, &cfg, &cap.sink, &hooks);
        lw_job_add_page(&job, &pages[0], 1);
        lw_job_add_page(&job, &pages[1], 2);
        CHECK(lw_job_finish(&job, false));
        lw_job_free(&job);
    }
    CHECK_INT(cap.labels, 2);
    lw_buf_free(&cap.out);
    free_pages(pages, 2);

    /* Abbruch mit zurückgehaltener erster Seite → einmal ausgeben */
    make_pages(pages, 1, -1);
    run_job(&cap, &s, 203, 0, -1, 5, true, pages, 1, true);
    CHECK_INT(cap.labels, 1);
    CHECK_INT(cap.quantities[0], 1);
    lw_buf_free(&cap.out);
    free_pages(pages, 1);

    /* Kopien begrenzen */
    make_pages(pages, 1, -1);
    run_job(&cap, &s, 203, 0, -1, 2000000000, false, pages, 1, false);
    CHECK_INT(cap.quantities[0], LW_MAX_QUANTITY);
    lw_buf_free(&cap.out);
    free_pages(pages, 1);
    make_pages(pages, 1, -1);
    run_job(&cap, &s, 203, 0, -1, -3, false, pages, 1, false);
    CHECK_INT(cap.quantities[0], 1);
    lw_buf_free(&cap.out);
    free_pages(pages, 1);

    /* Keine Seiten: nur Kopf und Ende */
    s.darkness = 5;
    s.end_commands = "END";
    s.end_commands_len = 3;
    run_job(&cap, &s, 203, 0, -1, 2, true, NULL, 0, false);
    CHECK_BUF_STR(cap.out, "~SD05\nEND\n");
    CHECK_INT(cap.labels, 0);
    lw_buf_free(&cap.out);
    s.darkness = LW_UNSET;
    s.end_commands = NULL;
    s.end_commands_len = 0;

    /* Seiten ohne Fläche werden übersprungen */
    lw_bitmap empty[2];
    lw_bitmap_init(&empty[0]);
    lw_bitmap_alloc(&empty[0], 0, 5);
    lw_bitmap_init(&empty[1]);
    lw_bitmap_alloc(&empty[1], 8, 0);
    run_job(&cap, &s, 203, 0, -1, 1, true, empty, 2, false);
    CHECK_INT(cap.labels, 0);
    CHECK_INT(cap.out.len, 0);
    lw_buf_free(&cap.out);
    free_pages(empty, 2);
}

/* Wie der Filter: ohne vorheriges lw_job_begin – der Kopf entsteht erst mit der ersten Seite
 * bzw. in lw_job_finish. Liefert die Rückgabe von lw_job_finish; `begun` meldet, ob der
 * Auftragskopf geschrieben wurde. */
static bool run_job_lazy(job_capture *cap, const lw_settings *s, int copies, lw_bitmap *pages, int count,
                         bool cancel, bool *begun)
{
    capture_init(cap);
    lw_job_config cfg = { s, 203, 0, -1, copies, true, false, 0, 0 };
    lw_job_hooks hooks = { capture_label, NULL, capture_canceled, cap, NULL, NULL };
    lw_job job;
    CHECK(lw_job_init(&job, &cfg, &cap->sink, &hooks));
    for (int i = 0; i < count; i++)
        CHECK(lw_job_add_page(&job, &pages[i], i + 1));
    bool ok = lw_job_finish(&job, cancel);
    if (begun != NULL)
        *begun = job.begun;
    /* Ein zweiter Aufruf ist wirkungslos – auch nach einem Abbruch ohne Kopf. */
    size_t len = cap->out.len;
    CHECK(lw_job_finish(&job, cancel));
    CHECK_INT(cap->out.len, len);
    lw_job_free(&job);
    return ok;
}

/* Regression: ein Abbruch vor der ersten Seite schrieb trotzdem den Auftragskopf (mit ~JC also
 * eine Kalibrierung samt Etikettenvorschub) und die Endbefehle. */
static void test_job_cancel_early(void)
{
    lw_settings s;
    lw_settings_init(&s);
    s.darkness = 10;
    s.tear_off = 10;
    s.calibrate = true;
    s.start_commands = "^XA^FXstart^XZ";
    s.start_commands_len = strlen(s.start_commands);
    s.end_commands = "~JR";
    s.end_commands_len = 3;
    job_capture cap;
    bool begun = true;

    /* ZPL: Abbruch ohne Seite → gar keine Ausgabe, auch kein Kopf. */
    CHECK(run_job_lazy(&cap, &s, 3, NULL, 0, true, &begun));
    CHECK(!begun);
    CHECK_INT(cap.out.len, 0);
    CHECK_INT(cap.labels, 0);
    lw_buf_free(&cap.out);

    /* Ohne Abbruch bleibt es beim Auftrag ohne Etiketten: Kopf und Endbefehle. */
    CHECK(run_job_lazy(&cap, &s, 3, NULL, 0, false, &begun));
    CHECK(begun);
    CHECK_BUF_STR(cap.out, "^XA^FXstart^XZ\n~SD10\n~TA010\n~JC\n~JR\n");
    CHECK_INT(cap.labels, 0);
    lw_buf_free(&cap.out);

    /* Kopf bereits geschrieben (erste Seite leer und übersprungen), dann Abbruch: die
     * Endbefehle gehören zum geschriebenen Kopf und werden weiterhin angehängt. */
    s.skip_blank = true;
    lw_bitmap pages[2];
    make_pages(pages, 1, 0);
    CHECK(run_job_lazy(&cap, &s, 3, pages, 1, true, &begun));
    CHECK(begun);
    CHECK_BUF_STR(cap.out, "^XA^FXstart^XZ\n~SD10\n~TA010\n~JC\n~JR\n");
    CHECK_INT(cap.labels, 0);
    lw_buf_free(&cap.out);
    free_pages(pages, 1);
    s.skip_blank = false;

    /* Abbruch mit zurückgehaltener erster Seite (Sortierung): Kopf, Seite einmal, Ende. */
    s.compression = LW_COMPRESSION_HEX;
    s.darkness = LW_UNSET;
    s.tear_off = LW_UNSET;
    s.calibrate = false;
    s.start_commands = "S";
    s.start_commands_len = 1;
    make_pages(pages, 1, -1);
    CHECK(run_job_lazy(&cap, &s, 3, pages, 1, true, &begun));
    CHECK_BUF_STR(cap.out, "S\n^XA\n^PW16\n^LL3\n^LH0,0\n^PON\n^PMN\n^FO0,0^GFA,6,6,2,000080000000^FS\n"
                           "^PQ1\n^XZ\n~JR\n");
    CHECK_INT(cap.labels, 1);
    CHECK_INT(cap.quantities[0], 1);
    lw_buf_free(&cap.out);
    free_pages(pages, 1);

    /* EPL: Start-/Endbefehle ebenfalls nur, wenn der Auftrag begonnen hat. */
    lw_settings_init(&s);
    s.language = LW_LANGUAGE_EPL;
    s.darkness = 10;
    s.start_commands = "OD";
    s.start_commands_len = 2;
    s.end_commands = "ENDE";
    s.end_commands_len = 4;
    CHECK(run_job_lazy(&cap, &s, 1, NULL, 0, true, &begun));
    CHECK(!begun);
    CHECK_INT(cap.out.len, 0);
    lw_buf_free(&cap.out);
    CHECK(run_job_lazy(&cap, &s, 1, NULL, 0, false, &begun));
    CHECK_BUF_STR(cap.out, "OD\nENDE\n");
    lw_buf_free(&cap.out);

    /* CPCL kennt keinen Kopf: Abbruch ohne Seite → leer. */
    lw_settings_init(&s);
    s.language = LW_LANGUAGE_CPCL;
    s.darkness = 30;
    CHECK(run_job_lazy(&cap, &s, 2, NULL, 0, true, &begun));
    CHECK_INT(cap.out.len, 0);
    lw_buf_free(&cap.out);
}

static void test_job_preprocess(void)
{
    lw_settings s;
    lw_settings_init(&s);
    s.compression = LW_COMPRESSION_HEX;
    s.negative = true;
    job_capture cap;
    /* Breite 20 → auf 9 abgeschnitten, dann invertiert (Füllbits bleiben 0) */
    lw_bitmap page;
    lw_bitmap_init(&page);
    lw_bitmap_alloc(&page, 20, 1);
    lw_bitmap_set(&page, 0, 0, true);
    lw_bitmap_set(&page, 8, 0, true);
    lw_bitmap_set(&page, 9, 0, true);
    run_job(&cap, &s, 203, 9, -1, 1, true, &page, 1, false);
    CHECK(strstr((const char *)cap.out.data, "^PW9\n^LL1\n") != NULL);
    CHECK(strstr((const char *)cap.out.data, "^GFA,2,2,2,7F00^FS") != NULL);
    lw_buf_free(&cap.out);
    lw_bitmap_free(&page);

    /* Negativ macht eine leere Seite schwarz → wird nicht übersprungen */
    s.skip_blank = true;
    lw_bitmap_init(&page);
    lw_bitmap_alloc(&page, 8, 1);
    run_job(&cap, &s, 203, 0, -1, 1, true, &page, 1, false);
    CHECK_INT(cap.labels, 1);
    CHECK(strstr((const char *)cap.out.data, "FF^FS") != NULL);
    lw_buf_free(&cap.out);
    lw_bitmap_free(&page);

    /* Schwarze Seite + Negativ = leer → übersprungen */
    lw_bitmap_init(&page);
    lw_bitmap_alloc(&page, 8, 1);
    memset(page.data, 0xFF, 1);
    run_job(&cap, &s, 203, 0, -1, 1, true, &page, 1, false);
    CHECK_INT(cap.labels, 0);
    lw_buf_free(&cap.out);
    lw_bitmap_free(&page);
}

/* ------------------------------------------------------------------------------------------ */
/* Hilfen                                                                                     */
/* ------------------------------------------------------------------------------------------ */

static void test_util(void)
{
    char buf[8];
    CHECK(lw_trim_copy(buf, sizeof(buf), "  abc \t"));
    CHECK(strcmp(buf, "abc") == 0);
    CHECK(!lw_trim_copy(buf, sizeof(buf), "123456789"));
    CHECK(strcmp(buf, "1234567") == 0);
    CHECK(lw_trim_copy(buf, sizeof(buf), NULL));
    CHECK(buf[0] == '\0');
    CHECK(lw_str_ieq("ZpL", "zpl"));
    CHECK(!lw_str_ieq("zpl", "zpl2"));
    CHECK(lw_str_ieq(NULL, NULL));
    CHECK(!lw_str_ieq("a", NULL));
    CHECK(lw_str_nieq("Custom.12", "custom.", 7));
    lw_buf b;
    lw_buf_init(&b);
    for (int i = 0; i < 1000; i++)
        lw_buf_printf(&b, "%04d", i);
    CHECK_INT(b.len, 4000);
    CHECK(memcmp(b.data + 3996, "0999", 4) == 0);
    char big[600];
    memset(big, 'x', sizeof(big) - 1);
    big[sizeof(big) - 1] = '\0';
    lw_buf_reset(&b);
    lw_buf_printf(&b, "<%s>", big);
    CHECK_INT(b.len, 601);
    lw_buf_free(&b);
    lw_buf sinkbuf;
    lw_buf_init(&sinkbuf);
    lw_sink sink;
    lw_sink_init_buf(&sink, &sinkbuf);
    lw_sink_printf(&sink, "%s", big);
    lw_sink_puts(&sink, "!");
    CHECK_INT(sinkbuf.len, 600);
    CHECK(lw_sink_flush(&sink));
    lw_buf_free(&sinkbuf);
    CHECK(strcmp(lw_log_prefix(LW_LOG_WARNING), "WARNING") == 0);
}

/* ------------------------------------------------------------------------------------------ */

typedef struct test_case {
    const char *name;
    void (*fn)(void);
} test_case;

static const test_case tests[] = {
    { "crc16", test_crc16 },
    { "base64", test_base64 },
    { "hex", test_hex },
    { "base64url", test_base64url },
    { "utf8", test_utf8 },
    { "acs_known", test_acs_known },
    { "acs_roundtrip", test_acs_roundtrip },
    { "z64", test_z64 },
    { "bitmap_ops", test_bitmap_ops },
    { "dither_threshold", test_dither_threshold },
    { "dither_matrix", test_dither_matrix },
    { "dither_fs_hand", test_dither_fs_hand },
    { "dither_vs_naive", test_dither_vs_naive },
    { "raster_gray", test_raster_gray },
    { "raster_color", test_raster_color },
    { "raster_errors", test_raster_errors },
    { "parse_values", test_parse_values },
    { "resolve", test_resolve },
    { "job_zpl", test_job_zpl },
    { "job_epl", test_job_epl },
    { "job_cpcl", test_job_cpcl },
    { "job_copies", test_job_copies },
    { "job_cancel_early", test_job_cancel_early },
    { "job_preprocess", test_job_preprocess },
    { "util", test_util },
};

int main(int argc, char *argv[])
{
    size_t count = sizeof(tests) / sizeof(tests[0]);
    int run = 0;
    for (size_t i = 0; i < count; i++) {
        bool selected = argc < 2;
        for (int a = 1; a < argc; a++)
            if (strstr(tests[i].name, argv[a]) != NULL)
                selected = true;
        if (!selected)
            continue;
        g_current = tests[i].name;
        long before = g_failures;
        tests[i].fn();
        run++;
        printf("%-18s %s\n", tests[i].name, g_failures == before ? "ok" : "FEHLER");
    }
    printf("\n%d Tests, %ld Prüfungen, %ld Fehler\n", run, g_checks, g_failures);
    return g_failures == 0 && run > 0 ? 0 : 1;
}
