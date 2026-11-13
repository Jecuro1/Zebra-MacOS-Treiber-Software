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
 *   2. ^XA^JZY^XZ – der Drucker druckt das Etikett, bei dem ein Fehler auftrat, danach erneut.
 *   3. Auftragskopf (alles vor dem ersten ^XA) senden, dann je Format ^XA…^XZ: vorher per ~HS
 *      warten, bis der Drucker nichts mehr im Puffer hat (keine Formate, keine Restetiketten, kein
 *      Fehler). So liegt nie mehr als ein Format im Drucker; der Auftrag bleibt in der
 *      macOS-Warteschlange, bis das letzte Etikett gedruckt ist.
 *   4. Papier leer, Farbband leer, Druckkopf offen, Pause: CUPS erfährt es über
 *      „STATE: +media-empty-error“ usw. und eine deutsche INFO-Meldung; das Backend fragt alle 2 s
 *      nach und setzt fort, sobald der Fehler behoben ist (der Drucker wiederholt das
 *      unterbrochene Etikett wegen ^JZY selbst).
 *   5. Verbindungsabbruch: neu verbinden (1 s, 2 s, 4 s … höchstens 30 s, unbegrenzt oft). War der
 *      Drucker beim Abbruch im Fehlerzustand und meldet danach einen leeren Puffer (aus- und
 *      eingeschaltet, um Etiketten einzulegen), gehen Auftragskopf und das offene Format mit den
 *      restlichen Etiketten erneut hinaus. Ein unvollständig gesendetes Format verwirft ~JA vor dem
 *      erneuten Senden.
 *   6. Abbrechen (SIGTERM): ~JA leert den Druckerpuffer, dann Ende.
 *
 * EPL/CPCL (lwLanguage), lwResumeOnError=False in den Auftragsoptionen und ?mode=stream senden wie
 * `socket` am Stück.
 *
 * Rechte: root:wheel 0755 – CUPS startet Backends, die für „andere“ ausführbar sind, als
 * unprivilegierter Benutzer (lp/_lp); 0700 hieße Ausführung als root, die dieses Backend nicht
 * braucht (nur TCP zum Drucker).
 *
 * Umgebung nur für Tests: LW_BACKEND_POLL_MS, LW_BACKEND_ERROR_POLL_MS, LW_BACKEND_REPLY_TIMEOUT_MS,
 * LW_BACKEND_STALL_MS, LW_BACKEND_RECONNECT_MS, LW_BACKEND_RECONNECT_MAX_MS,
 * LW_BACKEND_RECONNECT_LIMIT, LW_BACKEND_CONNECT_TIMEOUT_MS, LW_BACKEND_CANCEL_DELAY_MS.
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

/* Höchstmenge, die vor dem ersten Etikett gelesen wird, um die Gesamtzahl zu kennen. */
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
/* Auftrag                                                                                    */
/* ------------------------------------------------------------------------------------------ */

typedef struct timing {
    long poll;            /* Abfrage während des Drucks */
    long error_poll;      /* Abfrage im Fehlerzustand (2 s) */
    long reply_timeout;   /* Wartezeit auf eine ~HS-Antwort */
    long stall;           /* so lange ohne Antwort → Verbindung gilt als verloren */
    long reconnect;       /* erste Wartezeit vor einem neuen Verbindungsversuch */
    long reconnect_max;
    long reconnect_limit; /* 0 = unbegrenzt */
    long connect_timeout;
    long cancel_delay;    /* Wartezeit nach ~JA vor dem erneuten Senden */
} timing;

