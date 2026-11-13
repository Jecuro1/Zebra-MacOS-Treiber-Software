/*
 * labelwerk.c – CUPS-Backend „labelwerk“ für Zebra-Netzwerkdrucker (ARCHITECTURE.md §10
 * „Backend labelwerk“).
 *
 * Geräte-URI: labelwerk://host[:port][?mode=stream] (Port ohne Angabe 9100, IPv6 in [ ]).
 *
 * Anders als das CUPS-Backend `socket`, für das ein Auftrag erledigt ist, sobald die Daten beim
 * Drucker sind, schickt dieses Backend einen ZPL-Auftrag Etikett für Etikett:
 *
 *   1. Verbinden (TCP), ~HS abfragen (antwortet der Drucker nicht: wie `socket` am Stück senden).
 *   2. Auftragskopf (alles vor dem ersten ^XA) senden. Beginnt er mit ~JA („Aufträge vor dem
 *      Drucken abbrechen“), folgt nach der ~JA-Zeile die Pause lwCancelDelay wie im Filter – ~JA
 *      löscht die Daten vor sich im Empfangspuffer.
 *   3. Vor dem ersten druckenden Format, sobald der Drucker bereit ist: ^XA^JZY^XZ (der Drucker
 *      druckt das Etikett, bei dem ein Fehler auftrat, danach erneut) und der Neustart-Merker
 *      R:LWJOB.GRF (~DG, 1 Byte im RAM, verschwindet beim Aus- und Einschalten); ^HW prüft einmal,
 *      ob der Drucker ihn meldet.
 *   4. Je Format ^XA…^XZ: vorher per ~HS warten, bis der Drucker nichts mehr im Puffer hat (keine
 *      Formate, keine Restetiketten, kein Fehler). So liegt nie mehr als ein Format im Drucker; der
 *      Auftrag bleibt in der macOS-Warteschlange, bis das letzte Etikett gedruckt ist. Das erste
 *      Etikett geht los, sobald es vom Filter vollständig da ist; während des Wartens liest das
 *      Backend weiter (Gesamtzahl „Etikett 3 von 50“, sobald das Auftragsende gelesen ist).
 *   5. Papier leer, Farbband leer (nur Thermotransfer), Druckkopf offen, Pause: CUPS erfährt es
 *      über „STATE: +media-empty-error“ usw. und eine deutsche INFO-Meldung; das Backend fragt alle
 *      2 s nach und setzt fort, sobald der Fehler behoben ist (der Drucker wiederholt das
 *      unterbrochene Etikett wegen ^JZY selbst). Bleibt der Drucker nach einem solchen Fehler
 *      angehalten (viele Modelle nach dem Einlegen), setzt ~PS ihn fort; eine Pause ohne
 *      vorherigen Fehler bleibt dem Benutzer überlassen.
 *   6. Verbindungsabbruch: neu verbinden (1 s, 2 s, 4 s … höchstens 30 s, unbegrenzt oft). Ob der
 *      Drucker dabei neu gestartet wurde, entscheidet sein Zustand, nicht eine Vermutung: Daten im
 *      Puffer → behalten; Antwort nur mit den gespeicherten Steuerzeichen → neu gestartet; sonst
 *      (sobald er bereit ist) der Neustart-Merker per ^HW. Behalten: nichts erneut senden – was er
 *      inzwischen gedruckt hat, zählt. Neu gestartet: Auftragskopf, ^JZY, Merker und das offene
 *      Format mit den zuletzt gemeldeten Restetiketten erneut (auch ohne vorherigen Fehler).
 *      Meldet der Drucker den Merker nicht: nichts automatisch wiederholen, WARNING mit der Zahl
 *      der möglicherweise fehlenden Etiketten. Beim Senden abgebrochen: ein Teilformat verwirft
 *      ~JX, dann geht das Format erneut hinaus; liegt es vollständig im Drucker, nicht.
 *   7. Downloads (~DG, ~DY …) und Binärdaten: ab dort am Stück, ohne ~HS dazwischen.
 *   8. Abbrechen (SIGTERM): ~JA leert den Druckerpuffer, dann Ende.
 *
 * Am Stück gesendet (EPL/CPCL, lwResumeOnError=False, ?mode=stream, Drucker ohne ~HS, Rest nach
 * einem Download) gilt wie bei `socket`: Bricht die Verbindung ab, nachdem Auftragsdaten gesendet
 * wurden, endet der Auftrag mit einem Fehler statt alles erneut (doppelt) zu senden.
 *
 * Rechte: root:wheel 0755 – CUPS startet Backends, die für „andere“ ausführbar sind, als
 * unprivilegierter Benutzer (lp/_lp); 0700 hieße Ausführung als root, die dieses Backend nicht
 * braucht (nur TCP zum Drucker).
 *
 * Umgebung nur für Tests: LW_BACKEND_POLL_MS, LW_BACKEND_ERROR_POLL_MS, LW_BACKEND_REPLY_TIMEOUT_MS,
 * LW_BACKEND_STALL_MS, LW_BACKEND_RECONNECT_MS, LW_BACKEND_RECONNECT_MAX_MS,
 * LW_BACKEND_RECONNECT_LIMIT, LW_BACKEND_CONNECT_TIMEOUT_MS, LW_BACKEND_CANCEL_DELAY_MS (Pause nach
 * ~JX bzw. dem ~JA beim Abbruch), LW_BACKEND_SNDBUF (Sendepuffer des Sockets in Byte).
 *
 * Copyright (c) LabelWerk-Projekt. Zebra ist eine Marke der Zebra Technologies Corp.
 */

#if !defined(__APPLE__) && !defined(_DEFAULT_SOURCE)
#  define _DEFAULT_SOURCE 1
#endif

#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#include "lw_cups.h"
#include "lw_options.h"
#include "lw_util.h"
#include "lwb_core.h"

/* CUPS-Exitcodes (cups/backend.h), hier fest, damit der Kern ohne Backend-Header auskommt. */
enum {
    BACKEND_OK = 0,
    BACKEND_FAILED = 1,
    BACKEND_RETRY = 6
};

/* Höchstmenge der Eingabe, die im Speicher vorausgelesen wird (Gesamtzahl der Etiketten). */
#define READ_AHEAD_LIMIT (64u * 1024u * 1024u)
/* Auftragskopf, der nach einem Neustart des Druckers erneut gesendet wird (höchstens). */
#define PROLOGUE_LIMIT (256u * 1024u)

static volatile sig_atomic_t g_cancel = 0;

static void on_sigterm(int sig)
{
    (void)sig;
    g_cancel = 1;
}

/* ------------------------------------------------------------------------------------------ */
/* Meldungen an CUPS                                                                          */
/* ------------------------------------------------------------------------------------------ */

static void message(const char *prefix, const char *fmt, ...) LW_PRINTF(2, 3);

