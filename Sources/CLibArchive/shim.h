#ifndef SWIFTPODS_C_LIBARCHIVE_SHIM_H
#define SWIFTPODS_C_LIBARCHIVE_SHIM_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

/*
 * Apple's SDK ships libarchive's stable ABI but not archive.h. These are the declarations SwiftPods uses.
 */
struct archive;
struct archive_entry;

#define ARCHIVE_EOF 1
#define ARCHIVE_OK 0
#define ARCHIVE_WARN (-20)

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
int archive_read_open_filename(struct archive *, const char *, size_t);
int archive_read_next_header(struct archive *, struct archive_entry **);
ssize_t archive_read_data(struct archive *, void *, size_t);
int archive_read_data_skip(struct archive *);
int archive_read_close(struct archive *);
int archive_read_free(struct archive *);
int archive_format(struct archive *);
const char *archive_error_string(struct archive *);

const char *archive_entry_pathname_utf8(struct archive_entry *);
const char *archive_entry_hardlink_utf8(struct archive_entry *);
const char *archive_entry_symlink_utf8(struct archive_entry *);
mode_t archive_entry_filetype(struct archive_entry *);
mode_t archive_entry_perm(struct archive_entry *);
int archive_entry_is_encrypted(struct archive_entry *);

#endif
