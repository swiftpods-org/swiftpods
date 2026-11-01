#ifndef SWIFTPODS_C_LIBARCHIVE_SHIM_H
#define SWIFTPODS_C_LIBARCHIVE_SHIM_H

#include <stddef.h>
#include <stdint.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <stdlib.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

/*
 * Apple's SDK ships libarchive's stable ABI and manual pages, but not archive.h. Keep the declarations used by
 * SwiftPods in this SDK-portable shim instead of depending on Homebrew or an absolute host include path.
 */
struct archive;
struct archive_entry;

#define ARCHIVE_EOF 1
#define ARCHIVE_OK 0
#define ARCHIVE_FATAL -30

#define ARCHIVE_FORMAT_BASE_MASK 0xff0000
#define ARCHIVE_FORMAT_TAR 0x30000
#define ARCHIVE_FORMAT_ZIP 0x50000

struct archive *archive_read_new(void);
int archive_read_support_filter_none(struct archive *);
int archive_read_support_filter_gzip(struct archive *);
int archive_read_support_filter_bzip2(struct archive *);
int archive_read_support_filter_xz(struct archive *);
int archive_read_support_format_tar(struct archive *);
int archive_read_support_format_zip(struct archive *);
int archive_read_set_options(struct archive *, const char *);
typedef ssize_t archive_read_callback(struct archive *, void *, const void **);
typedef int archive_open_callback(struct archive *, void *);
typedef int archive_close_callback(struct archive *, void *);
typedef int64_t archive_seek_callback(struct archive *, void *, int64_t, int);
int archive_read_set_seek_callback(struct archive *, archive_seek_callback *);
int archive_read_open(
    struct archive *, void *, archive_open_callback *, archive_read_callback *, archive_close_callback *);
int archive_read_next_header(struct archive *, struct archive_entry **);
int archive_read_data_block(struct archive *, const void **, size_t *, int64_t *);
int archive_read_data_skip(struct archive *);
int archive_read_close(struct archive *);
int archive_read_free(struct archive *);
int archive_format(struct archive *);
const char *archive_error_string(struct archive *);
void archive_set_error(struct archive *, int, const char *, ...);

const char *archive_entry_pathname_utf8(struct archive_entry *);
const char *archive_entry_hardlink_utf8(struct archive_entry *);
const char *archive_entry_symlink_utf8(struct archive_entry *);
mode_t archive_entry_mode(struct archive_entry *);
mode_t archive_entry_perm(struct archive_entry *);
int archive_entry_size_is_set(struct archive_entry *);
int64_t archive_entry_size(struct archive_entry *);
int archive_entry_is_encrypted(struct archive_entry *);

/*
 * archive_read_open_fd() performs blocking reads internally, so a deadline checked only between headers cannot bound
 * inspection time. This callback keeps every read small, waits through poll(2) against a monotonic deadline, and uses
 * the caller's O_NONBLOCK descriptor. The context is explicitly owned by Swift and outlives archive_read_close().
 */
struct swiftpods_archive_read_context {
    int descriptor;
    int original_flags;
    uint64_t deadline_nanoseconds;
    unsigned char buffer[64 * 1024];
};

static inline uint64_t swiftpods_monotonic_nanoseconds(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC, &value) != 0 || value.tv_sec < 0 || value.tv_nsec < 0) {
        return UINT64_MAX;
    }
    uint64_t seconds = (uint64_t)value.tv_sec;
    if (seconds > (UINT64_MAX - (uint64_t)value.tv_nsec) / 1000000000ULL) {
        return UINT64_MAX;
    }
    return seconds * 1000000000ULL + (uint64_t)value.tv_nsec;
}

static inline struct swiftpods_archive_read_context *swiftpods_archive_read_context_create(
    int descriptor, uint64_t deadline_nanoseconds
) {
    struct swiftpods_archive_read_context *context =
        (struct swiftpods_archive_read_context *)malloc(sizeof(struct swiftpods_archive_read_context));
    if (context == NULL) {
        return NULL;
    }
    int flags = fcntl(descriptor, F_GETFL);
    if (flags < 0 || fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != 0) {
        int problem = errno;
        free(context);
        errno = problem;
        return NULL;
    }
    context->descriptor = descriptor;
    context->original_flags = flags;
    context->deadline_nanoseconds = deadline_nanoseconds;
    return context;
}