typedef struct job {
    char host[512];
    int port;
    int fd;
    bool paced;
    timing t;
    lw_buf rx;

    lwb_prefixes start_prefixes;   /* Steuerzeichen am Auftragsanfang */
    lwb_prefixes prefixes;         /* aktuelle Steuerzeichen (für ~HS, ~JA) */

    lw_buf prologue;               /* Rohdaten vor dem ersten Format (für einen Neustart) */
    bool prologue_closed;

    /* Offenes Format: gesendet, aber noch nicht vollständig gedruckt. */
    lw_buf outstanding;
    lwb_prefixes outstanding_prefixes;
    bool outstanding_active;
    bool outstanding_written;
    long outstanding_quantity;
    long outstanding_remaining;   /* zuletzt gemeldete Restetiketten (> 0) */
    bool outstanding_error;       /* Fehlerzustand seit dem Senden gesehen */
    bool outstanding_seen;        /* Drucker hat das Format schon gemeldet (Puffer/Rest) */

    long labels_done;
    long labels_total;            /* 0 = unbekannt */
    long reported_label;
    unsigned reported_reasons;
    bool reported_connecting;
    bool anything_sent;
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

/* Sendet alles. 0 = gesendet, -1 = Verbindungsfehler, -2 = Abbruch. `allow_cancel` = false für ~JA. */
static int send_all(job *j, const void *data, size_t len, bool allow_cancel)
{
    const uint8_t *p = data;
    long long last_progress = now_ms();
    long stall = j->t.stall > 300000 ? j->t.stall : 300000;
    while (len > 0) {
        if (allow_cancel && g_cancel)
            return -2;
        if (j->fd < 0)
            return -1;
        struct pollfd pfd = { j->fd, POLLOUT, 0 };
        int n = poll(&pfd, 1, 250);
        if (n < 0 && errno != EINTR)
            return -1;
        if (n <= 0) {
            if (now_ms() - last_progress > stall)
                return -1;
            continue;
        }
        if (pfd.revents & (POLLERR | POLLHUP | POLLNVAL))
            return -1;
        ssize_t sent = send(j->fd, p, len, 0);
        if (sent < 0) {
            if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)
                continue;
            return -1;
        }
        p += sent;
        len -= (size_t)sent;
        last_progress = now_ms();
        j->anything_sent = true;
    }
    return 0;
}

