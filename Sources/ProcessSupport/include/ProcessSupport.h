#ifndef SWIFTPODS_PROCESS_SUPPORT_H
#define SWIFTPODS_PROCESS_SUPPORT_H
#include <sys/types.h>
#include <stddef.h>

int sp_validate_archive(const char *path, char *message, size_t capacity);

int sp_cancellation_begin(void);
void sp_cancellation_end(void);
int sp_cancellation_number(void);
int sp_child_spawn(const char *executable, char *const argv[], char *const envp[],
                   const char *directory, int input, int output, int error, pid_t *pid);
int sp_child_wait(pid_t pid);
void sp_child_terminate(pid_t pid);
#endif
