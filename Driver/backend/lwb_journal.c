/*
 * lwb_journal.c – Druckjournal des CUPS-Backends „labelwerk“ (siehe lwb_journal.h).
 *
 * Copyright (c) LabelWerk-Projekt. Zebra ist eine Marke der Zebra Technologies Corp.
 */

#if !defined(__APPLE__) && !defined(_DEFAULT_SOURCE)
#  define _DEFAULT_SOURCE 1
#endif

#include "lwb_journal.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

/* Vorläufige Einträge, die ein abgebrochenes Backend hinterließ, nach so vielen Sekunden löschen. */
#define STALE_TEMP_SECONDS (24 * 60 * 60)

/* ------------------------------------------------------------------------------------------ */
/* Zerlegung                                                                                  */
/* ------------------------------------------------------------------------------------------ */

bool lwb_journal_scan(const uint8_t *data, size_t len, lwb_prefixes prefixes, lwb_journal_scan_result *result)
{
    memset(result, 0, sizeof(*result));
    size_t capacity = 0;
    size_t pos = 0;
    bool have_first = false;
    while (pos < len) {
        size_t seg = 0;
        lwb_prefixes start = prefixes;
        lwb_segment_kind kind = lwb_next_segment(data + pos, len - pos, true, &prefixes, &seg);
        if (kind == LWB_SEGMENT_NONE || seg == 0)
            break;
        if (kind == LWB_SEGMENT_FORMAT) {
            lwb_format_info info;
            lwb_format_analyze(data + pos, seg, start, &info);
            if (info.prints) {
                if (result->count == capacity) {
                    size_t grown = capacity == 0 ? 16 : capacity * 2;
                    lwb_journal_label *labels = realloc(result->labels, grown * sizeof(*labels));
                    if (labels == NULL) {
                        lwb_journal_scan_free(result);
                        return false;
                    }
                    result->labels = labels;
                    capacity = grown;
                }
                result->labels[result->count].offset = pos;
                result->labels[result->count].length = seg;
                result->labels[result->count].quantity = info.quantity;
                result->count++;
                if (!have_first) {
                    result->prologue_length = pos;
                    have_first = true;
                }
            }
        }
        pos += seg;
    }
    if (!have_first)
        result->prologue_length = len;
    return true;
}

void lwb_journal_scan_free(lwb_journal_scan_result *result)
{
    free(result->labels);
    memset(result, 0, sizeof(*result));
}

/* ------------------------------------------------------------------------------------------ */
/* meta.json                                                                                  */
/* ------------------------------------------------------------------------------------------ */

/* Länge einer gültigen UTF-8-Folge ab s[0] (0 = ungültig). */
static size_t utf8_sequence(const unsigned char *s, size_t len)
{
    unsigned char c = s[0];
    size_t n;
    unsigned min;
    unsigned value;
    if (c < 0x80)
        return 1;
    if (c >= 0xC2 && c <= 0xDF) {
        n = 2;
        min = 0x80;
        value = c & 0x1F;
    } else if (c >= 0xE0 && c <= 0xEF) {
        n = 3;
        min = 0x800;
        value = c & 0x0F;
    } else if (c >= 0xF0 && c <= 0xF4) {
        n = 4;
        min = 0x10000;
        value = c & 0x07;
    } else {
        return 0;
    }
    if (n > len)
        return 0;
    for (size_t k = 1; k < n; k++) {
        if ((s[k] & 0xC0) != 0x80)
            return 0;
        value = (value << 6) | (s[k] & 0x3F);
    }
    if (value < min || value > 0x10FFFF || (value >= 0xD800 && value <= 0xDFFF))
        return 0;
    return n;
}

static void json_string(lw_buf *out, const char *text)
{
    lw_buf_append_byte(out, '"');
    const unsigned char *s = (const unsigned char *)(text != NULL ? text : "");
    size_t len = strlen((const char *)s);
    size_t i = 0;
    while (i < len) {
        unsigned char c = s[i];
        if (c == '"' || c == '\\') {
            lw_buf_append_byte(out, '\\');
            lw_buf_append_byte(out, c);
            i++;
        } else if (c == '\n') {
            lw_buf_append_str(out, "\\n");
            i++;
        } else if (c == '\r') {
            lw_buf_append_str(out, "\\r");
            i++;
        } else if (c == '\t') {
            lw_buf_append_str(out, "\\t");
            i++;
        } else if (c < 0x20 || c == 0x7F) {
            lw_buf_printf(out, "\\u%04x", c);
            i++;
        } else {
            size_t n = utf8_sequence(s + i, len - i);
            if (n == 0) {
                lw_buf_append_byte(out, '?');
                i++;
            } else {
                lw_buf_append(out, s + i, n);
                i += n;
            }
        }
    }
    lw_buf_append_byte(out, '"');
}