static void message(const char *prefix, const char *fmt, ...)
{
    char text[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(text, sizeof(text), fmt, ap);
    va_end(ap);
    for (char *p = text; *p != '\0'; p++) {
        if (*p == '\n' || *p == '\r')
            *p = ' ';
    }
    fprintf(stderr, "%s: %s\n", prefix, text);
    fflush(stderr);
}

/* ------------------------------------------------------------------------------------------ */
/* Zeit                                                                                       */
/* ------------------------------------------------------------------------------------------ */

static long long now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* Wartet `ms` Millisekunden; endet früher bei einem Abbruch. */
static void sleep_ms(long ms)
{
    long long until = now_ms() + ms;
    while (!g_cancel) {
        long long left = until - now_ms();
        if (left <= 0)
            break;
        struct timespec ts = { (time_t)(left / 1000), (long)(left % 1000) * 1000000L };
        nanosleep(&ts, NULL);
    }
}

static long env_ms(const char *name, long fallback, long minimum)
{
    const char *text = getenv(name);
    if (text == NULL || text[0] == '\0')
        return fallback;
    char *end = NULL;
    long v = strtol(text, &end, 10);
    if (end == text || *end != '\0' || v < minimum)
        return fallback;
    return v;
}

/* ------------------------------------------------------------------------------------------ */
/* Eingabe                                                                                    */
/* ------------------------------------------------------------------------------------------ */

typedef struct input {
    int fd;
    lw_buf data;
    size_t pos;
    bool eof;
    bool failed;      /* Lesefehler beim Vorauslesen (pump_input) */
} input;

/* Eingabe des Auftrags; pump_input liest während des Wartens auf den Drucker weiter. */
static input *g_input = NULL;

/* Liest weitere Daten (blockierend). 0 = gelesen bzw. Ende, -1 = Fehler, -2 = Abbruch. */
static int read_more(input *in)
{
    if (in->pos > 0 && in->pos >= in->data.len / 2) {
        memmove(in->data.data, in->data.data + in->pos, in->data.len - in->pos);
        in->data.len -= in->pos;
        in->pos = 0;
    }
    uint8_t chunk[65536];
    for (;;) {
        if (g_cancel)
            return -2;
        ssize_t got = read(in->fd, chunk, sizeof(chunk));
        if (got < 0) {
            if (errno == EINTR)
                continue;
            return -1;
        }
        if (got == 0) {
            in->eof = true;
            return 0;
        }
        lw_buf_append(&in->data, chunk, (size_t)got);
        return in->data.failed ? -1 : 0;
    }
}

/*
 * Liest, was der Filter schon geliefert hat, ohne zu warten (höchstens READ_AHEAD_LIMIT im
 * Speicher). So kennt das Backend früh das Auftragsende (Gesamtzahl der Etiketten), und der Filter
 * rendert weiter, während der Drucker druckt. Darf Daten im Puffer verschieben: Aufrufer halten
 * keine Zeiger in den Eingabepuffer über diesen Aufruf hinweg.
 */
static void pump_input(void)
{
    input *in = g_input;
    if (in == NULL)
        return;
    while (!in->eof && !in->failed && !g_cancel && in->data.len - in->pos < READ_AHEAD_LIMIT) {
        struct pollfd pfd = { in->fd, POLLIN, 0 };
        if (poll(&pfd, 1, 0) <= 0 || (pfd.revents & (POLLIN | POLLHUP | POLLERR)) == 0)
            return;
        if (read_more(in) == -1)
            in->failed = true;
    }
}

/* ------------------------------------------------------------------------------------------ */
/* Auftrag                                                                                    */
/* ------------------------------------------------------------------------------------------ */

typedef struct timing {
    long poll;            /* Abfrage während des Drucks */
    long error_poll;      /* Abfrage im Fehlerzustand (2 s) */
    long reply_timeout;   /* Wartezeit auf eine ~HS- bzw. ^HW-Antwort */
    long stall;           /* so lange ohne Antwort → Verbindung gilt als verloren */
    long reconnect;       /* erste Wartezeit vor einem neuen Verbindungsversuch */
    long reconnect_max;
    long reconnect_limit; /* 0 = unbegrenzt */
    long connect_timeout;
    long cancel_delay;    /* Wartezeit nach ~JX vor dem erneuten Senden */
    long ja_delay;        /* Wartezeit nach ~JA am Auftragsanfang (lwCancelDelay) */
} timing;

/*
 * Neustart-Merker: eine 1-Byte-Grafik im RAM-Laufwerk R:, das der Drucker beim Ausschalten bzw.
 * Neustart verliert. Fehlt sie nach einem Verbindungsabbruch, hat der Drucker seinen Puffer verloren.
 */
#define MARKER_NAME "R:LWJOB.GRF"

typedef struct job {
    char host[512];
    int port;
    int fd;
    bool paced;
    timing t;
    lw_buf rx;

    lwb_prefixes start_prefixes;   /* Steuerzeichen am Auftragsanfang */
    /* Steuerzeichen, die der Drucker gerade hat (für ~HS, ~JA): immer die am Ende der zuletzt
     * vollständig gesendeten Daten. */
    lwb_prefixes prefixes;

    lw_buf prologue;               /* Rohdaten vor dem ersten Format (für einen Neustart) */
    lwb_prefixes prologue_prefixes;/* Steuerzeichen am Ende des Auftragskopfs */
    bool prologue_closed;

    /* ^JZY und Neustart-Merker gesendet (vor dem ersten druckenden Format). */
    bool session_armed;
    bool marker_checked;
    bool marker_ok;                /* der Drucker meldet den Merker per ^HW */

    /* Nächstes Format (Kopie aus der Eingabe, solange auf den Drucker gewartet wird). */
    lw_buf next;

    /* Offenes Format: gesendet, aber noch nicht vollständig gedruckt. */
    lw_buf outstanding;
    lwb_prefixes outstanding_prefixes;   /* am Formatanfang */
    lwb_prefixes outstanding_after;      /* am Formatende */
    bool outstanding_active;
    bool outstanding_written;
    long outstanding_quantity;
    long outstanding_remaining;   /* zuletzt gemeldete Restetiketten (> 0) */
    bool outstanding_seen;        /* Drucker hat das Format schon gemeldet (Puffer/Rest) */

    long labels_done;
    long labels_total;            /* 0 = unbekannt */
    long labels_uncertain;        /* nach Verbindungsabbruch nicht prüfbar */
    long reported_label;
    unsigned reported_reasons;
    bool reported_connecting;
    bool anything_sent;
    bool data_sent;               /* Auftragsdaten (nicht nur Abfragen) gesendet */
    bool fault_seen;      /* Papier/Farbband/Kopf seit dem letzten fehlerfreien Stand */
    bool resume_sent;     /* ~PS nach diesem Fehler schon gesendet */
} job;

/* ------------------------------------------------------------------------------------------ */
/* Statusmeldungen                                                                            */
/* ------------------------------------------------------------------------------------------ */

static const struct {
    unsigned reason;
    const char *keyword;
    const char *text;
} REASONS[] = {
    { LWB_REASON_MEDIA_EMPTY, "media-empty-error",
      "Kein Papier – neue Etikettenrolle einlegen. Der Druck geht danach automatisch weiter." },
    { LWB_REASON_RIBBON_EMPTY, "marker-supply-empty-error",
      "Farbband leer – neues Farbband einlegen. Der Druck geht danach automatisch weiter." },
    { LWB_REASON_COVER_OPEN, "cover-open-error",
      "Druckkopf offen – Druckkopf schließen. Der Druck geht danach automatisch weiter." },
    /* Nicht „paused“: cupsd hielte damit die ganze Warteschlange an (cupsdSetPrinterReasons). */
    { LWB_REASON_PAUSED, "other-warning",
      "Drucker angehalten (Pause) – Pause-Taste am Drucker drücken. Der Druck geht danach automatisch weiter." },
};
#define REASON_COUNT (sizeof(REASONS) / sizeof(REASONS[0]))

static void report_progress(job *j, bool force)
{
    long current = j->labels_done + 1;
    if (j->outstanding_active && j->outstanding_seen) {
        long printed = j->outstanding_quantity - j->outstanding_remaining;
        if (printed > 0)
            current = j->labels_done + printed + 1;
    }
    if (j->labels_total > 0 && current > j->labels_total)
        current = j->labels_total;
    if (!force && current == j->reported_label)
        return;
    j->reported_label = current;
    if (j->reported_reasons != 0)
        return;   /* Fehlermeldung bleibt stehen */
    if (j->labels_total > 0)
        message("INFO", "Etikett %ld von %ld", current, j->labels_total);
    else
        message("INFO", "Etikett %ld", current);
}

static void report_reasons(job *j, unsigned reasons)
{
    if (reasons == j->reported_reasons)
        return;
    for (size_t k = 0; k < REASON_COUNT; k++) {
        bool now = (reasons & REASONS[k].reason) != 0;
        bool before = (j->reported_reasons & REASONS[k].reason) != 0;
        if (now && !before)
            message("STATE", "+%s", REASONS[k].keyword);
        else if (!now && before)
            message("STATE", "-%s", REASONS[k].keyword);
    }
    j->reported_reasons = reasons;
    for (size_t k = 0; k < REASON_COUNT; k++) {
        if (reasons & REASONS[k].reason) {
            message("INFO", "%s", REASONS[k].text);
            return;
        }
    }
    message("DEBUG", "Fehler am Drucker behoben – Druck wird fortgesetzt.");
    report_progress(j, true);
}

static void report_connecting(job *j, bool connecting)
{
    if (connecting == j->reported_connecting)
        return;
    j->reported_connecting = connecting;
    message("STATE", "%s", connecting ? "+connecting-to-device" : "-connecting-to-device");
}

static void clear_states(job *j)
{
    report_connecting(j, false);
    if (j->reported_reasons != 0) {
        for (size_t k = 0; k < REASON_COUNT; k++) {
            if (j->reported_reasons & REASONS[k].reason)
                message("STATE", "-%s", REASONS[k].keyword);
        }
        j->reported_reasons = 0;
    }
}

/* ------------------------------------------------------------------------------------------ */
/* Netzwerk                                                                                   */
/* ------------------------------------------------------------------------------------------ */

static void close_connection(job *j)
{
    if (j->fd >= 0)
        close(j->fd);
    j->fd = -1;
    lw_buf_reset(&j->rx);
}

/* Verbindet mit dem Drucker (alle Adressen des Hosts). 0 = verbunden, -1 = Fehler, -2 = Abbruch. */
static int open_connection(job *j)
{
    char service[16];
    snprintf(service, sizeof(service), "%d", j->port);
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    struct addrinfo *list = NULL;
    int gai = getaddrinfo(j->host, service, &hints, &list);
    if (gai != 0) {
        message("DEBUG", "Adresse von %s nicht auflösbar: %s", j->host, gai_strerror(gai));
        return -1;
    }
    int result = -1;
    for (struct addrinfo *ai = list; ai != NULL && result == -1; ai = ai->ai_next) {
        int fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0)
            continue;
        int flags = fcntl(fd, F_GETFL, 0);
        fcntl(fd, F_SETFL, flags | O_NONBLOCK);
        int rc = connect(fd, ai->ai_addr, ai->ai_addrlen);
        if (rc != 0 && errno == EINPROGRESS) {
            long long deadline = now_ms() + j->t.connect_timeout;
            for (;;) {
                if (g_cancel) {
                    close(fd);
                    freeaddrinfo(list);
                    return -2;
                }
                long long left = deadline - now_ms();
                if (left <= 0)
                    break;
                struct pollfd pfd = { fd, POLLOUT, 0 };
                int n = poll(&pfd, 1, (int)(left > 250 ? 250 : left));
                if (n > 0) {
                    int error = 0;
                    socklen_t size = sizeof(error);
                    getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size);
                    rc = error == 0 ? 0 : -1;
                    break;
                }
            }
        }
        if (rc == 0) {
            int one = 1;
            setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, sizeof(one));
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
            int sndbuf = (int)env_ms("LW_BACKEND_SNDBUF", 0, 0);
            if (sndbuf > 0)
                setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf));
