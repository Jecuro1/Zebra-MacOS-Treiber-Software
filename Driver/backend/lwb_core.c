/*
 * lwb_core.c – Reine Logik des CUPS-Backends „labelwerk“ (siehe lwb_core.h).
 *
 * Copyright (c) LabelWerk-Projekt. Zebra ist eine Marke der Zebra Technologies Corp.
 */

#include "lwb_core.h"

#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define STX 0x02
#define ETX 0x03

lwb_prefixes lwb_prefixes_standard(void)
{
    lwb_prefixes p = { '^', '~', ',' };
    return p;
}

static int upper(int c)
{
    return (c >= 'a' && c <= 'z') ? c - 'a' + 'A' : c;
}

static bool is_command_char(int c)
{
    return c >= 33 && c <= 126;
}

/* ------------------------------------------------------------------------------------------ */
/* Befehlsscanner                                                                             */
/* ------------------------------------------------------------------------------------------ */

/* Ergebnis eines Scanschritts an Position i. */
typedef enum scan_step {
    SCAN_BYTE = 0,      /* gewöhnliches Byte, weiter mit i + 1 */
    SCAN_COMMAND,       /* Befehl erkannt: cmd[0..1], next = Position nach dem Befehl */
    SCAN_INCOMPLETE     /* Befehl am Pufferende abgeschnitten */
} scan_step;

typedef struct scan_result {
    scan_step step;
    bool format;        /* mit Formatzeichen (^) eingeleitet, sonst Steuerzeichen (~) */
    char cmd[3];
    size_t next;
} scan_result;

/*
 * Liest den Befehl an Position i (data[i] ist ein Präfix). Behandelt Präfixwechsel (CC/CT/CD,
 * aktualisiert `p`) und überspringt die Binärdaten von ^GFB (Länge = zweiter Parameter).
 */
static scan_result scan_command(const uint8_t *data, size_t len, size_t i, bool final, lwb_prefixes *p)
{
    scan_result r;
    memset(&r, 0, sizeof(r));
    r.step = SCAN_BYTE;
    r.next = i + 1;
    int c = data[i];
    if (c != p->format && c != p->control)
        return r;
    if (i + 2 >= len) {
        r.step = final ? SCAN_BYTE : SCAN_INCOMPLETE;
        return r;
    }
    r.format = (c == p->format);
    r.cmd[0] = (char)upper(data[i + 1]);
    r.cmd[1] = (char)upper(data[i + 2]);
    r.cmd[2] = '\0';
    r.step = SCAN_COMMAND;
    r.next = i + 3;

    if (r.cmd[0] == 'C' && (r.cmd[1] == 'C' || r.cmd[1] == 'T' || r.cmd[1] == 'D')) {
        if (i + 3 >= len) {
            if (!final)
                r.step = SCAN_INCOMPLETE;
            return r;
        }
        int value = data[i + 3];
        if (is_command_char(value)) {
            if (r.cmd[1] == 'C')
                p->format = (uint8_t)value;
            else if (r.cmd[1] == 'T')
                p->control = (uint8_t)value;
            else
                p->delimiter = (uint8_t)value;
        }
        r.next = i + 4;
        return r;
    }

    if (r.format && r.cmd[0] == 'G' && r.cmd[1] == 'F' && i + 3 < len && upper(data[i + 3]) == 'B') {
        /* ^GFB,b,c,d,<b Binärbytes>: Kopf bis zum vierten Trennzeichen lesen. */
        size_t j = i + 4;
        int delimiters = 0;
        long count = -1;
        long value = 0;
        bool digits = false;
        while (j < len && delimiters < 4) {
            int ch = data[j];
            if (ch == p->delimiter) {
                if (delimiters == 1)
                    count = digits ? value : -1;
                delimiters++;
                value = 0;
                digits = false;
            } else if (ch >= '0' && ch <= '9') {
                if (value < 100000000L)
                    value = value * 10 + (ch - '0');
                digits = true;
            } else if (ch == p->format || ch == p->control) {
                break;   /* kein vollständiger Kopf – wie ein gewöhnlicher Befehl behandeln */
            }
            j++;
        }
        if (delimiters < 4) {
            if (j >= len && !final)
                r.step = SCAN_INCOMPLETE;
            return r;
        }
        if (count < 0)
            return r;
        if ((size_t)count > len - j) {
            if (!final)
                r.step = SCAN_INCOMPLETE;
            else
                r.next = len;
            return r;
        }
        r.next = j + (size_t)count;
    }
    return r;
}