static inline void swiftpods_archive_read_context_destroy(struct swiftpods_archive_read_context *context) {
    if (context != NULL) {
        (void)fcntl(context->descriptor, F_SETFL, context->original_flags);
    }
    free(context);
}

static inline ssize_t swiftpods_archive_read_with_deadline(
    struct archive *reader, void *opaque_context, const void **buffer
) {
    struct swiftpods_archive_read_context *context =
        (struct swiftpods_archive_read_context *)opaque_context;
    if (context == NULL || buffer == NULL) {
        archive_set_error(reader, EINVAL, "invalid archive inspection reader");
        return -1;
    }

    for (;;) {
        uint64_t now = swiftpods_monotonic_nanoseconds();
        if (now == UINT64_MAX || now >= context->deadline_nanoseconds) {
            archive_set_error(reader, ETIMEDOUT, "archive inspection timed out");
            return -1;
        }
        uint64_t remaining = context->deadline_nanoseconds - now;
        uint64_t rounded_milliseconds = remaining / 1000000ULL + (remaining % 1000000ULL == 0 ? 0 : 1);
        int timeout = rounded_milliseconds > (uint64_t)INT_MAX ? INT_MAX : (int)rounded_milliseconds;
        struct pollfd readiness = { .fd = context->descriptor, .events = POLLIN, .revents = 0 };
        int poll_result = poll(&readiness, 1, timeout);
        if (poll_result == 0) {
            archive_set_error(reader, ETIMEDOUT, "archive inspection timed out");
            return -1;
        }
        if (poll_result < 0) {
            if (errno == EINTR) {
                continue;
            }
            archive_set_error(reader, errno, "cannot wait for archive inspection input");
            return -1;
        }
        if ((readiness.revents & (POLLERR | POLLNVAL)) != 0) {
            archive_set_error(reader, EIO, "archive inspection input failed");
            return -1;
        }

        ssize_t count = read(context->descriptor, context->buffer, sizeof(context->buffer));
        if (count >= 0) {
            *buffer = context->buffer;
            return count;
        }
        if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) {
            continue;
        }
        archive_set_error(reader, errno, "cannot read archive inspection input");
        return -1;
    }
}

static inline int64_t swiftpods_archive_seek_with_deadline(
    struct archive *reader, void *opaque_context, int64_t offset, int whence
) {
    struct swiftpods_archive_read_context *context =
        (struct swiftpods_archive_read_context *)opaque_context;
    if (context == NULL) {
        archive_set_error(reader, EINVAL, "invalid archive inspection seeker");
        return ARCHIVE_FATAL;
    }
    uint64_t now = swiftpods_monotonic_nanoseconds();
    if (now == UINT64_MAX || now >= context->deadline_nanoseconds) {
        archive_set_error(reader, ETIMEDOUT, "archive inspection timed out");
        return ARCHIVE_FATAL;
    }
    off_t result = lseek(context->descriptor, (off_t)offset, whence);
    if (result < 0) {
        archive_set_error(reader, errno, "cannot seek archive inspection input");
        return ARCHIVE_FATAL;
    }
    return (int64_t)result;
}

static inline int swiftpods_archive_read_open_with_deadline(
    struct archive *reader, struct swiftpods_archive_read_context *context
) {
    int seek_result = archive_read_set_seek_callback(reader, swiftpods_archive_seek_with_deadline);
    if (seek_result != ARCHIVE_OK) {
        return seek_result;
    }
    return archive_read_open(reader, context, NULL, swiftpods_archive_read_with_deadline, NULL);
}

/* Swift cannot import Darwin's variadic fcntl declaration for pointer-valued F_GETPATH. */
static inline int swiftpods_fgetpath(int descriptor, char *path) {
    return fcntl(descriptor, F_GETPATH, path);
}

#endif