#ifdef SO_NOSIGPIPE
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
#endif
            j->fd = fd;
            result = 0;
        } else {
            close(fd);
        }
    }
    freeaddrinfo(list);
    return result;
}

/*
 * Sendet alles. 0 = gesendet, -1 = Verbindungsfehler, -2 = Abbruch. `allow_cancel` = false für ~JA.
 * `written` (optional) erhält die Zahl der Bytes, die tatsächlich an das System übergeben wurden.
 */
static int send_all(job *j, const void *data, size_t len, bool allow_cancel, size_t *written)
{
    const uint8_t *p = data;
    size_t total = 0;
    long long last_progress = now_ms();
    long stall = j->t.stall > 300000 ? j->t.stall : 300000;
    int rc = 0;
    while (len > 0) {
        if (allow_cancel && g_cancel) {
            rc = -2;
            break;
        }
        if (j->fd < 0) {
            rc = -1;
            break;
        }
        struct pollfd pfd = { j->fd, POLLOUT, 0 };
        int n = poll(&pfd, 1, 250);
        if (n < 0 && errno != EINTR) {
            rc = -1;
            break;
        }
        if (n <= 0) {
            if (now_ms() - last_progress > stall) {
                rc = -1;
                break;
            }
            continue;
        }
        if (pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) {
            rc = -1;
            break;
        }
        ssize_t sent = send(j->fd, p, len, 0);
        if (sent < 0) {
            if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)
                continue;
            rc = -1;
            break;
        }
        p += sent;
        len -= (size_t)sent;
        total += (size_t)sent;
        last_progress = now_ms();
        j->anything_sent = true;
    }
    if (written != NULL)
        *written = total;
    return rc;
}

static int send_text(job *j, const char *text, bool allow_cancel)
{
    return send_all(j, text, strlen(text), allow_cancel, NULL);
}

/* Auftragsdaten senden (zählt für „Auftragsdaten gesendet“). */
static int send_data(job *j, const uint8_t *data, size_t len, size_t *written)
{
    size_t local = 0;
    int rc = send_all(j, data, len, true, &local);
    if (local > 0)
        j->data_sent = true;
    if (written != NULL)
        *written = local;
    return rc;
}

/* Liest verfügbare Daten in j->rx. 1 = Daten, 0 = keine (Zeitablauf), -1 = Verbindung beendet. */
static int receive(job *j, long timeout)
{
    struct pollfd pfd = { j->fd, POLLIN, 0 };
    int n = poll(&pfd, 1, (int)timeout);
    if (n < 0)
        return errno == EINTR ? 0 : -1;
    if (n == 0)
        return 0;
    uint8_t chunk[4096];
    ssize_t got = recv(j->fd, chunk, sizeof(chunk), 0);
    if (got < 0)
        return (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) ? 0 : -1;
    if (got == 0)
        return -1;
    lw_buf_append(&j->rx, chunk, (size_t)got);
    return 1;
}

static void consume_rx(job *j, size_t count)
{
    if (count >= j->rx.len) {
        lw_buf_reset(&j->rx);
        return;
    }
    memmove(j->rx.data, j->rx.data + count, j->rx.len - count);
    j->rx.len -= count;
}

/* Ältere, noch nicht gelesene Antworten verwerfen. */
static void drain_rx(job *j)
{
    while (receive(j, 0) > 0) {
    }
    lw_buf_reset(&j->rx);
}

/* ~HS abfragen. 1 = Antwort, 0 = keine Antwort, -1 = Verbindungsfehler, -2 = Abbruch. */
static int query_status(job *j, lwb_host_status *status)
{
    drain_rx(j);
    char query[4] = { (char)j->prefixes.control, 'H', 'S', '\0' };
    int rc = send_text(j, query, true);
    if (rc != 0)
        return rc;
    long long deadline = now_ms() + j->t.reply_timeout;
    for (;;) {
        size_t consumed = 0;
        if (lwb_parse_host_status(j->rx.data, j->rx.len, status, &consumed)) {
            consume_rx(j, consumed);
            return 1;
        }
        consume_rx(j, consumed);
        if (g_cancel)
            return -2;
        long long left = deadline - now_ms();
        if (left <= 0)
            return 0;
        int got = receive(j, left > 250 ? 250 : left);
        if (got < 0)
            return -1;
    }
}