lwb_segment_kind lwb_next_segment(const uint8_t *data, size_t len, bool final, lwb_prefixes *prefixes,
                                  size_t *segment_len)
{
    *segment_len = 0;
    if (len == 0)
        return LWB_SEGMENT_NONE;
    lwb_prefixes p = *prefixes;
    size_t i = 0;

    bool at_format = false;
    /* Rohdaten bis zum nächsten ^XA. */
    while (i < len) {
        lwb_prefixes before = p;
        scan_result r = scan_command(data, len, i, final, &p);
        if (r.step == SCAN_INCOMPLETE) {
            p = before;
            if (i > 0) {
                *segment_len = i;
                *prefixes = p;
                return LWB_SEGMENT_RAW;
            }
            return LWB_SEGMENT_NONE;
        }
        if (r.step == SCAN_COMMAND && r.format && r.cmd[0] == 'X' && r.cmd[1] == 'A') {
            p = before;
            if (i > 0) {
                *segment_len = i;
                *prefixes = p;
                return LWB_SEGMENT_RAW;
            }
            at_format = true;
            i = r.next;
            break;
        }
        i = r.next;
    }
    if (!at_format) {
        *segment_len = len;
        *prefixes = p;
        return LWB_SEGMENT_RAW;
    }

    /* Format bis ^XZ (Präfixwechsel innerhalb des Formats gelten sofort). */
    while (i < len) {
        scan_result r = scan_command(data, len, i, final, &p);
        if (r.step == SCAN_INCOMPLETE)
            break;
        if (r.step == SCAN_COMMAND && r.format && r.cmd[0] == 'X' && r.cmd[1] == 'Z') {
            size_t end = r.next;
            if (end < len && data[end] == '\r')
                end++;
            if (end < len && data[end] == '\n')
                end++;
            *segment_len = end;
            *prefixes = p;
            return LWB_SEGMENT_FORMAT;
        }
        i = r.next > len ? len : r.next;
    }
    if (final) {
        *segment_len = len;
        *prefixes = p;
        return LWB_SEGMENT_RAW;
    }
    return LWB_SEGMENT_NONE;
}

/* ------------------------------------------------------------------------------------------ */
/* Formate                                                                                    */
/* ------------------------------------------------------------------------------------------ */

/* Befehle, mit denen ein Format etwas druckt (Felder, Grafiken, Barcodes über ^FD …). */
static bool is_printing_command(const char *cmd)
{
    static const char *const printing[] = { "FO", "FT", "FD", "FV", "GF", "GB", "GC", "GD", "GE", "XG", "XF", NULL };
    for (size_t k = 0; printing[k] != NULL; k++) {
        if (cmd[0] == printing[k][0] && cmd[1] == printing[k][1])
            return true;
    }
    return false;
}

/* Liest eine Dezimalzahl ab data[i]; liefert die Position danach (i, wenn keine Ziffer folgt). */
static size_t read_number(const uint8_t *data, size_t len, size_t i, long *value)
{
    long v = 0;
    size_t j = i;
    while (j < len && data[j] >= '0' && data[j] <= '9') {
        if (v < 100000000L)
            v = v * 10 + (data[j] - '0');
        j++;
    }
    *value = v;
    return j;
}

