#include "ProcessSupport.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <unistd.h>

/* Exercise a permitted kill failure without changing process ownership. */
int fixture_kill(pid_t pid, int number) {
    (void)pid;
    (void)number;
    errno = ESRCH;
    return -1;
}
int main(int count, char **arguments) {
    (void)arguments;
    if (sp_cancellation_begin() != 0)
        return 2;
    pid_t child = 0;
    int null = -1;
    if (count > 1) {
        null = open("/dev/null", O_RDWR);
        char *const argv[] = {"/bin/sleep", ".1", NULL};
        char *const envp[] = {NULL};
        if (null < 0 || sp_child_spawn(argv[0], argv, envp, NULL, null, null, null, &child) != 0)
            return 3;
    }
    errno = EDOM;
    int result = raise(SIGINT);
    int observed = errno;
    if (child != 0)
        (void)sp_child_wait(child);
    sp_cancellation_end();
    if (null >= 0)
        close(null);
    printf("raise=%d errno=%d expected=%d\n", result, observed, EDOM);
    return result == 0 && observed == EDOM ? 0 : 4;
}