static void iso_date(time_t date, char *out, size_t size)
{
    struct tm tm;
    if (gmtime_r(&date, &tm) == NULL || strftime(out, size, "%Y-%m-%dT%H:%M:%SZ", &tm) == 0)
        snprintf(out, size, "1970-01-01T00:00:00Z");
}

bool lwb_journal_meta_json(const lwb_journal_meta *meta, const lwb_journal_scan_result *scan, lw_buf *out)
{
    char date[32];
    iso_date(meta->date, date, sizeof(date));
    lw_buf_reset(out);
    lw_buf_append_str(out, "{\n  \"version\": 1,\n  \"queue\": ");
    json_string(out, meta->queue);
    lw_buf_printf(out, ",\n  \"jobId\": %ld,\n  \"title\": ", meta->job_id);
    json_string(out, meta->title);
    lw_buf_append_str(out, ",\n  \"user\": ");
    json_string(out, meta->user);
    lw_buf_append_str(out, ",\n  \"date\": ");
    json_string(out, date);
    lw_buf_append_str(out, ",\n  \"printerURI\": ");
    json_string(out, meta->printer_uri);
    lw_buf_append_str(out, ",\n  \"labels\": [");
    for (size_t k = 0; k < scan->count; k++) {
        lw_buf_printf(out, "%s\n    {\"index\": %zu, \"offset\": %zu, \"length\": %zu, \"quantity\": %ld}",
                      k == 0 ? "" : ",", k + 1, scan->labels[k].offset, scan->labels[k].length,
                      scan->labels[k].quantity);
    }
    lw_buf_printf(out, "%s],\n  \"prologueLength\": %zu,\n  \"printed\": %ld,\n  \"reprinted\": %ld,\n"
                       "  \"copies\": %d,\n  \"status\": ",
                  scan->count > 0 ? "\n  " : "", scan->prologue_length, meta->printed, meta->reprinted,
                  meta->copies < 1 ? 1 : meta->copies);
    json_string(out, meta->status);
    lw_buf_append_str(out, "\n}\n");
    return !out->failed;
}

/* ------------------------------------------------------------------------------------------ */
/* Namen                                                                                      */
/* ------------------------------------------------------------------------------------------ */

void lwb_journal_entry_name(time_t date, long job_id, char *out, size_t size)
{
    struct tm tm;
    char stamp[32];
    if (gmtime_r(&date, &tm) == NULL || strftime(stamp, sizeof(stamp), "%Y%m%d-%H%M%S", &tm) == 0)
        snprintf(stamp, sizeof(stamp), "19700101-000000");
    snprintf(out, size, "%s-%ld", stamp, job_id);
}

void lwb_journal_safe_name(const char *queue, char *out, size_t size)
{
    if (size == 0)
        return;
    size_t n = 0;
    const char *s = queue != NULL ? queue : "";
    for (; *s != '\0' && n + 1 < size; s++) {
        unsigned char c = (unsigned char)*s;
        bool bad = c < 0x20 || c == 0x7F || c == '/' || c == '\\' || (n == 0 && c == '.');
        out[n++] = bad ? '_' : (char)c;
    }
    out[n] = '\0';
    if (n == 0)
        snprintf(out, size, "unbekannt");
}

/* ------------------------------------------------------------------------------------------ */
/* Dateien                                                                                    */
/* ------------------------------------------------------------------------------------------ */

static void set_error(char *error, size_t size, const char *what, const char *path)
{
    if (error != NULL && size > 0)
        snprintf(error, size, "%s „%s“: %s", what, path, strerror(errno));
}