bool lwb_segment_is_download(const uint8_t *data, size_t len, lwb_prefixes prefixes)
{
    size_t i = 0;
    while (i < len) {
        int c = data[i];
        if (c < 0x09 || (c >= 0x0E && c < 0x20)) {
            /* STX/ETX kommen in ZPL-Aufträgen nicht vor; alles andere Binäre auch nicht. */
            return true;
        }
        scan_result r = scan_command(data, len, i, true, &prefixes);
        if (r.step == SCAN_COMMAND && !r.format && r.cmd[0] == 'D' &&
            (r.cmd[1] == 'G' || r.cmd[1] == 'Y' || r.cmd[1] == 'B' || r.cmd[1] == 'S' || r.cmd[1] == 'T' ||
             r.cmd[1] == 'U' || r.cmd[1] == 'N'))
            return true;
        i = r.next > len ? len : r.next;
    }
    return false;
}

void lwb_format_analyze(const uint8_t *data, size_t len, lwb_prefixes prefixes, lwb_format_info *info)
{
    memset(info, 0, sizeof(*info));
    bool stores = false;
    long quantity = 1;
    size_t i = 0;
    while (i < len) {
        scan_result r = scan_command(data, len, i, true, &prefixes);
        if (r.step == SCAN_COMMAND && r.format) {
            if (is_printing_command(r.cmd))
                info->prints = true;
            if (r.cmd[0] == 'D' && r.cmd[1] == 'F')
                stores = true;
            if (r.cmd[0] == 'P' && r.cmd[1] == 'Q' && !info->has_quantity) {
                long value = 0;
                size_t end = read_number(data, len, r.next, &value);
                info->has_quantity = true;
                quantity = (end > r.next && value > 0) ? value : 1;
            }
        }
        i = r.next > len ? len : r.next;
    }
    if (stores)
        info->prints = false;
    info->quantity = info->prints ? quantity : 0;
}

bool lwb_format_with_quantity(const uint8_t *data, size_t len, lwb_prefixes prefixes, long quantity,
                              lw_buf *out)
{
    if (quantity < 1)
        quantity = 1;
    lw_buf_reset(out);
    size_t i = 0;
    size_t pq_start = 0, pq_end = 0, xz = 0;
    bool have_pq = false, have_xz = false;
    uint8_t format_prefix = prefixes.format;
    while (i < len) {
        lwb_prefixes before = prefixes;
        scan_result r = scan_command(data, len, i, true, &prefixes);
        if (r.step == SCAN_COMMAND && r.format) {
            if (r.cmd[0] == 'P' && r.cmd[1] == 'Q' && !have_pq) {
                long value = 0;
                have_pq = true;
                pq_start = r.next;
                pq_end = read_number(data, len, r.next, &value);
            } else if (r.cmd[0] == 'X' && r.cmd[1] == 'Z') {
                have_xz = true;
                xz = i;
                format_prefix = before.format;
                break;
            }
        }
        i = r.next > len ? len : r.next;
    }
    if (!have_xz)
        return false;
    if (have_pq) {
        lw_buf_append(out, data, pq_start);
        lw_buf_printf(out, "%ld", quantity);
        lw_buf_append(out, data + pq_end, len - pq_end);
    } else {
        lw_buf_append(out, data, xz);
        lw_buf_printf(out, "%cPQ%ld\n", format_prefix, quantity);
        lw_buf_append(out, data + xz, len - xz);
    }
    return !out->failed;
}

/* ------------------------------------------------------------------------------------------ */
/* ~HS                                                                                        */
/* ------------------------------------------------------------------------------------------ */

#define MAX_FIELDS 16

typedef struct frame {
    size_t start;   /* Position von STX */
    size_t end;     /* Position nach ETX */
    int count;
    long values[MAX_FIELDS];
    bool numeric[MAX_FIELDS];
    size_t field_len[MAX_FIELDS];
} frame;

/* Zerlegt den Inhalt zwischen STX und ETX in kommagetrennte Felder. */
static void split_frame(const uint8_t *data, frame *f)
{
    f->count = 0;
    size_t i = f->start + 1;
    size_t stop = f->end - 1;   /* ETX */
    while (f->count < MAX_FIELDS) {
        size_t j = i;
        while (j < stop && data[j] != ',')
            j++;
        /* Feld data[i, j) ohne Leerraum am Rand */
        size_t a = i, b = j;
        while (a < b && (data[a] == ' ' || data[a] == '\t'))
            a++;
        while (b > a && (data[b - 1] == ' ' || data[b - 1] == '\t'))
            b--;
        long value = 0;
        bool numeric = b > a;
        for (size_t k = a; k < b; k++) {
            if (data[k] < '0' || data[k] > '9') {
                numeric = false;
                break;
            }
            if (value < 1000000000L)
                value = value * 10 + (data[k] - '0');
        }
        f->values[f->count] = value;
        f->numeric[f->count] = numeric;
        f->field_len[f->count] = b - a;
        f->count++;
        if (j >= stop)
            break;
        i = j + 1;
    }
}