/*
 * ~HS mit anderen Steuerzeichen, wenn der Drucker auf die aktuellen nicht antwortet: Nach einem
 * Neustart hat er wieder seine gespeicherten (die des Auftragsanfangs bzw. ~ ^ ,), auch wenn der
 * Auftrag sie per ~CC/^CC/~CT gewechselt hatte. Antwortet er so, steht `*reset` auf true und
 * j->prefixes auf den Zeichen, mit denen er geantwortet hat. Rückgabe wie query_status.
 */
static int query_status_any_prefix(job *j, lwb_host_status *status, bool *reset)
{
    int q = query_status(j, status);
    if (q != 0)
        return q;
    lwb_prefixes current = j->prefixes;
    lwb_prefixes candidates[2] = { j->start_prefixes, lwb_prefixes_standard() };
    for (int k = 0; k < 2; k++) {
        if (candidates[k].control == current.control || (k == 1 && candidates[1].control == candidates[0].control))
            continue;
        j->prefixes = candidates[k];
        q = query_status(j, status);
        if (q == 1) {
            *reset = true;
            message("DEBUG", "Drucker antwortet mit Steuerzeichen „%c“ statt „%c“ – er wurde neu gestartet.",
                    (char)candidates[k].control, (char)current.control);
            return 1;
        }
        if (q != 0) {
            j->prefixes = current;
            return q;
        }
    }
    j->prefixes = current;
    return 0;
}

/* ------------------------------------------------------------------------------------------ */
/* Druckerbefehle des Backends                                                                */
/* ------------------------------------------------------------------------------------------ */

/* ^XA^JZY^XZ mit den aktuellen Steuerzeichen. */
static int send_reprint_setting(job *j)
{
    char text[16];
    snprintf(text, sizeof(text), "%cXA%cJZY%cXZ\n", j->prefixes.format, j->prefixes.format, j->prefixes.format);
    return send_text(j, text, true);
}

/* Neustart-Merker speichern: ~DGR:LWJOB.GRF,1,1,00 (1 Byte, verschwindet beim Neustart). */
static int store_marker(job *j)
{
    char text[64];
    char d = (char)j->prefixes.delimiter;
    snprintf(text, sizeof(text), "%cDG%s%c1%c1%c00\n", (char)j->prefixes.control, MARKER_NAME, d, d, d);
    return send_text(j, text, true);
}

/* Merker am Auftragsende löschen (ohne Fehlerbehandlung). */
static void delete_marker(job *j)
{
    char text[64];
    char f = (char)j->prefixes.format;
    snprintf(text, sizeof(text), "%cXA%cID%s%cXZ\n", f, f, MARKER_NAME, f);
    (void)send_text(j, text, true);
}

/*
 * Merker per ^HW abfragen. Der Drucker bearbeitet ^HW als Format – nur fragen, wenn er bereit ist
 * (kein Fehler, keine Pause). 1 = vorhanden, 0 = fehlt, 2 = keine Antwort, -1 = Verbindungsfehler,
 * -2 = Abbruch.
 */
static int check_marker(job *j)
{
    drain_rx(j);
    char query[64];
    char f = (char)j->prefixes.format;
    snprintf(query, sizeof(query), "%cXA%cHW%s%cXZ\n", f, f, MARKER_NAME, f);
    int rc = send_text(j, query, true);
    if (rc != 0)
        return rc;
    long long deadline = now_ms() + j->t.reply_timeout;
    for (;;) {
        size_t consumed = 0;
        int found = lwb_parse_directory(j->rx.data, j->rx.len, MARKER_NAME, &consumed);
        consume_rx(j, consumed);
        if (found >= 0)
            return found;
        if (g_cancel)
            return -2;
        long long left = deadline - now_ms();
        if (left <= 0)
            return 2;
        int got = receive(j, left > 250 ? 250 : left);
        if (got < 0)
            return -1;
    }
}

/* Steuerzeichen des Druckers von j->prefixes auf `to` umstellen (~CC, ~CD, ~CT). */
static int switch_prefixes(job *j, lwb_prefixes to)
{
    lwb_prefixes from = j->prefixes;
    char text[16];
    size_t n = 0;
    if (from.format != to.format)
        n += (size_t)snprintf(text + n, sizeof(text) - n, "%cCC%c", (char)from.control, (char)to.format);
    if (from.delimiter != to.delimiter)
        n += (size_t)snprintf(text + n, sizeof(text) - n, "%cCD%c", (char)from.control, (char)to.delimiter);
    if (from.control != to.control)
        n += (size_t)snprintf(text + n, sizeof(text) - n, "%cCT%c", (char)from.control, (char)to.control);
    if (n == 0)
        return 0;
    int rc = send_text(j, text, true);
    if (rc == 0)
        j->prefixes = to;
    return rc;
}

/*
 * Rohdaten senden; beginnen sie mit ~JA (Filteroption „Aufträge vor dem Drucken abbrechen“),
 * zuerst nur die ~JA-Zeile, dann lwCancelDelay warten (~JA löscht die Daten vor sich im
 * Empfangspuffer; ohne Pause träfe es auch die folgenden Befehle), dann den Rest.
 */
static int send_raw_split(job *j, const uint8_t *data, size_t len)
{
    size_t i = 0;
    while (i < len && (data[i] == ' ' || data[i] == '\t' || data[i] == '\r' || data[i] == '\n'))
        i++;
    if (i + 3 <= len && data[i] == j->prefixes.control && (data[i + 1] == 'J' || data[i + 1] == 'j') &&
        (data[i + 2] == 'A' || data[i + 2] == 'a')) {
        size_t end = i + 3;
        if (end < len && data[end] == '\r')
            end++;
        if (end < len && data[end] == '\n')
            end++;
        int rc = send_data(j, data, end, NULL);
        if (rc != 0)
            return rc;
        message("DEBUG", "~JA gesendet – %ld ms Pause vor den weiteren Befehlen.", j->t.ja_delay);
        sleep_ms(j->t.ja_delay);
        if (g_cancel)
            return -2;
        data += end;
        len -= end;
    }
    return len > 0 ? send_data(j, data, len, NULL) : 0;
}

/* ------------------------------------------------------------------------------------------ */
/* Verbindungsaufbau und Wiederaufnahme                                                       */
/* ------------------------------------------------------------------------------------------ */

/*
 * Verbindet (erneut), bis der Drucker antwortet. Im getakteten Modus muss er auch ~HS
 * beantworten (`status` erhält die Antwort; mit `any_prefix` auch mit anderen Steuerzeichen, siehe
 * query_status_any_prefix). 0 = verbunden, -2 = Abbruch, -3 = Versuche erschöpft.
 */
static int connect_with_retry(job *j, lwb_host_status *status, bool *answered, bool any_prefix, bool *reset)
{
    long delay = j->t.reconnect;
    long attempts = 0;
    *answered = false;
    for (;;) {
        if (g_cancel)
            return -2;
        message("DEBUG", "Verbinde mit %s:%d …", j->host, j->port);
        int rc = open_connection(j);
        if (rc == -2)
            return -2;
        if (rc == 0) {
            if (!j->paced) {
                report_connecting(j, false);
                return 0;
            }
            int q = any_prefix ? query_status_any_prefix(j, status, reset) : query_status(j, status);
            if (q == -2)
                return -2;
            if (q == 1) {
                *answered = true;
                report_connecting(j, false);
                return 0;
            }
            if (q == 0) {
                /* Verbunden, aber keine Antwort: Entscheidung beim Aufrufer. */
                report_connecting(j, false);
                return 0;
            }
            close_connection(j);
        }
        attempts++;
        if (j->t.reconnect_limit > 0 && attempts >= j->t.reconnect_limit)
            return -3;
        report_connecting(j, true);
        long seconds = (delay + 999) / 1000;
        message("INFO", "Drucker %s:%d nicht erreichbar – neuer Versuch in %ld s.", j->host, j->port, seconds);
        sleep_ms(delay);
        delay = delay * 2 > j->t.reconnect_max ? j->t.reconnect_max : delay * 2;
    }
}