static int send_text(job *j, const char *text, bool allow_cancel)
{
    return send_all(j, text, strlen(text), allow_cancel);
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

/* ~HS abfragen. 1 = Antwort, 0 = keine Antwort, -1 = Verbindungsfehler, -2 = Abbruch. */
static int query_status(job *j, lwb_host_status *status)
{
    /* Ältere Antworten verwerfen. */
    while (receive(j, 0) > 0) {
    }
    lw_buf_reset(&j->rx);
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

/* ------------------------------------------------------------------------------------------ */
/* Verbindungsaufbau und Wiederaufnahme                                                       */
/* ------------------------------------------------------------------------------------------ */

/* ^XA^JZY^XZ mit den aktuellen Steuerzeichen. */
static int send_reprint_setting(job *j)
{
    char text[16];
    snprintf(text, sizeof(text), "%cXA%cJZY%cXZ\n", j->prefixes.format, j->prefixes.format, j->prefixes.format);
    return send_text(j, text, true);
}

/*
 * Verbindet (erneut), bis der Drucker antwortet. Im getakteten Modus muss er auch ~HS
 * beantworten (`status` erhält die Antwort). 0 = verbunden, -2 = Abbruch, -3 = Versuche erschöpft.
 */
static int connect_with_retry(job *j, lwb_host_status *status, bool *answered)
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
            int q = query_status(j, status);
            if (q == -2)
                return -2;
            if (q == 1) {
                *answered = true;
                report_connecting(j, false);
                return 0;
            }
            if (q == 0) {
                /* Verbunden, aber keine Antwort: Entscheidung beim Aufrufer (erste Verbindung). */
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
    rc = send_all(j, data.data, data.len, true);
    lw_buf_free(&data);
    if (rc == 0)
        j->outstanding_written = true;
    return rc;
}

/*
 * Nach einem Verbindungsabbruch: neu verbinden und entscheiden, ob das offene Format erneut
 * gesendet werden muss. 0 = weiter, -2 = Abbruch, -3 = aufgegeben.
 */
static int recover(job *j)
{
    bool was_error = j->outstanding_error;
    close_connection(j);
    message("INFO", "Verbindung zum Drucker %s:%d unterbrochen – wird neu aufgebaut.", j->host, j->port);
    for (;;) {
        lwb_host_status status;
        bool answered = false;
        report_connecting(j, true);
        int rc = connect_with_retry(j, &status, &answered);
        if (rc != 0)
            return rc;
        if (!answered) {
            /* Verbunden, aber stumm: wie ein Abbruch behandeln. */
            close_connection(j);
            sleep_ms(j->t.reconnect);
            continue;
        }
        report_connecting(j, false);
        if (!j->paced)
            return 0;
        if (send_reprint_setting(j) != 0) {
            close_connection(j);
            continue;
        }
        if (!j->outstanding_active)
            return 0;
        bool power_cycled = j->outstanding_written && was_error && lwb_status_idle(&status);
        if (j->outstanding_written && !power_cycled)
            return 0;   /* Das Format liegt noch im Drucker bzw. ist gedruckt. */
        if (power_cycled) {
            /* Der Drucker hat seinen Puffer verloren: Kopf und Rest des Formats erneut senden. */
            long remaining = j->outstanding_seen && j->outstanding_remaining > 0
                                 ? j->outstanding_remaining : j->outstanding_quantity;
            if (remaining < j->outstanding_quantity) {
                j->labels_done += j->outstanding_quantity - remaining;
                j->outstanding_quantity = remaining;
            }
            message("INFO", "Drucker wurde neu gestartet – %ld Etikett(en) werden erneut gesendet.", remaining);
            if (j->prologue.len > 0 && send_all(j, j->prologue.data, j->prologue.len, true) != 0) {
                close_connection(j);
                continue;
            }
        } else {
            /* Teilweise gesendet: Rest im Drucker verwerfen. */
            char cancel[4] = { (char)j->prefixes.control, 'J', 'A', '\0' };
            if (send_text(j, cancel, true) != 0) {
                close_connection(j);
                continue;
            }
            sleep_ms(j->t.cancel_delay);
        }
        j->outstanding_written = false;
        j->outstanding_error = false;
        j->outstanding_seen = false;
        int sent = send_outstanding(j);
        if (sent == -2)
            return -2;
        if (sent != 0) {
            close_connection(j);
            continue;
        }
        return 0;
    }
}

/*
 * Wartet, bis der Drucker nichts mehr zu tun hat (offenes Format vollständig gedruckt, kein
 * Fehler). 0 = bereit, -2 = Abbruch, -3 = aufgegeben.
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
        unsigned reasons = lwb_status_reasons(&status);
        report_reasons(j, reasons);
        if (status.under_temperature || status.over_temperature)
            message("DEBUG", "Druckkopftemperatur außerhalb des Betriebsbereichs.");
        if (j->outstanding_active) {
            if (reasons != 0)
                j->outstanding_error = true;
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
        sleep_ms(reasons != 0 ? j->t.error_poll : j->t.poll);
    }
}

/* Sendet Daten; bei einem Verbindungsfehler neu verbinden und erneut senden (nur Rohdaten). */
static int send_raw_resilient(job *j, const uint8_t *data, size_t len)
{
    for (;;) {
        int rc = send_all(j, data, len, true);
        if (rc != -1)
            return rc;
        rc = recover(j);
        if (rc != 0)
            return rc;
        /* Rohdaten (Kopf, Steuerbefehle) sind kurz: vollständig erneut senden. */
    }
}

/* Ein druckendes Format getaktet senden. */
static int send_format_paced(job *j, const uint8_t *data, size_t len, lwb_prefixes prefixes, long quantity)
{
    int rc = wait_until_idle(j);
    if (rc != 0)
        return rc;
    lw_buf_reset(&j->outstanding);
    lw_buf_append(&j->outstanding, data, len);
    if (j->outstanding.failed) {
        message("ERROR", "Zu wenig Speicher für ein Etikett.");
        return -3;
    }
    j->outstanding_prefixes = prefixes;
    j->outstanding_active = true;
    j->outstanding_written = false;
    j->outstanding_quantity = quantity;
    j->outstanding_remaining = quantity;
    j->outstanding_error = false;
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

/* ------------------------------------------------------------------------------------------ */
/* Eingabe                                                                                    */
/* ------------------------------------------------------------------------------------------ */

typedef struct input {
    int fd;
    lw_buf data;
    size_t pos;
    bool eof;
} input;

/* Liest weitere Daten. 0 = gelesen bzw. Ende, -1 = Fehler, -2 = Abbruch. */
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

    /* --- Auftragsoptionen (Steuerzeichen, Sprache) --------------------------------------- */
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

    /* --- Verbinden ----------------------------------------------------------------------- */
    message("INFO", "Verbinde mit Drucker %s:%d …", j.host, j.port);
    lwb_host_status status;
    bool answered = false;
    int rc = connect_with_retry(&j, &status, &answered);
    if (rc == -2)
        return finish_cancelled(&j);
    if (rc != 0) {
        message("ERROR", "Drucker %s:%d nicht erreichbar.", j.host, j.port);
        return BACKEND_RETRY;
    }
    if (j.paced && !answered) {
        message("WARNING", "Der Drucker beantwortet ~HS nicht – der Auftrag wird ohne Fortsetzen nach "
                           "Papier- oder Farbbandende gesendet.");
        j.paced = false;
    }
    if (j.paced) {
        report_reasons(&j, lwb_status_reasons(&status));
        if (send_reprint_setting(&j) != 0 && !g_cancel) {
            rc = recover(&j);
            if (rc == -2)
                return finish_cancelled(&j);
        }
    }

    /* --- Daten --------------------------------------------------------------------------- */
    if (j.paced) {
        /* Vorauslesen, um die Etiketten zu zählen („Etikett 3 von 50“). */
        while (!in.eof && in.data.len < READ_AHEAD_LIMIT) {
            rc = read_more(&in);
            if (rc == -2)
                return finish_cancelled(&j);
            if (rc != 0) {
                message("ERROR", "Druckdaten nicht lesbar: %s", strerror(errno));
                clear_states(&j);
                return BACKEND_FAILED;
            }
        }
        if (in.eof) {
            whole_input = true;
            j.labels_total = count_labels(in.data.data, in.data.len, j.start_prefixes) * copies;
        }
    }

    int result = BACKEND_OK;
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
                return finish_cancelled(&j);
            const uint8_t *data = in.data.data + in.pos;
            size_t len = in.data.len - in.pos;
            if (!j.paced) {
                if (len > 0) {
                    rc = send_raw_resilient(&j, data, len);
                    if (rc == -2)
                        return finish_cancelled(&j);
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
                lwb_segment_kind kind = lwb_next_segment(data, len, in.eof, &j.prefixes, &seg);
                if (kind == LWB_SEGMENT_NONE) {
                    if (in.eof)
                        break;
                } else {
                    if (kind == LWB_SEGMENT_FORMAT) {
                        lwb_format_info info;
                        lwb_format_analyze(data, seg, start, &info);
                        j.prologue_closed = true;
                        if (info.prints)
                            rc = send_format_paced(&j, data, seg, start, info.quantity);
                        else
                            rc = send_raw_resilient(&j, data, seg);
                    } else {
                        if (!j.prologue_closed && copy == 0) {
                            if (j.prologue.len + seg <= PROLOGUE_LIMIT)
                                lw_buf_append(&j.prologue, data, seg);
                        }
                        rc = send_raw_resilient(&j, data, seg);
                    }
                    if (rc == -2)
                        return finish_cancelled(&j);
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
                return finish_cancelled(&j);
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
            return finish_cancelled(&j);
        if (rc != 0)
            result = BACKEND_FAILED;
        else if (j.labels_done > 0)
            message("INFO", "Alle %ld Etiketten gedruckt.", j.labels_done);
    }
    if (result != BACKEND_OK && j.labels_done > 0)
        message("ERROR", "Verbindung zum Drucker verloren – %ld Etiketten wurden gedruckt.", j.labels_done);
    clear_states(&j);
    if (j.fd >= 0) {
        shutdown(j.fd, SHUT_WR);
        close_connection(&j);
    }
    if (in.fd > 0)
        close(in.fd);
    lw_buf_free(&in.data);
    lw_buf_free(&j.rx);
    lw_buf_free(&j.prologue);
    lw_buf_free(&j.outstanding);
    return result;
}