/* Legt einen Ordner an (0755, unabhängig von der umask); vorhandene bleiben unverändert. */
static int make_dir(const char *path)
{
    struct stat st;
    /* Vorhandene Ordner nicht anfassen (die Sandbox von cupsd verbietet Schreiben außerhalb von
     * /Users/Shared/ – auch ein mkdir auf /Users). */
    if (stat(path, &st) == 0 && S_ISDIR(st.st_mode))
        return 0;
    if (mkdir(path, 0755) == 0) {
        (void)chmod(path, 0755);
        return 0;
    }
    if (errno != EEXIST)
        return -1;
    if (stat(path, &st) != 0 || !S_ISDIR(st.st_mode)) {
        errno = ENOTDIR;
        return -1;
    }
    return 0;
}

/* Legt einen Pfad samt fehlender Elternordner an. */
static int make_dirs(const char *path)
{
    char buffer[1024];
    size_t len = strlen(path);
    if (len == 0 || len >= sizeof(buffer)) {
        errno = ENAMETOOLONG;
        return -1;
    }
    memcpy(buffer, path, len + 1);
    for (size_t k = 1; k < len; k++) {
        if (buffer[k] == '/') {
            buffer[k] = '\0';
            if (make_dir(buffer) != 0)
                return -1;
            buffer[k] = '/';
        }
    }
    return make_dir(buffer);
}

static int write_file(const char *path, const uint8_t *data, size_t len)
{
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0)
        return -1;
    (void)fchmod(fd, 0644);
    size_t done = 0;
    while (done < len) {
        ssize_t n = write(fd, data + done, len - done);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            int saved = errno;
            close(fd);
            errno = saved;
            return -1;
        }
        done += (size_t)n;
    }
    return close(fd);
}

/* Löscht einen Eintrag (nur Dateien darin, dann den Ordner). */
static int remove_entry(const char *path)
{
    DIR *dir = opendir(path);
    if (dir == NULL)
        return errno == ENOENT ? 0 : -1;
    struct dirent *item;
    char file[1024];
    while ((item = readdir(dir)) != NULL) {
        if (strcmp(item->d_name, ".") == 0 || strcmp(item->d_name, "..") == 0)
            continue;
        if ((size_t)snprintf(file, sizeof(file), "%s/%s", path, item->d_name) < sizeof(file))
            (void)unlink(file);
    }
    closedir(dir);
    return rmdir(path);
}

/* Summe der Dateigrößen eines Eintrags. */
static long long entry_size(const char *path)
{
    DIR *dir = opendir(path);
    if (dir == NULL)
        return 0;
    long long total = 0;
    struct dirent *item;
    char file[1024];
    struct stat st;
    while ((item = readdir(dir)) != NULL) {
        if (item->d_name[0] == '.')
            continue;
        if ((size_t)snprintf(file, sizeof(file), "%s/%s", path, item->d_name) < sizeof(file) &&
            stat(file, &st) == 0 && S_ISREG(st.st_mode))
            total += (long long)st.st_size;
    }
    closedir(dir);
    return total;
}

static int compare_names_descending(const void *a, const void *b)
{
    return strcmp(*(char *const *)b, *(char *const *)a);
}

int lwb_journal_prune(const char *queue_dir, int max_entries, long long max_bytes)
{
    DIR *dir = opendir(queue_dir);
    if (dir == NULL)
        return -1;
    char **names = NULL;
    size_t count = 0, capacity = 0;
    struct dirent *item;
    char path[1024];
    struct stat st;
    time_t now = time(NULL);
    while ((item = readdir(dir)) != NULL) {
        if ((size_t)snprintf(path, sizeof(path), "%s/%s", queue_dir, item->d_name) >= sizeof(path))
            continue;
        if (item->d_name[0] == '.') {
            /* Vorläufiger Eintrag eines abgebrochenen Backends. */
            size_t n = strlen(item->d_name);
            if (n > 5 && strcmp(item->d_name + n - 4, ".tmp") == 0 && lstat(path, &st) == 0 &&
                S_ISDIR(st.st_mode) && now - st.st_mtime > STALE_TEMP_SECONDS)
                (void)remove_entry(path);
            continue;
        }
        if (lstat(path, &st) != 0 || !S_ISDIR(st.st_mode))
            continue;
        if (count == capacity) {
            size_t grown = capacity == 0 ? 64 : capacity * 2;
            char **list = realloc(names, grown * sizeof(*list));
            if (list == NULL)
                break;
            names = list;
            capacity = grown;
        }
        names[count] = strdup(item->d_name);
        if (names[count] != NULL)
            count++;
    }
    closedir(dir);
    qsort(names, count, sizeof(*names), compare_names_descending);
    int removed = 0;
    long long total = 0;
    for (size_t k = 0; k < count; k++) {
        snprintf(path, sizeof(path), "%s/%s", queue_dir, names[k]);
        bool keep = (int)k < max_entries;
        if (keep) {
            long long size = entry_size(path);
            keep = k == 0 || total + size <= max_bytes;
            if (keep)
                total += size;
        }
        if (!keep && remove_entry(path) == 0)
            removed++;
        free(names[k]);
    }
    free(names);
    return removed;
}