/*
 * Statusgründe melden; nach einem behobenen Fehler einen angehaltenen Drucker fortsetzen (~PS).
 * Liefert die Gründe; -2 bei Abbruch (in *reasons unverändert).
 */
static int handle_reasons(job *j, const lwb_host_status *status, unsigned *reasons_out)
{
    unsigned reasons = lwb_status_reasons(status);
    report_reasons(j, reasons);
    if (reasons & (LWB_REASON_MEDIA_EMPTY | LWB_REASON_RIBBON_EMPTY | LWB_REASON_COVER_OPEN)) {
        j->fault_seen = true;
    } else if (reasons == LWB_REASON_PAUSED && j->fault_seen && !j->resume_sent) {
        /* Viele Modelle bleiben nach dem Einlegen angehalten: nach einem Fehler dieses Auftrags
         * selbst fortsetzen (~PS) – eine Pause ohne vorherigen Fehler hat der Benutzer gewollt. */
        char resume[4] = { (char)j->prefixes.control, 'P', 'S', '\0' };
        message("DEBUG", "Fehler behoben, Drucker angehalten – ~PS setzt den Druck fort.");
        if (send_text(j, resume, true) == -2)
            return -2;
        j->resume_sent = true;
    } else if (reasons == 0) {
        j->fault_seen = false;
        j->resume_sent = false;
    }
    if (status->under_temperature || status->over_temperature)
        message("DEBUG", "Druckkopftemperatur außerhalb des Betriebsbereichs.");
    *reasons_out = reasons;
    return 0;
}

/* Sendet das offene Format (mit der Restmenge, falls kleiner). */
static int send_outstanding(job *j)
{
    int rc;
    lw_buf data;
    lw_buf_init(&data);
    if (!lwb_format_with_quantity(j->outstanding.data, j->outstanding.len, j->outstanding_prefixes,
                                  j->outstanding_quantity, &data)) {
        lw_buf_reset(&data);
        lw_buf_append(&data, j->outstanding.data, j->outstanding.len);
    }
    rc = send_data(j, data.data, data.len, NULL);
    lw_buf_free(&data);
    if (rc == 0) {
        j->outstanding_written = true;
        j->prefixes = j->outstanding_after;
    }
    return rc;
}

/* Ergebnis der Neustart-Prüfung nach einem Wiederverbinden. */
enum {
    PRINTER_KEPT = 0,      /* Drucker hat seinen Puffer behalten */
    PRINTER_RESTARTED = 1, /* Drucker wurde neu gestartet: Puffer und Einstellungen weg */
    PRINTER_UNKNOWN = 2    /* nicht prüfbar (Drucker meldet den Merker nicht) */
};

/*
 * Wurde der Drucker während der Unterbrechung neu gestartet? Entscheidet nach dem Druckerzustand,
 * nicht nach Vermutungen: Daten im Puffer bzw. ein Teilformat → behalten; Antwort nur mit den
 * gespeicherten Steuerzeichen → neu gestartet; sonst der Neustart-Merker im RAM (^HW). Weil der
 * Drucker ^HW als Format erst bearbeitet, wenn er bereit ist, wird bei Papier leer usw. zuerst
 * gewartet (mit STATE-Meldungen wie beim Drucken). -1 = Verbindungsfehler, -2 = Abbruch.
 */
static int restart_verdict(job *j, lwb_host_status *status, bool prefixes_reset, bool had_partial)
{
    if (prefixes_reset)
        return PRINTER_RESTARTED;
    if (had_partial)
        return PRINTER_KEPT;
    long long last_answer = now_ms();
    for (;;) {
        if (status->formats_in_buffer > 0 || status->labels_remaining > 0)
            return PRINTER_KEPT;
        if (!j->marker_ok)
            return PRINTER_UNKNOWN;
        unsigned reasons = 0;
        if (handle_reasons(j, status, &reasons) == -2)
            return -2;
        if (reasons == 0) {
            int m = check_marker(j);
            if (m < 0)
                return m;
            if (m == 2) {
                message("DEBUG", "Keine Antwort auf ^HW nach dem Wiederverbinden.");
                return PRINTER_UNKNOWN;
            }
            return m == 1 ? PRINTER_KEPT : PRINTER_RESTARTED;
        }
        sleep_ms(j->t.error_poll);
        int q = query_status(j, status);
        if (q == -2)
            return -2;
        if (q == 1) {
            last_answer = now_ms();
            continue;
        }
        if (q == 0 && now_ms() - last_answer < j->t.stall)
            continue;
        return -1;
    }
}

/*
 * Nach einem Neustart des Druckers: Auftragskopf (mit den Steuerzeichen des Auftragsanfangs),
 * danach ^JZY und Neustart-Merker erneut senden; zuletzt die Steuerzeichen `target` einstellen.
 */
static int resend_session(job *j, lwb_prefixes target)
{
    int rc = switch_prefixes(j, j->start_prefixes);
    if (rc != 0)
        return rc;
    if (j->prologue.len > 0) {
        rc = send_raw_split(j, j->prologue.data, j->prologue.len);
        if (rc != 0)
            return rc;
        j->prefixes = j->prologue_prefixes;
    }
    rc = switch_prefixes(j, target);
    if (rc != 0)
        return rc;
    if (j->session_armed) {
        rc = send_reprint_setting(j);
        if (rc == 0)
            rc = store_marker(j);
    }
    return rc;
}

/* Nach dem Wiederverbinden je nach Neustart-Prüfung fortsetzen. 0 = weiter, -1/-2 wie send_all. */
static int resume_after_reconnect(job *j, int verdict, bool busy, lwb_prefixes expected)
{
    int rc;
    if (j->outstanding_active && !j->outstanding_written) {
        /* Beim Senden des Formats abgebrochen. */
        if (busy && verdict == PRINTER_KEPT) {
            j->outstanding_written = true;   /* vollständig angekommen */
            j->prefixes = j->outstanding_after;
            return 0;
        }
        if (verdict == PRINTER_RESTARTED) {
            message("INFO", "Drucker wurde neu gestartet – Auftragseinstellungen werden erneut gesendet.");
            rc = resend_session(j, j->outstanding_prefixes);
            if (rc != 0)
                return rc;
        }
        /* Das Format kam nicht vollständig an (ein Teilformat hat ~JX verworfen): erneut senden. */
        j->outstanding_seen = false;
        return send_outstanding(j);
    }
    if (j->outstanding_active) {
        if (verdict == PRINTER_KEPT)
            return 0;   /* liegt noch im Drucker bzw. ist gedruckt – wait_until_idle zählt es */
        long remaining = j->outstanding_seen && j->outstanding_remaining > 0 ? j->outstanding_remaining
                                                                             : j->outstanding_quantity;
        if (verdict == PRINTER_UNKNOWN) {
            /* Nicht raten: erneut senden könnte doppelt drucken, nicht senden Etiketten auslassen. */
            message("WARNING", "Verbindung zum Drucker unterbrochen – ob er neu gestartet wurde, lässt sich "
                               "nicht prüfen. Möglicherweise fehlen bis zu %ld Etikett(en); bitte nachzählen.",
                    remaining);
            j->labels_uncertain += remaining;
            return 0;
        }
        /* Neu gestartet: Kopf, ^JZY, Merker und die restlichen Etiketten erneut senden. */
        if (remaining < j->outstanding_quantity) {
            j->labels_done += j->outstanding_quantity - remaining;
            j->outstanding_quantity = remaining;
        }
        message("INFO", "Drucker wurde neu gestartet – %ld Etikett(en) werden erneut gesendet.", remaining);
        rc = resend_session(j, j->outstanding_prefixes);
        if (rc != 0)
            return rc;
        j->outstanding_written = false;
        j->outstanding_seen = false;
        j->outstanding_remaining = remaining;
        return send_outstanding(j);
    }
    if (verdict == PRINTER_RESTARTED && (j->session_armed || j->prologue.len > 0)) {
        message("INFO", "Drucker wurde neu gestartet – Auftragseinstellungen werden erneut gesendet.");
        return resend_session(j, expected);
    }
    return 0;
}

