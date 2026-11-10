/*
 * lw_util.c – Protokollierung, Bytepuffer, Ausgabesenken und Zeichenkettenhilfen.
 */

#if !defined(__APPLE__) && !defined(_DEFAULT_SOURCE)
#  define _DEFAULT_SOURCE 1
#endif

#include "lw_util.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>

/* ------------------------------------------------------------------------------------------ */
/* Protokollierung                                                                            */
/* ------------------------------------------------------------------------------------------ */

const char *lw_log_prefix(lw_log_level level)
{
    switch (level) {
    case LW_LOG_DEBUG: return "DEBUG";
    case LW_LOG_INFO: return "INFO";
    case LW_LOG_WARNING: return "WARNING";
    case LW_LOG_ERROR: return "ERROR";
    }
    return "DEBUG";
}

void lw_logv(const lw_logger *logger, lw_log_level level, const char *fmt, va_list ap)
{
    if (logger == NULL || logger->emit == NULL)
        return;
    /* CUPS begrenzt Meldungszeilen ohnehin auf wenige KiB; 2 KiB genügen für alle Texte. */
    char message[2048];
    int n = vsnprintf(message, sizeof(message), fmt, ap);
    if (n < 0)
        snprintf(message, sizeof(message), "(Meldung konnte nicht formatiert werden)");
    logger->emit(logger->ctx, level, message);
}

void lw_log(const lw_logger *logger, lw_log_level level, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    lw_logv(logger, level, fmt, ap);
    va_end(ap);
}

void lw_logger_file_emit(void *ctx, lw_log_level level, const char *message)
{
    FILE *out = ctx != NULL ? (FILE *)ctx : stderr;
    fputs(lw_log_prefix(level), out);
    fputs(": ", out);
    for (const char *p = message; *p != '\0'; p++) {
        char c = *p;
        if (c == '\n' || c == '\r')
            c = ' ';
        fputc(c, out);
    }
    fputc('\n', out);
    fflush(out);
}

/* ------------------------------------------------------------------------------------------ */
/* Bytepuffer                                                                                 */
/* ------------------------------------------------------------------------------------------ */

void lw_buf_init(lw_buf *b)
{
    b->data = NULL;
    b->len = 0;
    b->cap = 0;
    b->failed = false;
}

void lw_buf_free(lw_buf *b)
{
    free(b->data);
    lw_buf_init(b);
}

void lw_buf_reset(lw_buf *b)
{
    b->len = 0;
    b->failed = false;
    if (b->data != NULL)
        b->data[0] = 0;
}

bool lw_buf_reserve(lw_buf *b, size_t extra)
{
    if (b->failed)
        return false;
    /* +1 für das abschließende NUL-Byte. */
    if (extra > SIZE_MAX - b->len - 1) {
        b->failed = true;
        return false;
    }
    size_t need = b->len + extra + 1;
    if (need <= b->cap)
        return true;
    size_t cap = b->cap < 256 ? 256 : b->cap;
    while (cap < need) {
        if (cap > SIZE_MAX / 2) {
            cap = need;
            break;
        }
        cap *= 2;
    }
    uint8_t *p = realloc(b->data, cap);
    if (p == NULL) {
        b->failed = true;
        return false;
    }
    b->data = p;
    b->cap = cap;
    return true;
}

bool lw_buf_append(lw_buf *b, const void *data, size_t len)
{
    if (!lw_buf_reserve(b, len))
        return false;
    if (len > 0)
        memcpy(b->data + b->len, data, len);
    b->len += len;
    b->data[b->len] = 0;
    return true;
}

bool lw_buf_append_byte(lw_buf *b, uint8_t byte)
{
    return lw_buf_append(b, &byte, 1);
}

bool lw_buf_append_str(lw_buf *b, const char *s)
{
    return lw_buf_append(b, s, strlen(s));
}

bool lw_buf_printf(lw_buf *b, const char *fmt, ...)
{
    if (b->failed)
        return false;
    char small[256];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(small, sizeof(small), fmt, ap);
    va_end(ap);
    if (n < 0) {
        b->failed = true;
        return false;
    }
    if ((size_t)n < sizeof(small))
        return lw_buf_append(b, small, (size_t)n);
    if (!lw_buf_reserve(b, (size_t)n))
        return false;
    va_start(ap, fmt);
    vsnprintf((char *)b->data + b->len, (size_t)n + 1, fmt, ap);
    va_end(ap);
    b->len += (size_t)n;
    return true;
}

