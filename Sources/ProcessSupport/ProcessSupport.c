#include "ProcessSupport.h"
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stdatomic.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define SP_CHILDREN 512
static volatile sig_atomic_t children[SP_CHILDREN];
static volatile sig_atomic_t cancellation = 0;
static pthread_mutex_t child_mutex = PTHREAD_MUTEX_INITIALIZER;
static struct sigaction previous_int, previous_term, previous_pipe;
static _Atomic int monitoring = 0;
static pthread_t monitor_thread;

static void signal_children(int number) {
    for (int i = 0; i < SP_CHILDREN; ++i) {
        pid_t pid = (pid_t)children[i];
        if (pid > 0)
            kill(-pid, number);
    }
}
static void forward_signal(int number) {
    cancellation = number;
    signal_children(number);
}
static double elapsed(struct timespec start, struct timespec now) {
    return (double)(now.tv_sec - start.tv_sec) + (double)(now.tv_nsec - start.tv_nsec) / 1000000000.0;
}
static void *monitor(void *unused) {
    (void)unused;
    struct timespec start = {0};
    while (atomic_load(&monitoring)) {
        if (cancellation != 0) {
            struct timespec now;
            clock_gettime(CLOCK_MONOTONIC, &now);
            if (start.tv_sec == 0)
                start = now;
            double seconds = elapsed(start, now);
            if (seconds >= 2.0)
                signal_children(SIGKILL);
            else if (seconds >= 1.0)
                signal_children(SIGTERM);
        }
        struct timespec interval = {.tv_sec = 0, .tv_nsec = 20000000};
        nanosleep(&interval, NULL);
    }
    return NULL;
}
int sp_cancellation_begin(void) {
    cancellation = 0;
    struct sigaction handler = {0};
    handler.sa_handler = forward_signal;
    sigemptyset(&handler.sa_mask);
    if (sigaction(SIGINT, &handler, &previous_int) != 0)
        return errno;
    if (sigaction(SIGTERM, &handler, &previous_term) != 0) {
        int error = errno;
        sigaction(SIGINT, &previous_int, NULL);
        return error;
    }
    struct sigaction ignored = {0};
    ignored.sa_handler = SIG_IGN;
    sigemptyset(&ignored.sa_mask);
    if (sigaction(SIGPIPE, &ignored, &previous_pipe) != 0) {
        int error = errno;
        sigaction(SIGINT, &previous_int, NULL);
        sigaction(SIGTERM, &previous_term, NULL);
        return error;
    }
    atomic_store(&monitoring, 1);
    int error = pthread_create(&monitor_thread, NULL, monitor, NULL);
    if (error != 0) {
        atomic_store(&monitoring, 0);
        sigaction(SIGINT, &previous_int, NULL);
        sigaction(SIGTERM, &previous_term, NULL);
        sigaction(SIGPIPE, &previous_pipe, NULL);
    }
    return error;
}
void sp_cancellation_end(void) {
    atomic_store(&monitoring, 0);
    pthread_join(monitor_thread, NULL);
    sigaction(SIGINT, &previous_int, NULL);
    sigaction(SIGTERM, &previous_term, NULL);
    sigaction(SIGPIPE, &previous_pipe, NULL);
}
int sp_cancellation_number(void) { return (int)cancellation; }

int sp_child_spawn(const char *executable, char *const argv[], char *const envp[], const char *directory, int input,
                   int output, int error, pid_t *pid) {
    if (cancellation != 0)
        return ECANCELED;
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    int result = posix_spawn_file_actions_init(&actions);
    if (result != 0)
        return result;
    result = posix_spawnattr_init(&attributes);
    if (result != 0) {
        posix_spawn_file_actions_destroy(&actions);
        return result;
    }
    sigset_t defaults, mask;
    sigemptyset(&defaults);
    sigaddset(&defaults, SIGINT);
    sigaddset(&defaults, SIGTERM);
    sigaddset(&defaults, SIGPIPE);
    sigemptyset(&mask);
    short flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT;
#define SP_ACTION(call)                                                                                                \
    do {                                                                                                               \
        if (result == 0)                                                                                               \
            result = (call);                                                                                           \
    } while (0)
    SP_ACTION(posix_spawnattr_setflags(&attributes, flags));
    SP_ACTION(posix_spawnattr_setpgroup(&attributes, 0));
    SP_ACTION(posix_spawnattr_setsigdefault(&attributes, &defaults));
    SP_ACTION(posix_spawnattr_setsigmask(&attributes, &mask));
    if (directory != NULL)
        SP_ACTION(posix_spawn_file_actions_addchdir_np(&actions, directory));
    SP_ACTION(posix_spawn_file_actions_adddup2(&actions, input, STDIN_FILENO));
    SP_ACTION(posix_spawn_file_actions_adddup2(&actions, output, STDOUT_FILENO));
    SP_ACTION(posix_spawn_file_actions_adddup2(&actions, error, STDERR_FILENO));
    pthread_mutex_lock(&child_mutex);
    int slot = -1;
    for (int i = 0; i < SP_CHILDREN; ++i)
        if (children[i] == 0) {
            slot = i;
            break;
        }
    if (slot < 0 && result == 0)
        result = EAGAIN;
    if (result == 0)
        result = posix_spawn(pid, executable, &actions, &attributes, argv, envp);
    if (result == 0) {
        children[slot] = (sig_atomic_t)*pid;
        if (cancellation != 0)
            kill(-*pid, cancellation);
    }
    pthread_mutex_unlock(&child_mutex);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attributes);
    return result;
#undef SP_ACTION
}
int sp_child_wait(pid_t pid) {
    int status = 0;
    pid_t result;
    do {
        result = waitpid(pid, &status, 0);
    } while (result == -1 && errno == EINTR);
    /* A helper must not leave descendants holding its output pipes open. */
    kill(-pid, SIGKILL);
    pthread_mutex_lock(&child_mutex);
    for (int i = 0; i < SP_CHILDREN; ++i)
        if (children[i] == pid)
            children[i] = 0;
    pthread_mutex_unlock(&child_mutex);
    if (cancellation != 0)
        return 128 + cancellation;
    if (result == -1)
        return 125;
    return WIFSIGNALED(status) ? 128 + WTERMSIG(status) : WEXITSTATUS(status);
}
void sp_child_terminate(pid_t pid) {
    kill(-pid, SIGTERM);
    struct timespec start, now;
    clock_gettime(CLOCK_MONOTONIC, &start);
    for (;;) {
        if (kill(pid, 0) != 0 && errno == ESRCH)
            return;
        clock_gettime(CLOCK_MONOTONIC, &now);
        if (elapsed(start, now) >= 0.25) {
            kill(-pid, SIGKILL);
            return;
        }
        struct timespec interval = {.tv_sec = 0, .tv_nsec = 10000000};
        nanosleep(&interval, NULL);
    }
}