/*
 * Nach einem Verbindungsabbruch (nur getaktet): neu verbinden, prüfen, ob der Drucker neu
 * gestartet wurde, und das Nötige erneut senden. 0 = weiter, -2 = Abbruch, -3 = aufgegeben.
 */
static int recover(job *j)
{
    lwb_prefixes expected = j->prefixes;
    close_connection(j);
    message("INFO", "Verbindung zum Drucker %s:%d unterbrochen – wird neu aufgebaut.", j->host, j->port);
    for (;;) {
        lwb_host_status status;
        bool answered = false;
        bool reset = false;
        j->prefixes = expected;
        report_connecting(j, true);
        int rc = connect_with_retry(j, &status, &answered, true, &reset);
        if (rc != 0)
            return rc;
        if (!answered) {
            /* Verbunden, aber stumm (auch mit den gespeicherten Steuerzeichen): erneut versuchen. */
            message("DEBUG", "Drucker antwortet nicht auf ~HS – neue Verbindung.");
            close_connection(j);
            sleep_ms(j->t.reconnect);
            continue;
        }
        report_connecting(j, false);
        bool had_partial = status.partial_format;
        if (had_partial) {
            /* Teilformat im Drucker (beim Senden abgebrochen): nur dieses verwerfen (~JX). */
            char cancel[4] = { (char)j->prefixes.control, 'J', 'X', '\0' };
            rc = send_text(j, cancel, true);
            if (rc == -2)
                return -2;
            if (rc != 0) {
                close_connection(j);
                continue;
            }
            sleep_ms(j->t.cancel_delay);
        }
        bool busy = status.formats_in_buffer > 0 || status.labels_remaining > 0;
        int verdict = restart_verdict(j, &status, reset, had_partial);
        if (verdict == -2)
            return -2;
        if (verdict == -1) {
            close_connection(j);
            continue;
        }
        rc = resume_after_reconnect(j, verdict, busy, expected);
        if (rc == -2)
            return -2;
        if (rc != 0) {
            close_connection(j);
            continue;
        }
        return 0;
    }
}

/*
 * Wartet, bis der Drucker nichts mehr zu tun hat (offenes Format vollständig gedruckt, kein
 * Fehler). Liest währenddessen die Eingabe weiter (pump_input). 0 = bereit, -2 = Abbruch,
 * -3 = aufgegeben.
 */
static int wait_until_idle(job *j)
{
    int idle_streak = 0;
    long long last_answer = now_ms();
    for (;;) {
        if (g_cancel)
            return -2;
        lwb_host_status status;
        int q = query_status(j, &status);
        if (q == -2)
            return -2;
        if (q == 0 && now_ms() - last_answer < j->t.stall) {
            message("DEBUG", "Keine Antwort auf ~HS – neuer Versuch.");
            continue;
        }
        if (q != 1) {
            int rc = recover(j);
            if (rc != 0)
                return rc;
            last_answer = now_ms();
            idle_streak = 0;
            continue;
        }
        last_answer = now_ms();
        unsigned reasons = 0;
        if (handle_reasons(j, &status, &reasons) == -2)
            return -2;
        if (j->outstanding_active) {
            if (status.formats_in_buffer > 0 || status.labels_remaining > 0) {
                j->outstanding_seen = true;
                if (status.formats_in_buffer == 0 && status.labels_remaining > 0)
                    j->outstanding_remaining = status.labels_remaining > j->outstanding_quantity
                                                   ? j->outstanding_quantity : status.labels_remaining;
                else if (status.formats_in_buffer > 0)
                    j->outstanding_remaining = j->outstanding_quantity;
            }
            report_progress(j, false);
        }
        if (lwb_status_idle(&status)) {
            idle_streak++;
            /* Nach dem Senden zweimal „leer“ verlangen: Der Drucker hat das Format evtl. noch nicht gezählt. */
            int needed = (j->outstanding_active && !j->outstanding_seen) ? 2 : 1;
            if (idle_streak >= needed) {
                if (j->outstanding_active) {
                    j->labels_done += j->outstanding_quantity;
                    j->outstanding_active = false;
                    j->outstanding_quantity = 0;
                    lw_buf_reset(&j->outstanding);
                }
                return 0;
            }
        } else {
            idle_streak = 0;
        }
        pump_input();
        sleep_ms(reasons != 0 ? j->t.error_poll : j->t.poll);
    }
}

/*
 * Vor dem ersten druckenden Format (der Drucker ist bereit): ^XA^JZY^XZ – nach dem Auftragskopf,
 * damit ein ~JA darin es nicht verwirft – und den Neustart-Merker speichern; beim ersten Mal prüfen,
 * ob der Drucker ihn per ^HW meldet. 0 = erledigt, -1 = Verbindungsfehler, -2 = Abbruch.
 */
static int arm_session(job *j)
{
    int rc = send_reprint_setting(j);
    if (rc != 0)
        return rc;
    rc = store_marker(j);
    if (rc != 0)
        return rc;
    if (!j->marker_checked) {
        int m = check_marker(j);
        if (m < 0)
            return m;
        j->marker_checked = true;
        j->marker_ok = m == 1;
        if (!j->marker_ok)
            message("DEBUG", "Drucker meldet den Neustart-Merker %s nicht – nach einem Verbindungsabbruch "
                             "wird nichts automatisch wiederholt.", MARKER_NAME);
    }
    j->session_armed = true;
    return 0;
}

/* Rohdaten (Auftragskopf, nicht druckende Formate) senden; nach einem Verbindungsabbruch vollständig
 * erneut (kurz und wiederholbar; ein Teilformat verwirft recover() per ~JX). */
static int send_raw_paced(job *j, const uint8_t *data, size_t len, lwb_prefixes after)
{
    for (;;) {
        int rc = send_raw_split(j, data, len);
        if (rc == 0) {
            j->prefixes = after;
            return 0;
        }
        if (rc != -1)
            return rc;
        rc = recover(j);
        if (rc != 0)
            return rc;
    }
}

/* Ein druckendes Format (in j->next) getaktet senden. */
static int send_format_paced(job *j, lwb_prefixes start, lwb_prefixes after, long quantity)
{
    int rc = wait_until_idle(j);
    if (rc != 0)
        return rc;
    while (!j->session_armed) {
        rc = arm_session(j);
        if (rc == 0)
            break;
        if (rc != -1)
            return rc;
        rc = recover(j);
        if (rc != 0)
            return rc;
    }
    lw_buf swap = j->outstanding;
    j->outstanding = j->next;
    j->next = swap;
    lw_buf_reset(&j->next);
    j->outstanding_prefixes = start;
    j->outstanding_after = after;
    j->outstanding_active = true;
    j->outstanding_written = false;
    j->outstanding_quantity = quantity;
    j->outstanding_remaining = quantity;
    j->outstanding_seen = false;
    report_progress(j, false);
    for (;;) {
        rc = send_outstanding(j);
        if (rc != -1)
            return rc;
        rc = recover(j);   /* sendet das Format selbst erneut */
        if (rc != 0)
            return rc;
        if (j->outstanding_written)
            return 0;
    }
}

