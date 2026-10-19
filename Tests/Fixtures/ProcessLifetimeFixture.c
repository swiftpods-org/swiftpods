#include "ProcessSupport.h"
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

static pid_t target;
static _Atomic int released_signals, owned_signals, gated, entered, release_gate, waited;
static int (*system_kill)(pid_t, int);
struct wait_result { int status; };

int fixture_kill(pid_t group, int number) {
    if (group == -target) {
        if (atomic_exchange(&gated, 0)) {
            atomic_store(&entered, 1);
            while (!atomic_load(&release_gate)) {}
        }
        siginfo_t information = {0};
        int result;
        do {
            result = waitid(P_PID, (id_t)target, &information, WEXITED | WNOWAIT | WNOHANG);
        } while (result == -1 && errno == EINTR);
        if (result == -1 && errno == ECHILD)
            atomic_fetch_add(&released_signals, 1);
        else
            atomic_fetch_add(&owned_signals, 1);
    }
    return system_kill(group, number);
}
static void *cancel(void *unused) {
    (void)unused;
    raise(SIGINT);
    return NULL;
}
static void *terminate(void *unused) {
    (void)unused;
    sp_child_terminate(target);
    return NULL;
}
static void *waiter(void *value) {
    struct wait_result *result = value;
    result->status = sp_child_wait(target);
    atomic_fetch_add(&waited, 1);
    return NULL;
}
static int await_gate(void) {
    for (int i = 0; i < 1000; ++i) {
        if (atomic_load(&entered))
            return 1;
        usleep(1000);
    }
    return 0;
}
int main(int count, char **arguments) {
    system_kill = (int (*)(pid_t, int))dlsym(RTLD_DEFAULT, "kill");
    if (count != 2 || system_kill == NULL)
        return 2;
    const char *mode = arguments[1];
    int self_wait = strcmp(mode, "self-wait") == 0;
    int self_terminate = strcmp(mode, "self-terminate") == 0;
    int pending = strcmp(mode, "pending") == 0;
    int terminating = strcmp(mode, "terminate") == 0;
    int failed = strcmp(mode, "failed-wait") == 0;
    int concurrent = strcmp(mode, "concurrent-wait") == 0;
    int duplicate = strcmp(mode, "duplicate-wait") == 0;
    int null = -1, status = 0, second = -1, held = -1, completed = -1, reaped = -1;
    if (self_wait || self_terminate) {
        if (getpgrp() != getpid())
            return 3;
        target = getpid();
        if (self_wait)
            status = sp_child_wait(target);
        else
            sp_child_terminate(target);
    } else {
        if (pending && sp_cancellation_begin() != 0)
            return 4;
        if (failed)
            signal(SIGCHLD, SIG_IGN);
        null = open("/dev/null", O_RDWR);
        char *const fast[] = {"/usr/bin/true", NULL};
        char *const slow[] = {"/bin/sleep", terminating ? "5" : ".05", NULL};
        char *const envp[] = {NULL};
        char *const *argv = terminating || concurrent ? slow : fast;
        if (null < 0 || sp_child_spawn(argv[0], argv, envp, NULL, null, null, null, &target) != 0)
            return 5;
        if (pending || terminating) {
            siginfo_t information = {0};
            if (pending && waitid(P_PID, (id_t)target, &information, WEXITED | WNOWAIT) != 0)
                return 6;
            atomic_store(&gated, 1);
            pthread_t sender, waiting;
            if (pthread_create(&sender, NULL, pending ? cancel : terminate, NULL) != 0)
                return 7;
            if (!await_gate()) {
                atomic_store(&release_gate, 1);
                pthread_join(sender, NULL);
                return 8;
            }
            struct wait_result result;
            if (pthread_create(&waiting, NULL, waiter, &result) != 0) {
                atomic_store(&release_gate, 1);
                pthread_join(sender, NULL);
                return 9;
            }
            usleep(50000);
            int before = waitid(P_PID, (id_t)target, &information, WEXITED | WNOWAIT | WNOHANG);
            held = before == 0;
            completed = atomic_load(&waited);
            atomic_store(&release_gate, 1);
            pthread_join(sender, NULL);
            pthread_join(waiting, NULL);
            status = result.status;
        } else if (concurrent) {
            pthread_t threads[2];
            struct wait_result results[2];
            for (int i = 0; i < 2; ++i)
                if (pthread_create(&threads[i], NULL, waiter, &results[i]) != 0)
                    return 10;
            for (int i = 0; i < 2; ++i)
                pthread_join(threads[i], NULL);
            status = results[0].status < results[1].status ? results[0].status : results[1].status;
            second = results[0].status > results[1].status ? results[0].status : results[1].status;
        } else {
            status = sp_child_wait(target);
            if (duplicate)
                second = sp_child_wait(target);
        }
        siginfo_t information = {0};
        reaped = waitid(P_PID, (id_t)target, &information, WEXITED | WNOWAIT | WNOHANG) == -1 && errno == ECHILD;
        if (pending)
            sp_cancellation_end();
        if (failed)
            signal(SIGCHLD, SIG_DFL);
    }
    if (null >= 0)
        close(null);
    printf("{\"mode\":\"%s\",\"status\":%d,\"second_status\":%d,\"held\":%d,\"completed_early\":%d,\"reaped\":%d,\"released_signals\":%d,\"owned_signals\":%d}\n",
           mode, status, second, held, completed, reaped, atomic_load(&released_signals), atomic_load(&owned_signals));
    int expected = self_wait || failed ? 125 : pending ? 130 : terminating ? 143 : 0;
    int valid = status == expected && atomic_load(&released_signals) == 0;
    if (!self_wait && !self_terminate)
        valid = valid && reaped;
    if (pending || terminating)
        valid = valid && held && completed == 0;
    if (duplicate || concurrent)
        valid = valid && second == 125;
    return valid ? 0 : 11;
}
