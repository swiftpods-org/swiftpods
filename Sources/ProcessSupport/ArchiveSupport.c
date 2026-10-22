#include "ArchiveHeaders/archive.h"
#include "ArchiveHeaders/archive_entry.h"
#include "ProcessSupport.h"
#include <CoreFoundation/CoreFoundation.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Accept relative paths whose normalized traversal stays within the archive.
   Hard links are relative to the root; symbolic links to their parent. */
static int path_depth(const char *path, int depth) {
    if (!path || path[0] == '/' || path[0] == '\\')
        return -1;
    const char *cursor = path;
    while (*cursor) {
        const char *end = strchr(cursor, '/');
        size_t length = end ? (size_t)(end - cursor) : strlen(cursor);
        if (memchr(cursor, '\\', length))
            return -1;
        if (length == 2 && cursor[0] == '.' && cursor[1] == '.') {
            if (--depth < 0)
                return -1;
        } else if (length && !(length == 1 && cursor[0] == '.')) {
            depth++;
        }
        if (!end)
            break;
        cursor = end + 1;
    }
    return depth;
}

typedef struct {
    char *name;
    char *target;
    int hardlink;
} entry_path;

/* Compare paths as they can alias on macOS volumes. Preserve traversal
   components: lexical normalization before following links would hide escapes. */
static char *filesystem_key(const char *path) {
    CFStringRef input = CFStringCreateWithCString(kCFAllocatorDefault, path, kCFStringEncodingUTF8);
    if (!input)
        return NULL;
    CFMutableStringRef key = CFStringCreateMutableCopy(kCFAllocatorDefault, 0, input);
    CFRelease(input);
    if (!key)
        return NULL;
    CFLocaleRef locale = CFLocaleCreate(kCFAllocatorDefault, CFSTR("en_US_POSIX"));
    if (!locale) {
        CFRelease(key);
        return NULL;
    }
    CFStringNormalize(key, kCFStringNormalizationFormD);
    CFStringFold(key, kCFCompareCaseInsensitive, locale);
    CFStringNormalize(key, kCFStringNormalizationFormD);
    CFRelease(locale);
    CFIndex maximum = CFStringGetMaximumSizeForEncoding(CFStringGetLength(key), kCFStringEncodingUTF8);
    char *result = maximum < 0 || maximum == LONG_MAX ? NULL : malloc((size_t)maximum + 1);
    if (result && !CFStringGetCString(key, result, maximum + 1, kCFStringEncodingUTF8)) {
        free(result);
        result = NULL;
    }
    CFRelease(key);
    return result;
}

static char *normalized_name(const char *name) {
    char *copy = strdup(name), *result = calloc(strlen(name) + 1, 1), *state = NULL;
    if (!copy || !result) {
        free(copy);
        free(result);
        return NULL;
    }
    for (char *part = strtok_r(copy, "/", &state); part; part = strtok_r(NULL, "/", &state)) {
        /* Parent components in entry names interact with earlier symlinks in
           extraction order. Canonical relative archive names need none. */
        if (!strcmp(part, "..")) {
            free(copy);
            free(result);
            return NULL;
        }
        if (!strcmp(part, "."))
            continue;
        if (*result)
            strcat(result, "/");
        strcat(result, part);
    }
    free(copy);
    char *key = filesystem_key(result);
    free(result);
    return key;
}

static int resolves_inside(const char *input, const entry_path *entries, size_t count, int follow_final_symlink) {
    char *pending = strdup(input);
    if (!pending)
        return 0;
    for (int redirects = 0; redirects <= 64; redirects++) {
        char *resolved = calloc(strlen(pending) + 1, 1), *state = NULL;
        if (!resolved) {
            free(pending);
            return 0;
        }
        int restart = 0;
        for (char *part = strtok_r(pending, "/", &state); part; part = strtok_r(NULL, "/", &state)) {
            if (!strcmp(part, "."))
                continue;
            if (!strcmp(part, "..")) {
                if (!*resolved) {
                    free(resolved);
                    free(pending);
                    return 0;
                }
                char *slash = strrchr(resolved, '/');
                if (slash)
                    *slash = '\0';
                else
                    *resolved = '\0';
                continue;
            }
            if (*resolved)
                strcat(resolved, "/");
            strcat(resolved, part);
            for (size_t index = 0; index < count; index++) {
                if (!entries[index].target || strcmp(entries[index].name, resolved))
                    continue;
                if (!entries[index].hardlink) {
                    /* A hardlink preserves a final symlink's inode. Its relative
                       target would then be interpreted from a different parent. */
                    if (!follow_final_symlink && (!state || !*state)) {
                        free(resolved);
                        free(pending);
                        return 0;
                    }
                    char *slash = strrchr(resolved, '/');
                    if (slash)
                        *slash = '\0';
                    else
                        *resolved = '\0';
                } else
                    *resolved = '\0';
                size_t size = strlen(resolved) + strlen(entries[index].target) + strlen(state ? state : "") + 3;
                char *replacement = malloc(size);
                if (!replacement) {
                    free(resolved);
                    free(pending);
                    return 0;
                }
                snprintf(replacement, size, "%s%s%s/%s", resolved, *resolved ? "/" : "", entries[index].target,
                         state ? state : "");
                free(pending);
                pending = replacement;
                restart = 1;
                break;
            }
            if (restart)
                break;
        }
        free(resolved);
        if (!restart) {
            free(pending);
            return 1;
        }
    }
    free(pending);
    return 0; /* cyclic or excessively deep links */
}