/*
 * Ungetaktet (wie socket://) senden. Bricht die Verbindung ab, nachdem schon Auftragsdaten beim
 * Drucker sind, endet der Auftrag mit einem Fehler: Was davon angekommen ist, lässt sich nicht
 * feststellen; erneut senden könnte doppelt drucken. Nur ohne gesendete Daten wird neu verbunden.
 * `written` erhält die gesendeten Bytes. 0 = gesendet, -2 = Abbruch, -3 = Fehler.
 */
static int send_unpaced(job *j, const uint8_t *data, size_t len, size_t *written)
{
    *written = 0;
    for (;;) {
        bool before = j->data_sent;
        size_t now = 0;
        int rc = send_data(j, data, len, &now);
        *written += now;
        if (rc != -1)
            return rc;
        if (before || now > 0) {
            message("ERROR", "Verbindung zum Drucker %s:%d beim Senden unterbrochen – der Auftrag wird nicht "
                             "erneut gesendet, damit nichts doppelt gedruckt wird.", j->host, j->port);
            return -3;
        }
        close_connection(j);
        bool answered = false;
        rc = connect_with_retry(j, NULL, &answered, false, NULL);
        if (rc != 0)
            return rc;
    }
}

/* ------------------------------------------------------------------------------------------ */
/* Etiketten zählen                                                                           */
/* ------------------------------------------------------------------------------------------ */

/* Zählt die Etiketten aller Formate in data[0, len). */
static long count_labels(const uint8_t *data, size_t len, lwb_prefixes prefixes)
{
    long total = 0;
    size_t pos = 0;
    while (pos < len) {
        size_t seg = 0;
        lwb_prefixes start = prefixes;
        lwb_segment_kind kind = lwb_next_segment(data + pos, len - pos, true, &prefixes, &seg);
        if (kind == LWB_SEGMENT_NONE || seg == 0)
            break;
        if (kind == LWB_SEGMENT_FORMAT) {
            lwb_format_info info;
            lwb_format_analyze(data + pos, seg, start, &info);
            total += info.quantity;
        }
        pos += seg;
    }
    return total;
}

/* ------------------------------------------------------------------------------------------ */
/* Hauptprogramm                                                                              */
/* ------------------------------------------------------------------------------------------ */

static bool option_false(const char *value)
{
    return value != NULL && (lw_str_ieq(value, "false") || lw_str_ieq(value, "no") || lw_str_ieq(value, "off") ||
                             lw_str_ieq(value, "0"));
}

static int finish_cancelled(job *j)
{
    /* Ab hier ist der Abbruch beschlossen; weitere Signale ändern nichts mehr. */
    g_cancel = 0;
    clear_states(j);
    message("INFO", "Auftrag abgebrochen – Druckerpuffer wird geleert.");
    if (j->fd < 0 && j->anything_sent) {
        j->t.connect_timeout = 2000;
        (void)open_connection(j);
    }
    if (j->fd >= 0) {
        char cancel[5] = { (char)j->prefixes.control, 'J', 'A', '\n', '\0' };
        j->t.stall = 0;
        (void)send_text(j, cancel, false);
        sleep_ms(env_ms("LW_BACKEND_CANCEL_DELAY_MS", 200, 0));
        close_connection(j);
    }
    return BACKEND_OK;
}

