#include "ProcessSupport.h"
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static _Atomic int done = 0;
static void *reader(void *unused) {
    (void)unused;
    while (!atomic_load(&done))
        (void)sp_cancellation_number();
    return NULL;
}
struct child {
    pid_t pid;
    int status;
};
static void *waiter(void *value) {
    struct child *child = value;
    child->status = sp_child_wait(child->pid);
    return NULL;
}
static int registry(const char *directory) {
    int null = open("/dev/null", O_RDWR);
    if (null < 0)
        return 3;
    struct child children[8];
    pthread_t threads[8];
    int started = 0;
    int result = 0;
    char *const environment[] = {NULL};
    for (int i = 0; i < 8; ++i) {
        char label[16];
        snprintf(label, sizeof(label), "%d", i);
        char *const arguments[] = {"/bin/sh", "-c", "trap '' INT TERM; : > \"$1/ready-$2\"; /bin/sleep 5; exit 0",
                                   "fixture", (char *)directory, label, NULL};
        if (sp_child_spawn(arguments[0], arguments, environment, NULL, null, null, null, &children[i].pid) != 0) {
            result = 4;
            break;
        }
        if (pthread_create(&threads[i], NULL, waiter, &children[i]) != 0) {
            sp_child_terminate(children[i].pid);
            (void)sp_child_wait(children[i].pid);
            result = 5;
            break;
        }
        ++started;
    }
    int ready = 0;
    for (int attempt = 0; result == 0 && attempt < 300 && !ready; ++attempt) {
        ready = 1;
        for (int i = 0; i < 8; ++i) {
            char path[PATH_MAX];
            int length = snprintf(path, sizeof(path), "%s/ready-%d", directory, i);
            if (length < 0 || (size_t)length >= sizeof(path) || access(path, F_OK) != 0)
                ready = 0;
        }
        if (!ready)
            usleep(10000);
    }
    raise(SIGINT);
    if (result == 0 && !ready)
        result = 6;
    for (int i = 0; i < started; ++i) {
        pthread_join(threads[i], NULL);
        if (result == 0 && children[i].status != 128 + SIGINT)
            result = 7;
    }
    close(null);
    return result;
}
int main(int count, char **arguments) {
    if (count < 2 || sp_cancellation_begin() != 0)
        return 2;
    int result;
    if (strcmp(arguments[1], "reader") == 0) {
        pthread_t thread;
        if (pthread_create(&thread, NULL, reader, NULL) != 0) {
            sp_cancellation_end();
            return 3;
        }
        usleep(10000);
        for (int i = 0; i < 1000; ++i)
            raise(SIGINT);
        atomic_store(&done, 1);
        pthread_join(thread, NULL);
        result = sp_cancellation_number() == SIGINT ? 0 : 4;
    } else {
        if (count != 3) {
            sp_cancellation_end();
            return 3;
        }
        result = registry(arguments[2]);
    }
    sp_cancellation_end();
    if (result == 0)
        printf("passed=%s\n", arguments[1]);
    return result;
}