/* ------------------------------------------------------------------------------------------ */
/* Ausgabesenke                                                                               */
/* ------------------------------------------------------------------------------------------ */

static int sink_file_write(void *ctx, const void *data, size_t len)
{
    FILE *f = ctx;
    if (len == 0)
        return 0;
    if (fwrite(data, 1, len, f) != len)
        return errno != 0 ? errno : EIO;
    return 0;
}

static int sink_file_flush(void *ctx)
{
    return fflush((FILE *)ctx) == 0 ? 0 : (errno != 0 ? errno : EIO);
}

static int sink_buf_write(void *ctx, const void *data, size_t len)
{
    return lw_buf_append((lw_buf *)ctx, data, len) ? 0 : ENOMEM;
}

void lw_sink_init_file(lw_sink *s, FILE *file)
{
    s->write = sink_file_write;
    s->flush = sink_file_flush;
    s->ctx = file;
    s->failed = false;
}

void lw_sink_init_buf(lw_sink *s, lw_buf *buffer)
{
    s->write = sink_buf_write;
    s->flush = NULL;
    s->ctx = buffer;
    s->failed = false;
}

bool lw_sink_write(lw_sink *s, const void *data, size_t len)
{
    if (s->failed)
        return false;
    if (s->write(s->ctx, data, len) != 0) {
        s->failed = true;
        return false;
    }
    return true;
}

bool lw_sink_puts(lw_sink *s, const char *str)
{
    return lw_sink_write(s, str, strlen(str));
}

bool lw_sink_printf(lw_sink *s, const char *fmt, ...)
{
    if (s->failed)
        return false;
    lw_buf tmp;
    lw_buf_init(&tmp);
    char small[256];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(small, sizeof(small), fmt, ap);
    va_end(ap);
    if (n < 0) {
        s->failed = true;
        return false;
    }
    if ((size_t)n < sizeof(small))
        return lw_sink_write(s, small, (size_t)n);
    if (!lw_buf_reserve(&tmp, (size_t)n)) {
        s->failed = true;
        return false;
    }
    va_start(ap, fmt);
    vsnprintf((char *)tmp.data, (size_t)n + 1, fmt, ap);
    va_end(ap);
    bool ok = lw_sink_write(s, tmp.data, (size_t)n);
    lw_buf_free(&tmp);
    return ok;
}

bool lw_sink_flush(lw_sink *s)
{
    if (s->failed)
        return false;
    if (s->flush != NULL && s->flush(s->ctx) != 0) {
        s->failed = true;
        return false;
    }
    return true;
}

/* ------------------------------------------------------------------------------------------ */
/* Zeichenketten                                                                              */
/* ------------------------------------------------------------------------------------------ */

static int ascii_lower(int c)
{
    return (c >= 'A' && c <= 'Z') ? c + ('a' - 'A') : c;
}

bool lw_str_ieq(const char *a, const char *b)
{
    if (a == NULL || b == NULL)
        return a == b;
    while (*a != '\0' && *b != '\0') {
        if (ascii_lower((unsigned char)*a) != ascii_lower((unsigned char)*b))
            return false;
        a++;
        b++;
    }
    return *a == *b;
}

bool lw_str_nieq(const char *a, const char *b, size_t n)
{
    if (a == NULL || b == NULL)
        return a == b;
    for (size_t i = 0; i < n; i++) {
        int ca = (unsigned char)a[i], cb = (unsigned char)b[i];
        if (ascii_lower(ca) != ascii_lower(cb))
            return false;
        if (ca == '\0')
            return true;
    }
    return true;
}

bool lw_is_space(int c)
{
    return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\v' || c == '\f';
}

bool lw_trim_copy(char *dst, size_t size, const char *src)
{
    if (size == 0)
        return false;
    dst[0] = '\0';
    if (src == NULL)
        return true;
    while (*src != '\0' && lw_is_space((unsigned char)*src))
        src++;
    size_t len = strlen(src);
    while (len > 0 && lw_is_space((unsigned char)src[len - 1]))
        len--;
    bool fits = len < size;
    if (!fits)
        len = size - 1;
    memcpy(dst, src, len);
    dst[len] = '\0';
    return fits;
}