int main(int argc, char *argv[])
{
    setbuf(stderr, NULL);
    signal(SIGPIPE, SIG_IGN);
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    sigemptyset(&action.sa_mask);
    action.sa_handler = on_sigterm;
    sigaction(SIGTERM, &action, NULL);

    if (argc == 1) {
        /* Geräteerkennung (lpinfo -v): keine eigene Suche, nur das Schema anbieten. */
        printf("network labelwerk \"Unknown\" \"LabelWerk Zebra network printer (resume after media out)\"\n");
        return BACKEND_OK;
    }
    if (argc < 6 || argc > 7) {
        fprintf(stderr, "Usage: %s job-id user title copies options [file]\n", argv[0]);
        return BACKEND_FAILED;
    }

    job j;
    memset(&j, 0, sizeof(j));
    j.fd = -1;
    lw_buf_init(&j.rx);
    lw_buf_init(&j.prologue);
    lw_buf_init(&j.next);
    lw_buf_init(&j.outstanding);
    j.t.poll = env_ms("LW_BACKEND_POLL_MS", 200, 1);
    j.t.error_poll = env_ms("LW_BACKEND_ERROR_POLL_MS", 2000, 1);
    j.t.reply_timeout = env_ms("LW_BACKEND_REPLY_TIMEOUT_MS", 5000, 10);
    j.t.stall = env_ms("LW_BACKEND_STALL_MS", 30000, 10);
    j.t.reconnect = env_ms("LW_BACKEND_RECONNECT_MS", 1000, 1);
    j.t.reconnect_max = env_ms("LW_BACKEND_RECONNECT_MAX_MS", 30000, 1);
    j.t.reconnect_limit = env_ms("LW_BACKEND_RECONNECT_LIMIT", 0, 0);
    j.t.connect_timeout = env_ms("LW_BACKEND_CONNECT_TIMEOUT_MS", 10000, 10);
    j.t.cancel_delay = env_ms("LW_BACKEND_CANCEL_DELAY_MS", 500, 0);

    /* --- Geräte-URI ---------------------------------------------------------------------- */
    const char *uri = getenv("DEVICE_URI");
    if (uri == NULL || uri[0] == '\0')
        uri = argv[0];
    char options[512];
    if (!lwb_parse_uri(uri, j.host, sizeof(j.host), &j.port, options, sizeof(options))) {
        message("ERROR", "Ungültige Geräte-URI „%s“ – erwartet labelwerk://host:port.", uri);
        return BACKEND_FAILED;
    }

    /* --- Auftragsoptionen (Steuerzeichen, Sprache, Wartezeit nach ~JA) -------------------- */
    lw_cups_options opts;
    lw_cups_options_open(&opts, argv[5], NULL);
    lw_settings settings;
    lw_settings_init(&settings);
    lw_settings_resolve(&settings, lw_cups_lookup, &opts, NULL);
    j.start_prefixes = lwb_prefixes_standard();
    if (settings.control_printer) {
        j.start_prefixes.format = (uint8_t)settings.format_prefix;
        j.start_prefixes.control = (uint8_t)settings.control_prefix;
        j.start_prefixes.delimiter = (uint8_t)settings.delimiter;
    }
    j.prefixes = j.start_prefixes;
    j.prologue_prefixes = j.start_prefixes;
    j.t.ja_delay = settings.cancel_delay;
    const char *resume_option = lw_cups_lookup(&opts, "lwResumeOnError", LW_LEVEL_ARGV);
    char mode[32] = "";
    bool stream_requested = lwb_uri_option(options, "mode", mode, sizeof(mode)) && lw_str_ieq(mode, "stream");
    j.paced = settings.language == LW_LANGUAGE_ZPL && !option_false(resume_option) && !stream_requested;
    if (!j.paced) {
        message("DEBUG", "Auftrag wird am Stück gesendet (%s).",
                settings.language != LW_LANGUAGE_ZPL ? lw_language_name(settings.language)
                                                     : (stream_requested ? "mode=stream" : "lwResumeOnError=False"));
    }
    lw_settings_free(&settings);
    lw_cups_options_close(&opts);

    /* --- Eingabe ------------------------------------------------------------------------- */
    input in;
    memset(&in, 0, sizeof(in));
    bool whole_input = false;   /* Eingabe vollständig im Speicher (weitere Kopien ohne Neulesen) */
    lw_buf_init(&in.data);
    int copies = 1;
    if (argc == 7) {
        in.fd = open(argv[6], O_RDONLY);
        if (in.fd < 0) {
            message("ERROR", "Druckdatei „%s“ nicht lesbar: %s", argv[6], strerror(errno));
            return BACKEND_FAILED;
        }
        copies = atoi(argv[4]);
        if (copies < 1)
            copies = 1;
    } else {
        in.fd = 0;
    }

    int result = BACKEND_OK;
    size_t written = 0;

    /* --- Verbinden ----------------------------------------------------------------------- */
    message("INFO", "Verbinde mit Drucker %s:%d …", j.host, j.port);
    lwb_host_status status;
    bool answered = false;
    int rc = connect_with_retry(&j, &status, &answered, false, NULL);
    if (rc == -2)
        { result = finish_cancelled(&j); goto done; }
    if (rc != 0) {
        message("ERROR", "Drucker %s:%d nicht erreichbar.", j.host, j.port);
        clear_states(&j);
        result = BACKEND_RETRY;
        goto done;
    }
    if (j.paced && !answered) {
        message("WARNING", "Der Drucker beantwortet ~HS nicht – der Auftrag wird ohne Fortsetzen nach "
                           "Papier- oder Farbbandende gesendet.");
        j.paced = false;
    }
    if (j.paced)
        report_reasons(&j, lwb_status_reasons(&status));

    /* --- Daten --------------------------------------------------------------------------- */
    /* Eine Druckdatei (Kopien) ganz einlesen; vom Filter (stdin) nur, was schon da ist – das erste
     * Etikett geht los, sobald es vollständig ist; die Gesamtzahl folgt, sobald das Ende gelesen ist. */
    if (j.paced && argc == 7) {
        while (!in.eof && in.data.len < READ_AHEAD_LIMIT) {
            rc = read_more(&in);
            if (rc == -2)
                { result = finish_cancelled(&j); goto done; }
            if (rc != 0) {
                message("ERROR", "Druckdaten nicht lesbar: %s", strerror(errno));
                clear_states(&j);
                result = BACKEND_FAILED;
                goto done;
            }
        }
        whole_input = in.eof;
    }
    g_input = j.paced ? &in : NULL;
    long labels_seen = 0;         /* Etiketten der schon gesendeten Formate (erste Kopie) */
    bool total_known = false;

    for (int copy = 0; copy < copies && result == BACKEND_OK; copy++) {
        if (copy > 0) {
            if (!whole_input) {
                if (lseek(in.fd, 0, SEEK_SET) != 0) {
                    message("ERROR", "Druckdatei für weitere Kopien nicht lesbar.");
                    result = BACKEND_FAILED;
                    break;
                }
                lw_buf_reset(&in.data);
                in.eof = false;
            }
            in.pos = 0;
            j.prefixes = j.start_prefixes;
        }
        for (;;) {
            if (g_cancel)
                { result = finish_cancelled(&j); goto done; }
            if (j.paced)
                pump_input();
            if (in.failed) {
                message("ERROR", "Druckdaten nicht lesbar.");
                result = BACKEND_FAILED;
                break;
            }
            const uint8_t *data = in.data.data + in.pos;
            size_t len = in.data.len - in.pos;
            if (j.paced && copy == 0 && in.eof && !total_known) {
                total_known = true;
                j.labels_total = (labels_seen + count_labels(data, len, j.prefixes)) * copies;
            }
            if (!j.paced) {
                if (len > 0) {
                    rc = send_unpaced(&j, data, len, &written);
                    if (rc == -2)
                        { result = finish_cancelled(&j); goto done; }
                    if (rc != 0) {
                        result = BACKEND_FAILED;
                        break;
                    }
                    in.pos += len;
                }
                if (in.eof)
                    break;
            } else {
                size_t seg = 0;
                lwb_prefixes start = j.prefixes;
                lwb_prefixes after = j.prefixes;
                lwb_segment_kind kind = lwb_next_segment(data, len, in.eof, &after, &seg);
                if (kind != LWB_SEGMENT_NONE && lwb_segment_is_download(data, seg, start)) {
                    /* Download (Grafik, Schrift, Firmware) bzw. Binärdaten: keine ~HS-Abfragen mehr
                     * einschieben, der Rest geht am Stück wie bei socket://. */
                    message("DEBUG", "Download- bzw. Binärdaten im Auftrag – Rest wird am Stück gesendet.");
                    rc = wait_until_idle(&j);
                    if (rc == -2) {
                        result = finish_cancelled(&j);
                        goto done;
                    }
                    if (rc != 0) {
                        result = BACKEND_FAILED;
                        break;
                    }
                    j.paced = false;
                    g_input = NULL;
                    continue;
                }
                if (kind == LWB_SEGMENT_NONE) {
                    if (in.eof)
                        break;
                } else {
                    if (kind == LWB_SEGMENT_FORMAT) {
                        lwb_format_info info;
                        lwb_format_analyze(data, seg, start, &info);
                        j.prologue_closed = true;
                        if (info.prints) {
                            /* Kopie: während des Wartens liest pump_input weiter (Puffer kann wandern). */
                            lw_buf_reset(&j.next);
                            lw_buf_append(&j.next, data, seg);
                            if (j.next.failed) {
                                message("ERROR", "Zu wenig Speicher für ein Etikett.");
                                result = BACKEND_FAILED;
                                break;
                            }
                            rc = send_format_paced(&j, start, after, info.quantity);
                            if (rc == 0 && copy == 0)
                                labels_seen += info.quantity;
                        } else {
                            rc = send_raw_paced(&j, data, seg, after);
                        }
                    } else {
                        if (!j.prologue_closed && copy == 0) {
                            if (j.prologue.len + seg <= PROLOGUE_LIMIT) {
                                lw_buf_append(&j.prologue, data, seg);
                                j.prologue_prefixes = after;
                            }
                        }
                        rc = send_raw_paced(&j, data, seg, after);
                    }
                    if (rc == -2)
                        { result = finish_cancelled(&j); goto done; }
                    if (rc != 0) {
                        result = BACKEND_FAILED;
                        break;
                    }
                    in.pos += seg;
                    continue;
                }
            }
            rc = read_more(&in);
            if (rc == -2)
                { result = finish_cancelled(&j); goto done; }
            if (rc != 0) {
                message("ERROR", "Druckdaten nicht lesbar: %s", strerror(errno));
                result = BACKEND_FAILED;
                break;
            }
        }
    }

    if (result == BACKEND_OK && j.paced) {
        rc = wait_until_idle(&j);
        if (rc == -2)
            { result = finish_cancelled(&j); goto done; }
        if (rc != 0) {
            result = BACKEND_FAILED;
        } else {
            if (j.session_armed)
                delete_marker(&j);
            if (j.labels_uncertain > 0)
                message("WARNING", "%ld Etiketten gesendet – bis zu %ld davon nach einem Verbindungsabbruch "
                                   "möglicherweise nicht gedruckt; bitte nachzählen.",
                        j.labels_done, j.labels_uncertain);
            else if (j.labels_done > 0)
                message("INFO", "Alle %ld Etiketten gedruckt.", j.labels_done);
        }
    }
    if (result != BACKEND_OK && j.labels_done > 0)
        message("ERROR", "Verbindung zum Drucker verloren – %ld Etiketten wurden gedruckt.", j.labels_done);
    clear_states(&j);
    if (j.fd >= 0)
        shutdown(j.fd, SHUT_WR);

done:
    g_input = NULL;
    close_connection(&j);
    if (in.fd > 0)
        close(in.fd);
    lw_buf_free(&in.data);
    lw_buf_free(&j.rx);
    lw_buf_free(&j.prologue);
    lw_buf_free(&j.next);
    lw_buf_free(&j.outstanding);
    return result;
}