int sp_validate_archive(const char *path, char *message, size_t capacity) {
    struct archive *reader = archive_read_new();
    if (!reader) {
        snprintf(message, capacity, "Cannot allocate archive reader");
        return 1;
    }
    archive_read_support_filter_all(reader);
    archive_read_support_format_all(reader);
    int status = archive_read_open_filename(reader, path, 10240);
    struct archive_entry *entry = NULL;
    entry_path *entries = NULL;
    size_t count = 0;
    int failed = 0;
    while (status == ARCHIVE_OK && (status = archive_read_next_header(reader, &entry)) == ARCHIVE_OK) {
        const char *name = archive_entry_pathname(entry);
        const char *symlink = archive_entry_symlink(entry);
        const char *hardlink = archive_entry_hardlink(entry);
        mode_t type = archive_entry_filetype(entry);
        int depth = path_depth(name, 0);
        if (depth < 0 || (symlink && hardlink) || (type == AE_IFLNK && !symlink) ||
            (symlink && (!*symlink || path_depth(symlink, depth > 0 ? depth - 1 : 0) < 0)) ||
            (hardlink && (!*hardlink || path_depth(hardlink, 0) < 0)) ||
            (type != AE_IFREG && type != AE_IFDIR && type != AE_IFLNK && !hardlink)) {
            snprintf(message, capacity, "Archive contains an escaping path, unsafe link or special file: %s",
                     name ? name : "(missing)");
            failed = 1;
            break;
        }
        entry_path *grown = realloc(entries, (count + 1) * sizeof(*entries));
        if (!grown) {
            snprintf(message, capacity, "Cannot allocate archive metadata");
            failed = 1;
            break;
        }
        entries = grown;
        entries[count].name = normalized_name(name);
        entries[count].target = (symlink || hardlink) ? filesystem_key(symlink ? symlink : hardlink) : NULL;
        entries[count].hardlink = hardlink != NULL;
        count++;
        if (!entries[count - 1].name ||
            ((symlink || hardlink) && (!entries[count - 1].target || !*entries[count - 1].name))) {
            snprintf(message, capacity, "Archive entry has parent path components or invalid metadata: %s", name);
            failed = 1;
            break;
        }
        status = archive_read_data_skip(reader);
    }
    if (!failed && status != ARCHIVE_EOF) {
        const char *error = archive_error_string(reader);
        snprintf(message, capacity, "Cannot validate archive: %s", error ? error : "invalid archive");
        failed = 1;
    }
    archive_read_free(reader);
    for (size_t link = 0; !failed && link < count; link++) {
        if (!entries[link].target)
            continue;
        for (size_t index = 0; index < count; index++) {
            size_t length = strlen(entries[link].name);
            if (!strcmp(entries[index].name, entries[link].name) &&
                (!entries[index].target || entries[index].hardlink != entries[link].hardlink ||
                 strcmp(entries[index].target, entries[link].target))) {
                snprintf(message, capacity, "Archive has conflicting link entries: %s", entries[link].name);
                failed = 1;
                break;
            }
            if (!strncmp(entries[index].name, entries[link].name, length) && entries[index].name[length] == '/') {
                snprintf(message, capacity, "Archive writes through a link ancestor: %s", entries[index].name);
                failed = 1;
                break;
            }
        }
        if (!failed && !resolves_inside(entries[link].name, entries, count, !entries[link].hardlink)) {
            snprintf(message, capacity, "Archive link chain escapes its root, cycles or hardlinks a symlink: %s",
                     entries[link].name);
            failed = 1;
        }
    }
    for (size_t index = 0; index < count; index++) {
        free(entries[index].name);
        free(entries[index].target);
    }
    free(entries);
    return failed;
}