static bool frame_is_line1(const frame *f)
{
    if (f->count < 12)
        return false;
    for (int k = 0; k < 8; k++) {
        if (!f->numeric[k])
            return false;
    }
    return f->numeric[9] && f->numeric[10] && f->numeric[11];
}

static bool frame_is_line2(const frame *f)
{
    if (f->count < 9)
        return false;
    for (int k = 0; k < 9; k++) {
        if (k == 5)
            continue;   /* Druckmodus: Ziffer oder Buchstabe */
        if (!f->numeric[k])
            return false;
    }
    return true;
}

static bool frame_is_line3(const uint8_t *data, const frame *f)
{
    if (f->count < 1 || f->count > 3 || f->field_len[0] == 0 || f->field_len[0] > 8)
        return false;
    for (size_t k = f->start + 1; k < f->start + 1 + f->field_len[0]; k++) {
        int c = data[k];
        bool alnum = (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');
        if (!alnum)
            return false;
    }
    return true;
}

/* Nächster vollständiger Rahmen ab `from`; false, wenn keiner vollständig ist (`*pending` = Anfang
 * eines unvollständigen Rahmens oder len). */
static bool next_frame(const uint8_t *data, size_t len, size_t from, frame *f, size_t *pending)
{
    size_t i = from;
    while (i < len && data[i] != STX)
        i++;
    if (i >= len) {
        *pending = len;
        return false;
    }
    size_t j = i + 1;
    while (j < len && data[j] != ETX) {
        if (data[j] == STX)
            i = j;   /* neuer Anfang (abgebrochener Rahmen davor) */
        j++;
    }
    if (j >= len) {
        *pending = i;
        return false;
    }
    f->start = i;
    f->end = j + 1;
    return true;
}

static size_t skip_line_end(const uint8_t *data, size_t len, size_t i)
{
    if (i < len && data[i] == '\r')
        i++;
    if (i < len && data[i] == '\n')
        i++;
    return i;
}

bool lwb_parse_host_status(const uint8_t *data, size_t len, lwb_host_status *status, size_t *consumed)
{
    size_t pos = 0;
    size_t discard = 0;
    frame f1, f2, f3;
    for (;;) {
        size_t pending = len;
        if (!next_frame(data, len, pos, &f1, &pending)) {
            *consumed = pending;
            return false;
        }
        split_frame(data, &f1);
        if (!frame_is_line1(&f1)) {
            pos = f1.end;
            discard = pos;
            continue;
        }
        discard = f1.start;
        if (!next_frame(data, len, f1.end, &f2, &pending)) {
            *consumed = discard;
            return false;
        }
        split_frame(data, &f2);
        if (!frame_is_line2(&f2)) {
            /* Zeile 1 ohne passende Zeile 2: verwerfen und beim zweiten Rahmen weitersuchen. */
            pos = f1.end;
            discard = pos;
            continue;
        }
        break;
    }

    memset(status, 0, sizeof(*status));
    status->paper_out = f1.values[1] != 0;
    status->paused = f1.values[2] != 0;
    status->formats_in_buffer = (int)f1.values[4];
    status->buffer_full = f1.values[5] != 0;
    status->partial_format = f1.values[7] != 0;
    status->corrupt_ram = f1.values[9] != 0;
    status->under_temperature = f1.values[10] != 0;
    status->over_temperature = f1.values[11] != 0;
    status->head_open = f2.values[2] != 0;
    status->ribbon_out = f2.values[3] != 0;
    status->thermal_transfer = f2.values[4] != 0;
    status->label_waiting = f2.values[7] != 0;
    status->labels_remaining = f2.values[8];

    size_t end = skip_line_end(data, len, f2.end);
    size_t pending = len;
    if (next_frame(data, len, end, &f3, &pending)) {
        bool adjacent = true;
        for (size_t k = end; k < f3.start; k++) {
            if (data[k] != '\r' && data[k] != '\n')
                adjacent = false;
        }
        split_frame(data, &f3);
        if (adjacent && frame_is_line3(data, &f3))
            end = skip_line_end(data, len, f3.end);
    }
    *consumed = end;
    return true;
}

/* ------------------------------------------------------------------------------------------ */
/* ^HW-Antwort                                                                                */
/* ------------------------------------------------------------------------------------------ */

static bool contains_ci(const uint8_t *data, size_t len, const char *needle)
{
    size_t n = strlen(needle);
    for (size_t i = 0; n > 0 && i + n <= len; i++) {
        size_t k = 0;
        while (k < n && upper(data[i + k]) == upper((unsigned char)needle[k]))
            k++;
        if (k == n)
            return true;
    }
    return false;
}

/* Eintragszeile „*R:NAME.EXT  größe“ (Leerzeichen vor/nach „*“ erlaubt) mit genau `name`? */
static bool line_lists(const uint8_t *line, size_t len, const char *name)
{
    size_t i = 0;
    while (i < len && (line[i] == ' ' || line[i] == '\t'))
        i++;
    if (i >= len || line[i] != '*')
        return false;
    i++;
    while (i < len && (line[i] == ' ' || line[i] == '\t'))
        i++;
    size_t start = i;
    while (i < len && line[i] != ' ' && line[i] != '\t')
        i++;
    size_t n = strlen(name);
    if (i - start != n)
        return false;
    for (size_t k = 0; k < n; k++) {
        if (upper(line[start + k]) != upper((unsigned char)name[k]))
            return false;
    }
    return true;
}

int lwb_parse_directory(const uint8_t *data, size_t len, const char *name, size_t *consumed)
{
    size_t pos = 0;
    for (;;) {
        const uint8_t *stx = pos < len ? memchr(data + pos, STX, len - pos) : NULL;
        if (stx == NULL) {
            *consumed = len;
            return -1;
        }
        size_t start = (size_t)(stx - data);
        const uint8_t *etx = memchr(data + start + 1, ETX, len - start - 1);
        if (etx == NULL) {
            *consumed = start;
            return -1;
        }
        size_t end = (size_t)(etx - data);
        const uint8_t *body = data + start + 1;
        size_t body_len = end - start - 1;
        if (!contains_ci(body, body_len, "bytes free") && !contains_ci(body, body_len, "DIR")) {
            pos = end + 1;   /* fremder Rahmen (z. B. ~HS) */
            continue;
        }
        bool found = false;
        size_t line = 0;
        for (size_t i = 0; i <= body_len && !found; i++) {
            if (i == body_len || body[i] == '\r' || body[i] == '\n') {
                found = line_lists(body + line, i - line, name);
                line = i + 1;
            }
        }
        *consumed = skip_line_end(data, len, end + 1);
        return found ? 1 : 0;
    }
}

unsigned lwb_status_reasons(const lwb_host_status *status)
{
    unsigned reasons = 0;
    if (status->paper_out)
        reasons |= LWB_REASON_MEDIA_EMPTY;
    /* Thermo-Direkt braucht kein Farbband: manche Modelle melden dann „Farbband leer“ ohne Folgen. */
    if (status->ribbon_out && status->thermal_transfer)
        reasons |= LWB_REASON_RIBBON_EMPTY;
    if (status->head_open)
        reasons |= LWB_REASON_COVER_OPEN;
    if (status->paused)
        reasons |= LWB_REASON_PAUSED;
    return reasons;
}

bool lwb_status_idle(const lwb_host_status *status)
{
    return lwb_status_reasons(status) == 0 && status->formats_in_buffer == 0 && status->labels_remaining == 0;
}

/* ------------------------------------------------------------------------------------------ */
/* URI                                                                                        */
/* ------------------------------------------------------------------------------------------ */

static bool copy_text(char *dst, size_t size, const char *src, size_t len)
{
    if (size == 0 || len >= size)
        return false;
    memcpy(dst, src, len);
    dst[len] = '\0';
    return true;
}

bool lwb_parse_uri(const char *uri, char *host, size_t host_size, int *port, char *options,
                   size_t options_size)
{
    if (uri == NULL || host == NULL || port == NULL)
        return false;
    const char *rest = strstr(uri, "://");
    if (rest == NULL)
        return false;
    rest += 3;
    const char *query = strchr(rest, '?');
    if (options != NULL) {
        if (query != NULL) {
            const char *qend = strchr(query + 1, '#');
            size_t qlen = qend ? (size_t)(qend - query - 1) : strlen(query + 1);
            if (!copy_text(options, options_size, query + 1, qlen))
                return false;
        } else if (options_size > 0) {
            options[0] = '\0';
        }
    }
    size_t authority_len = strcspn(rest, "/?#");
    const char *authority = rest;
    const char *at = NULL;
    for (size_t k = 0; k < authority_len; k++) {
        if (authority[k] == '@')
            at = authority + k;
    }
    if (at != NULL) {
        authority_len -= (size_t)(at + 1 - authority);
        authority = at + 1;
    }
    const char *host_start = authority;
    size_t host_len = 0;
    const char *port_text = NULL;
    size_t port_len = 0;
    if (authority_len > 0 && authority[0] == '[') {
        const char *close = memchr(authority, ']', authority_len);
        if (close == NULL)
            return false;
        host_start = authority + 1;
        host_len = (size_t)(close - host_start);
        size_t after = (size_t)(close + 1 - authority);
        if (after < authority_len) {
            if (authority[after] != ':')
                return false;
            port_text = authority + after + 1;
            port_len = authority_len - after - 1;
        }
    } else {
        const char *colon = memchr(authority, ':', authority_len);
        if (colon != NULL) {
            host_len = (size_t)(colon - authority);
            port_text = colon + 1;
            port_len = authority_len - host_len - 1;
        } else {
            host_len = authority_len;
        }
    }
    if (host_len == 0)
        return false;
    /* Prozentkodierung im Host (Zone %25) auflösen. */
    char decoded[512];
    size_t d = 0;
    for (size_t k = 0; k < host_len; k++) {
        if (d + 1 >= sizeof(decoded))
            return false;
        char c = host_start[k];
        if (c == '%' && k + 2 < host_len) {
            char hex[3] = { host_start[k + 1], host_start[k + 2], 0 };
            char *end = NULL;
            long v = strtol(hex, &end, 16);
            if (end == hex + 2 && v > 0) {
                decoded[d++] = (char)v;
                k += 2;
                continue;
            }
        }
        decoded[d++] = c;
    }
    decoded[d] = '\0';
    if (!copy_text(host, host_size, decoded, d))
        return false;
    *port = LWB_DEFAULT_PORT;
    if (port_text != NULL) {
        if (port_len == 0 || port_len > 5)
            return false;
        long v = 0;
        for (size_t k = 0; k < port_len; k++) {
            if (port_text[k] < '0' || port_text[k] > '9')
                return false;
            v = v * 10 + (port_text[k] - '0');
        }
        if (v < 1 || v > 65535)
            return false;
        *port = (int)v;
    }
    return true;
}

bool lwb_uri_option(const char *options, const char *name, char *value, size_t value_size)
{
    if (options == NULL || name == NULL)
        return false;
    size_t name_len = strlen(name);
    const char *p = options;
    while (*p != '\0') {
        size_t item_len = strcspn(p, "&+");
        if (item_len > name_len && lw_str_nieq(p, name, name_len) && p[name_len] == '=') {
            return copy_text(value, value_size, p + name_len + 1, item_len - name_len - 1);
        }
        if (item_len == name_len && lw_str_nieq(p, name, name_len))
            return copy_text(value, value_size, "", 0);
        p += item_len;
        if (*p != '\0')
            p++;
    }
    return false;
}
