/*
 * test_backend.c – C-Unit-Tests des Backend-Kerns (lwb_core): Zerlegung in Auftragskopf und Formate
 * (Standard- und eigene Steuerzeichen, Präfixwechsel im Datenstrom, ^GFB-Binärdaten, stückweise
 * Eingabe), Etikettenzählung (^PQ, ^DF, Formate ohne Druck), Mengenänderung, ~HS-Auswertung
 * (wie LabelWerkStatus.HostStatusParser, auch zwischen fremden Antworten und stückweise) und URIs.
 *
 * Aufruf: test_backend [Namensfilter …]; Exitcode 0, wenn alle Prüfungen bestehen.
 */

#if !defined(__APPLE__) && !defined(_DEFAULT_SOURCE)
#  define _DEFAULT_SOURCE 1
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lwb_core.h"

static long g_checks = 0;
static long g_failures = 0;
static const char *g_current = "";

#define CHECK(cond)                                                                                  \
    do {                                                                                             \
        g_checks++;                                                                                  \
        if (!(cond)) {                                                                               \
            g_failures++;                                                                            \
            fprintf(stderr, "  FEHLER [%s] %s:%d: %s\n", g_current, __FILE__, __LINE__, #cond);     \
        }                                                                                            \
    } while (0)

#define CHECK_INT(actual, expected)                                                                  \
    do {                                                                                             \
        long long a_ = (long long)(actual), e_ = (long long)(expected);                              \
        g_checks++;                                                                                  \
        if (a_ != e_) {                                                                              \
            g_failures++;                                                                            \
            fprintf(stderr, "  FEHLER [%s] %s:%d: %s = %lld, erwartet %lld\n", g_current, __FILE__, \
                    __LINE__, #actual, a_, e_);                                                      \
        }                                                                                            \
    } while (0)

#define CHECK_STR(actual, expected)                                                                  \
    do {                                                                                             \
        const char *a_ = (actual), *e_ = (expected);                                                 \
        g_checks++;                                                                                  \
        if (strcmp(a_, e_) != 0) {                                                                   \
            g_failures++;                                                                            \
            fprintf(stderr, "  FEHLER [%s] %s:%d: „%s“, erwartet „%s“\n", g_current, __FILE__,      \
                    __LINE__, a_, e_);                                                               \
        }                                                                                            \
    } while (0)

/* --- Hilfen ------------------------------------------------------------------------------ */

#define MAX_SEGMENTS 64

typedef struct split_result {
    int count;
    lwb_segment_kind kind[MAX_SEGMENTS];
    char text[MAX_SEGMENTS][512];
    lwb_prefixes start[MAX_SEGMENTS];
} split_result;

/* Zerlegt `data` vollständig; `chunk` > 0 = stückweise wie beim Lesen aus einer Pipe. */
static void split(const char *data, size_t len, lwb_prefixes prefixes, size_t chunk, split_result *r)
{
    memset(r, 0, sizeof(*r));
    size_t available = chunk > 0 ? (chunk < len ? chunk : len) : len;
    size_t pos = 0;
    while (pos < len && r->count < MAX_SEGMENTS) {
        bool final = available >= len;
        size_t seg = 0;
        lwb_prefixes start = prefixes;
        lwb_segment_kind kind =
            lwb_next_segment((const uint8_t *)data + pos, available - pos, final, &prefixes, &seg);
        if (kind == LWB_SEGMENT_NONE) {
            if (final)
                break;
            available = available + chunk < len ? available + chunk : len;
            continue;
        }
        r->kind[r->count] = kind;
        r->start[r->count] = start;
        size_t copy = seg < sizeof(r->text[0]) - 1 ? seg : sizeof(r->text[0]) - 1;
        memcpy(r->text[r->count], data + pos, copy);
        r->text[r->count][copy] = '\0';
        r->count++;
        pos += seg;
        if (pos > available)
            available = pos;
    }
}

static lwb_prefixes custom_prefixes(char format, char control, char delimiter)
{
    lwb_prefixes p = { (uint8_t)format, (uint8_t)control, (uint8_t)delimiter };
    return p;
}

/* Fügt Segmente wieder zusammen (Verlustfreiheit). */
static void joined(const split_result *r, char *out, size_t size)
{
    out[0] = '\0';
    for (int k = 0; k < r->count; k++)
        strncat(out, r->text[k], size - strlen(out) - 1);
}

/* --- Zerlegung --------------------------------------------------------------------------- */

static const char JOB[] =
    "~SD15\n~TA010\n~JSN\n"
    "^XA\n^PW832\n^LL609\n^FO0,0^GFA,4,4,1,FF00FF00^FS\n^PQ3\n^XZ\n"
    "^XA^ST11,13,2026,10,00,00,M^XZ\n"
    "^XA\n^FO0,0^GFA,2,2,1,0F0F^FS\n^PQ1\n^XZ\n"
    "^XA\n^FO0,0^GFA,2,2,1,F0F0^FS\n^XZ\n";

static void test_split_standard(void)
{
    split_result r;
    split(JOB, strlen(JOB), lwb_prefixes_standard(), 0, &r);
    CHECK_INT(r.count, 5);
    CHECK_INT(r.kind[0], LWB_SEGMENT_RAW);
    CHECK_STR(r.text[0], "~SD15\n~TA010\n~JSN\n");
    CHECK_INT(r.kind[1], LWB_SEGMENT_FORMAT);
    CHECK_STR(r.text[1], "^XA\n^PW832\n^LL609\n^FO0,0^GFA,4,4,1,FF00FF00^FS\n^PQ3\n^XZ\n");
    CHECK_INT(r.kind[2], LWB_SEGMENT_FORMAT);
    CHECK_STR(r.text[2], "^XA^ST11,13,2026,10,00,00,M^XZ\n");
    CHECK_INT(r.kind[3], LWB_SEGMENT_FORMAT);
    CHECK_INT(r.kind[4], LWB_SEGMENT_FORMAT);
    char all[4096];
    joined(&r, all, sizeof(all));
    CHECK_STR(all, JOB);
}

static void test_split_chunked(void)
{
    /* Jede Stückgröße liefert dieselbe Zerlegung. */
    split_result whole;
    split(JOB, strlen(JOB), lwb_prefixes_standard(), 0, &whole);
    for (size_t chunk = 1; chunk <= 17; chunk++) {
        split_result r;
        split(JOB, strlen(JOB), lwb_prefixes_standard(), chunk, &r);
        char all[4096];
        joined(&r, all, sizeof(all));
        CHECK_STR(all, JOB);
        int formats = 0;
        for (int k = 0; k < r.count; k++) {
            if (r.kind[k] == LWB_SEGMENT_FORMAT) {
                formats++;
                CHECK(strncmp(r.text[k], "^XA", 3) == 0);
                CHECK(strstr(r.text[k], "^XZ") != NULL);
            }
        }
        CHECK_INT(formats, 4);
    }
}

static void test_split_custom_prefixes(void)
{
    /* „Intern“: ^ → !, ~ → #, , → ; (wie der Filter mit lwControlChars=Printer). */
    const char job[] = "#SD15\n!XA\n!FO0;0!GFA;2;2;1;0F0F!FS\n!PQ2;0;0;N\n!XZ\n!XA\n!FO0;0!FDx!FS\n!XZ\n";
    split_result r;
    split(job, strlen(job), custom_prefixes('!', '#', ';'), 0, &r);
    CHECK_INT(r.count, 3);
    CHECK_INT(r.kind[0], LWB_SEGMENT_RAW);
    CHECK_STR(r.text[0], "#SD15\n");
    CHECK_INT(r.kind[1], LWB_SEGMENT_FORMAT);
    CHECK_INT(r.kind[2], LWB_SEGMENT_FORMAT);
    lwb_format_info info;
    lwb_format_analyze((const uint8_t *)r.text[1], strlen(r.text[1]), r.start[1], &info);
    CHECK(info.prints);
    CHECK_INT(info.quantity, 2);

    /* Mit Standardzeichen gelesen: kein Format erkannt – alles Rohdaten. */
    split(job, strlen(job), lwb_prefixes_standard(), 0, &r);
    CHECK_INT(r.count, 1);
    CHECK_INT(r.kind[0], LWB_SEGMENT_RAW);
}

static void test_split_prefix_change(void)
{
    /* ^CC! im Kopf wechselt das Formatzeichen; ~CT# das Steuerzeichen; danach !XA … !XZ. */
    const char job[] = "^CC!\n~CT#\n!XA!FO0,0!FDa!FS!XZ\n#JA\n!XA!FDb!FS!CC^^PQ2^XZ\n^XA^FDc^FS^XZ";
    split_result r;
    split(job, strlen(job), lwb_prefixes_standard(), 0, &r);
    CHECK_INT(r.count, 5);
    CHECK_INT(r.kind[0], LWB_SEGMENT_RAW);
    CHECK_STR(r.text[0], "^CC!\n~CT#\n");
    CHECK_INT(r.kind[1], LWB_SEGMENT_FORMAT);
    CHECK_STR(r.text[1], "!XA!FO0,0!FDa!FS!XZ\n");
    CHECK_INT(r.kind[2], LWB_SEGMENT_RAW);
    CHECK_STR(r.text[2], "#JA\n");
    CHECK_INT(r.kind[3], LWB_SEGMENT_FORMAT);
    CHECK_STR(r.text[3], "!XA!FDb!FS!CC^^PQ2^XZ\n");
    CHECK_INT(r.start[3].control, '#');
    lwb_format_info info;
    lwb_format_analyze((const uint8_t *)r.text[3], strlen(r.text[3]), r.start[3], &info);
    CHECK(info.prints);
    CHECK_INT(info.quantity, 2);
    CHECK_INT(r.kind[4], LWB_SEGMENT_FORMAT);
    CHECK_STR(r.text[4], "^XA^FDc^FS^XZ");
    /* Stückweise dieselben Formate (Rohdaten dürfen in mehreren Stücken kommen). */
    for (size_t chunk = 1; chunk <= 7; chunk++) {
        split_result c;
        split(job, strlen(job), lwb_prefixes_standard(), chunk, &c);
        int formats = 0;
        for (int k = 0; k < c.count; k++) {
            if (c.kind[k] != LWB_SEGMENT_FORMAT)
                continue;
            int expected[] = { 1, 3, 4 };
            /* Endet ein Stück direkt nach ^XZ, folgt das Zeilenende als Rohdaten. */
            if (formats < 3)
                CHECK(strncmp(c.text[k], r.text[expected[formats]], strlen(c.text[k])) == 0 &&
                      strlen(r.text[expected[formats]]) - strlen(c.text[k]) <= 1);
            formats++;
        }
        CHECK_INT(formats, 3);
        char all[512];
        joined(&c, all, sizeof(all));
        CHECK_STR(all, job);
    }
}

static void test_split_binary_graphic(void)
{
    /* ^GFB mit Binärdaten, die „^XZ“ und „^XA“ enthalten: kein Fehltreffer. */
    char job[256];
    const char head[] = "^XA^FO0,0^GFB,8,8,1,";
    const char data[8] = { '^', 'X', 'Z', 0, '^', 'X', 'A', 1 };
    const char tail[] = "^FS^PQ4^XZ\n^XA^FDz^FS^XZ\n";
    size_t n = 0;
    memcpy(job + n, head, strlen(head));
    n += strlen(head);
    memcpy(job + n, data, sizeof(data));
    n += sizeof(data);
    memcpy(job + n, tail, strlen(tail));
    n += strlen(tail);
    size_t seg = 0;
    lwb_prefixes p = lwb_prefixes_standard();
    lwb_segment_kind kind = lwb_next_segment((const uint8_t *)job, n, true, &p, &seg);
    CHECK_INT(kind, LWB_SEGMENT_FORMAT);
    CHECK_INT(seg, strlen(head) + sizeof(data) + strlen("^FS^PQ4^XZ\n"));
    lwb_format_info info;
    lwb_format_analyze((const uint8_t *)job, seg, lwb_prefixes_standard(), &info);
    CHECK(info.prints);
    CHECK_INT(info.quantity, 4);
    /* Unvollständige Binärdaten ohne final: weiterlesen. */
    p = lwb_prefixes_standard();
    kind = lwb_next_segment((const uint8_t *)job, strlen(head) + 5, false, &p, &seg);
    CHECK_INT(kind, LWB_SEGMENT_NONE);
}

static void test_split_edge_cases(void)
{
    size_t seg = 0;
    lwb_prefixes p = lwb_prefixes_standard();
    /* Leerer Puffer */
    CHECK_INT(lwb_next_segment((const uint8_t *)"", 0, true, &p, &seg), LWB_SEGMENT_NONE);
    /* Abgeschnittenes Präfix am Ende: Rohdaten nur bis davor. */
    const char *a = "~SD10\n^X";
    CHECK_INT(lwb_next_segment((const uint8_t *)a, strlen(a), false, &p, &seg), LWB_SEGMENT_RAW);
    CHECK_INT(seg, 6);
    CHECK_INT(lwb_next_segment((const uint8_t *)a + 6, 2, false, &p, &seg), LWB_SEGMENT_NONE);
    /* … mit final als Rohdaten. */
    CHECK_INT(lwb_next_segment((const uint8_t *)a + 6, 2, true, &p, &seg), LWB_SEGMENT_RAW);
    CHECK_INT(seg, 2);
    /* Format ohne ^XZ: ohne final weiterlesen, mit final Rohdaten. */
    const char *b = "^XA^FDx^FS";
    CHECK_INT(lwb_next_segment((const uint8_t *)b, strlen(b), false, &p, &seg), LWB_SEGMENT_NONE);
    CHECK_INT(lwb_next_segment((const uint8_t *)b, strlen(b), true, &p, &seg), LWB_SEGMENT_RAW);
    CHECK_INT(seg, strlen(b));
    /* Kleinbuchstaben und CR LF */
    const char *c = "^xa^fdx^fs^xz\r\n~HS";
    CHECK_INT(lwb_next_segment((const uint8_t *)c, strlen(c), true, &p, &seg), LWB_SEGMENT_FORMAT);
    CHECK_INT(seg, strlen("^xa^fdx^fs^xz\r\n"));
    /* Nur Steuerbefehle (Befehlsfilter: Kalibrieren) */
    const char *d = "~JC\n";
    CHECK_INT(lwb_next_segment((const uint8_t *)d, strlen(d), true, &p, &seg), LWB_SEGMENT_RAW);
    CHECK_INT(seg, 4);
    /* EPL-Daten ohne ^: alles Rohdaten */
    const char *e = "\nN\nq832\nQ609,24\nP1\n";
    CHECK_INT(lwb_next_segment((const uint8_t *)e, strlen(e), true, &p, &seg), LWB_SEGMENT_RAW);
    CHECK_INT(seg, strlen(e));
}

/* --- Formate ----------------------------------------------------------------------------- */

static void test_format_analyze(void)
{
    struct {
        const char *format;
        bool prints;
        long quantity;
    } cases[] = {
        { "^XA^FO0,0^GFA,1,1,1,FF^FS^PQ5^XZ", true, 5 },
        { "^XA^FO0,0^GFA,1,1,1,FF^FS^PQ5,2,0,N^XZ", true, 5 },
        { "^XA^FO10,10^A0N,30,30^FDHallo^FS^XZ", true, 1 },
        { "^XA^PQ0^FDx^FS^XZ", true, 1 },
        { "^XA^ST11,13,2026,10,00,00,M^XZ", false, 0 },
        { "^XA^MFF,C^XZ", false, 0 },
        { "^XA^JUS^XZ", false, 0 },
        { "^XA^JZY^XZ", false, 0 },
        { "^XA^DFR:FORM.ZPL^FS^FO0,0^FN1^FS^XZ", false, 0 },
        { "^XA^XFR:FORM.ZPL^FN1^FDWert^FS^PQ2^XZ", true, 2 },
        { "^XA^FO0,0^GB100,100,3^FS^PQ12^XZ", true, 12 },
    };
    for (size_t k = 0; k < sizeof(cases) / sizeof(cases[0]); k++) {
        lwb_format_info info;
        lwb_format_analyze((const uint8_t *)cases[k].format, strlen(cases[k].format), lwb_prefixes_standard(), &info);
        CHECK_INT(info.prints, cases[k].prints);
        CHECK_INT(info.quantity, cases[k].quantity);
    }
}

static void test_format_quantity(void)
{
    lw_buf out;
    lw_buf_init(&out);
    const char *a = "^XA^FDx^FS^PQ5,2,0,N^XZ\n";
    CHECK(lwb_format_with_quantity((const uint8_t *)a, strlen(a), lwb_prefixes_standard(), 2, &out));
    CHECK_STR((const char *)out.data, "^XA^FDx^FS^PQ2,2,0,N^XZ\n");
    const char *b = "^XA^FDx^FS^XZ\n";
    CHECK(lwb_format_with_quantity((const uint8_t *)b, strlen(b), lwb_prefixes_standard(), 3, &out));
    CHECK_STR((const char *)out.data, "^XA^FDx^FS^PQ3\n^XZ\n");
    const char *c = "!XA!FDx!FS!XZ";
    CHECK(lwb_format_with_quantity((const uint8_t *)c, strlen(c), custom_prefixes('!', '#', ';'), 7, &out));
    CHECK_STR((const char *)out.data, "!XA!FDx!FS!PQ7\n!XZ");
    const char *d = "^XA^FDx^FS";
    CHECK(!lwb_format_with_quantity((const uint8_t *)d, strlen(d), lwb_prefixes_standard(), 1, &out));
    lw_buf_free(&out);
}

/* --- ~HS --------------------------------------------------------------------------------- */

static const char HS_IDLE[] =
    "\x02" "030,0,0,0609,000,0,0,0,000,0,0,0" "\x03\r\n"
    "\x02" "000,0,0,0,1,2,6,0,00000000,1,000" "\x03\r\n"
    "\x02" "1234,0" "\x03\r\n";

static void test_host_status(void)
{
    lwb_host_status st;
    size_t consumed = 0;
    CHECK(lwb_parse_host_status((const uint8_t *)HS_IDLE, strlen(HS_IDLE), &st, &consumed));
    CHECK_INT(consumed, strlen(HS_IDLE));
    CHECK(!st.paper_out);
    CHECK(!st.paused);
    CHECK_INT(st.formats_in_buffer, 0);
    CHECK_INT(st.labels_remaining, 0);
    CHECK(lwb_status_idle(&st));
    CHECK_INT(lwb_status_reasons(&st), 0);

    const char busy[] =
        "\x02" "030,1,1,0609,002,0,0,1,000,0,0,1" "\x03\r\n"
        "\x02" "000,0,1,1,1,2,6,1,00000037,1,000" "\x03\r\n"
        "\x02" "1234,0" "\x03\r\n";
    CHECK(lwb_parse_host_status((const uint8_t *)busy, strlen(busy), &st, &consumed));
    CHECK(st.paper_out);
    CHECK(st.paused);
    CHECK_INT(st.formats_in_buffer, 2);
    CHECK(st.partial_format);
    CHECK(st.over_temperature);
    CHECK(st.head_open);
    CHECK(st.ribbon_out);
    CHECK(st.label_waiting);
    CHECK_INT(st.labels_remaining, 37);
    CHECK(!lwb_status_idle(&st));
    CHECK_INT(lwb_status_reasons(&st), LWB_REASON_MEDIA_EMPTY | LWB_REASON_RIBBON_EMPTY |
                                           LWB_REASON_COVER_OPEN | LWB_REASON_PAUSED);
}

static void test_host_status_noise(void)
{
    /* Fremde Antwort (~HI) und Rauschen davor; Druckmodus als Buchstabe (K). */
    char data[512];
    snprintf(data, sizeof(data), "xx\x02ZD421-203dpi,V84.20.18Z,8,8192KB\x03\r\n%s",
             "\x02" "030,0,0,0609,001,0,0,0,000,0,0,0" "\x03\r\n"
             "\x02" "000,0,0,0,1,K,6,0,00000002,1,000" "\x03\r\n"
             "\x02" "1234,0" "\x03\r\n");
    lwb_host_status st;
    size_t consumed = 0;
    CHECK(lwb_parse_host_status((const uint8_t *)data, strlen(data), &st, &consumed));
    CHECK_INT(consumed, strlen(data));
    CHECK_INT(st.formats_in_buffer, 1);
    CHECK_INT(st.labels_remaining, 2);

    /* Stückweise: erst bei vollständigen Zeilen 1 und 2 ein Ergebnis. */
    size_t full = strlen(HS_IDLE);
    size_t line12 = strlen("\x02" "030,0,0,0609,000,0,0,0,000,0,0,0" "\x03\r\n"
                           "\x02" "000,0,0,0,1,2,6,0,00000000,1,000" "\x03");
    for (size_t cut = 0; cut < full; cut++) {
        bool ok = lwb_parse_host_status((const uint8_t *)HS_IDLE, cut, &st, &consumed);
        CHECK_INT(ok, cut >= line12);
        if (!ok)
            CHECK_INT(consumed, 0);   /* nichts verwerfen, was zur Antwort gehört */
    }

    /* Nur fremde Antworten: alles verwerfbar. */
    const char other[] = "\x02" "ZD421-203dpi,V84.20.18Z,8,8192KB" "\x03\r\n";
    CHECK(!lwb_parse_host_status((const uint8_t *)other, strlen(other), &st, &consumed));
    CHECK(consumed >= strlen(other) - 2);
}

/* --- URI --------------------------------------------------------------------------------- */

static void test_uri(void)
{
    char host[256], options[128];
    int port = 0;
    CHECK(lwb_parse_uri("labelwerk://10.62.13.19:9100", host, sizeof(host), &port, options, sizeof(options)));
    CHECK_STR(host, "10.62.13.19");
    CHECK_INT(port, 9100);
    CHECK_STR(options, "");
    CHECK(lwb_parse_uri("labelwerk://zd421.local", host, sizeof(host), &port, options, sizeof(options)));
    CHECK_STR(host, "zd421.local");
    CHECK_INT(port, 9100);
    CHECK(lwb_parse_uri("labelwerk://[fe80::1%25en0]:6101/?mode=stream", host, sizeof(host), &port, options,
                        sizeof(options)));
    CHECK_STR(host, "fe80::1%en0");
    CHECK_INT(port, 6101);
    CHECK_STR(options, "mode=stream");
    char value[32];
    CHECK(lwb_uri_option(options, "mode", value, sizeof(value)));
    CHECK_STR(value, "stream");
    CHECK(!lwb_uri_option(options, "other", value, sizeof(value)));
    CHECK(lwb_uri_option("a=1&mode=x", "MODE", value, sizeof(value)));
    CHECK_STR(value, "x");
    CHECK(lwb_parse_uri("labelwerk://user@host:1", host, sizeof(host), &port, NULL, 0));
    CHECK_STR(host, "host");
    CHECK(!lwb_parse_uri("labelwerk://", host, sizeof(host), &port, NULL, 0));
    CHECK(!lwb_parse_uri("labelwerk://host:0", host, sizeof(host), &port, NULL, 0));
    CHECK(!lwb_parse_uri("labelwerk://host:99999", host, sizeof(host), &port, NULL, 0));
    CHECK(!lwb_parse_uri("labelwerk://host:12a", host, sizeof(host), &port, NULL, 0));
    CHECK(!lwb_parse_uri("labelwerk://[::1", host, sizeof(host), &port, NULL, 0));
    CHECK(!lwb_parse_uri("nonsense", host, sizeof(host), &port, NULL, 0));
}

/* --- Rahmen ------------------------------------------------------------------------------ */

typedef struct test_case {
    const char *name;
    void (*run)(void);
} test_case;

static const test_case TESTS[] = {
    { "split_standard", test_split_standard },
    { "split_chunked", test_split_chunked },
    { "split_custom_prefixes", test_split_custom_prefixes },
    { "split_prefix_change", test_split_prefix_change },
    { "split_binary_graphic", test_split_binary_graphic },
    { "split_edge_cases", test_split_edge_cases },
    { "format_analyze", test_format_analyze },
    { "format_quantity", test_format_quantity },
    { "host_status", test_host_status },
    { "host_status_noise", test_host_status_noise },
    { "uri", test_uri },
};

int main(int argc, char **argv)
{
    int run = 0;
    for (size_t k = 0; k < sizeof(TESTS) / sizeof(TESTS[0]); k++) {
        bool selected = argc < 2;
        for (int a = 1; a < argc; a++) {
            if (strstr(TESTS[k].name, argv[a]) != NULL)
                selected = true;
        }
        if (!selected)
            continue;
        g_current = TESTS[k].name;
        long before = g_failures;
        TESTS[k].run();
        printf("%s %s\n", g_failures == before ? "ok  " : "FAIL", TESTS[k].name);
        run++;
    }
    printf("%d Tests, %ld Prüfungen, %ld Fehler\n", run, g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