int lwb_journal_write(const char *root, const lwb_journal_meta *meta, const uint8_t *data, size_t len,
                      lwb_prefixes prefixes, char *error, size_t error_size)
{
    if (error != NULL && error_size > 0)
        error[0] = '\0';
    char queue[256];
    lwb_journal_safe_name(meta->queue, queue, sizeof(queue));
    char queue_dir[1024];
    if ((size_t)snprintf(queue_dir, sizeof(queue_dir), "%s/%s", root, queue) >= sizeof(queue_dir)) {
        errno = ENAMETOOLONG;
        set_error(error, error_size, "Journalordner", root);
        return -1;
    }
    lwb_journal_scan_result scan;
    if (!lwb_journal_scan(data, len, prefixes, &scan)) {
        errno = ENOMEM;
        set_error(error, error_size, "Auftrag nicht zerlegbar", queue_dir);
        return -1;
    }
    if (scan.count == 0) {
        /* Nur Befehle (Kalibrieren, Einstellungen …): nichts zum Nachdrucken. */
        lwb_journal_scan_free(&scan);
        return 1;
    }
    lwb_journal_meta effective = *meta;
    if (effective.printed < 0) {
        long total = 0;
        for (size_t k = 0; k < scan.count; k++)
            total += scan.labels[k].quantity;
        effective.printed = total * (meta->copies < 1 ? 1 : meta->copies);
    }
    lw_buf json;
    lw_buf_init(&json);
    bool ok = lwb_journal_meta_json(&effective, &scan, &json);
    lwb_journal_scan_free(&scan);
    if (!ok) {
        lw_buf_free(&json);
        errno = ENOMEM;
        set_error(error, error_size, "meta.json", queue_dir);
        return -1;
    }

    if (make_dirs(queue_dir) != 0) {
        set_error(error, error_size, "Journalordner nicht anlegbar", queue_dir);
        lw_buf_free(&json);
        return -1;
    }
    char name[64];
    lwb_journal_entry_name(meta->date, meta->job_id, name, sizeof(name));
    char final_path[1200], temp_path[1200], file[1300];
    snprintf(final_path, sizeof(final_path), "%s/%s", queue_dir, name);
    /* Gleicher Name (Auftrag in derselben Sekunde erneut gedruckt): Zähler anhängen. */
    struct stat st;
    for (int suffix = 2; lstat(final_path, &st) == 0 && suffix < 100; suffix++)
        snprintf(final_path, sizeof(final_path), "%s/%s-%d", queue_dir, name, suffix);
    snprintf(temp_path, sizeof(temp_path), "%s/.%s-%ld.tmp", queue_dir, name, (long)getpid());
    (void)remove_entry(temp_path);
    int rc = -1;
    if (mkdir(temp_path, 0755) != 0) {
        set_error(error, error_size, "Journaleintrag nicht anlegbar", temp_path);
    } else {
        (void)chmod(temp_path, 0755);
        snprintf(file, sizeof(file), "%s/job.zpl", temp_path);
        if (write_file(file, data, len) != 0) {
            set_error(error, error_size, "Nicht schreibbar", file);
        } else {
            snprintf(file, sizeof(file), "%s/meta.json", temp_path);
            if (write_file(file, json.data, json.len) != 0)
                set_error(error, error_size, "Nicht schreibbar", file);
            else if (rename(temp_path, final_path) != 0)
                set_error(error, error_size, "Nicht umbenennbar", temp_path);
            else
                rc = 0;
        }
        if (rc != 0)
            (void)remove_entry(temp_path);
    }
    lw_buf_free(&json);
    if (rc == 0)
        (void)lwb_journal_prune(queue_dir, LWB_JOURNAL_MAX_ENTRIES, LWB_JOURNAL_MAX_BYTES);
    return rc;
}
