#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/event.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

static const int termination_grace_milliseconds = 3000;
static const int kill_settle_milliseconds = 750;
static volatile sig_atomic_t termination_signal = 0;

static void record_termination_signal(int signal_number) {
    termination_signal = signal_number;
}

static void print_usage(const char *program_name) {
    fprintf(stderr, "Usage: %s --parent-pid PID -- /absolute/executable [arguments...]\n", program_name);
}

static bool parse_pid(const char *value, pid_t *result) {
    char *end = NULL;
    errno = 0;
    long parsed = strtol(value, &end, 10);
    if (errno != 0 || end == value || *end != '\0' || parsed <= 1 || parsed > INT32_MAX) {
        return false;
    }
    *result = (pid_t)parsed;
    return true;
}

static int64_t monotonic_milliseconds(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
        return 0;
    }
    return ((int64_t)now.tv_sec * 1000) + (now.tv_nsec / 1000000);
}

static bool process_group_exists(pid_t process_group) {
    if (kill(-process_group, 0) == 0) {
        return true;
    }
    return errno == EPERM;
}

static void reap_child_if_exited(pid_t child_pid, int *status, bool *reaped) {
    if (*reaped) {
        return;
    }

    pid_t result;
    do {
        result = waitpid(child_pid, status, WNOHANG);
    } while (result == -1 && errno == EINTR);

    if (result == child_pid || (result == -1 && errno == ECHILD)) {
        *reaped = true;
    }
}

static void wait_for_group_exit(
    pid_t process_group,
    pid_t child_pid,
    int timeout_milliseconds,
    int *child_status,
    bool *child_reaped
) {
    int64_t deadline = monotonic_milliseconds() + timeout_milliseconds;
    while (process_group_exists(process_group) && monotonic_milliseconds() < deadline) {
        reap_child_if_exited(child_pid, child_status, child_reaped);
        struct timespec interval = { .tv_sec = 0, .tv_nsec = 20 * 1000 * 1000 };
        nanosleep(&interval, NULL);
    }
    reap_child_if_exited(child_pid, child_status, child_reaped);
}

static void terminate_process_group(
    pid_t process_group,
    pid_t child_pid,
    int *child_status,
    bool *child_reaped
) {
    if (process_group_exists(process_group)) {
        if (kill(-process_group, SIGTERM) == -1 && errno != ESRCH) {
            fprintf(stderr, "process supervisor: SIGTERM failed: %s\n", strerror(errno));
        }
    }

    wait_for_group_exit(
        process_group,
        child_pid,
        termination_grace_milliseconds,
        child_status,
        child_reaped
    );

    if (process_group_exists(process_group)) {
        if (kill(-process_group, SIGKILL) == -1 && errno != ESRCH) {
            fprintf(stderr, "process supervisor: SIGKILL failed: %s\n", strerror(errno));
        }
        wait_for_group_exit(
            process_group,
            child_pid,
            kill_settle_milliseconds,
            child_status,
            child_reaped
        );
    }
}

static int exit_code_for_child_status(int status, bool child_reaped) {
    if (!child_reaped) {
        return EXIT_FAILURE;
    }
    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    }
    if (WIFSIGNALED(status)) {
        return 128 + WTERMSIG(status);
    }
    return EXIT_FAILURE;
}

int main(int argc, char *argv[]) {
    if (argc < 5 || strcmp(argv[1], "--parent-pid") != 0 || strcmp(argv[3], "--") != 0) {
        print_usage(argv[0]);
        return 64;
    }

    pid_t parent_pid;
    if (!parse_pid(argv[2], &parent_pid)) {
        fprintf(stderr, "process supervisor: invalid parent PID\n");
        return 64;
    }
    if (argv[4][0] != '/') {
        fprintf(stderr, "process supervisor: executable path must be absolute\n");
        return 64;
    }
    if (getppid() != parent_pid) {
        fprintf(stderr, "process supervisor: parent PID does not match direct parent\n");
        return 69;
    }

    struct sigaction action = {0};
    action.sa_handler = record_termination_signal;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGTERM, &action, NULL) != 0
        || sigaction(SIGINT, &action, NULL) != 0
        || sigaction(SIGHUP, &action, NULL) != 0) {
        fprintf(stderr, "process supervisor: could not install signal handlers: %s\n", strerror(errno));
        return 71;
    }

    int event_queue = kqueue();
    if (event_queue == -1) {
        fprintf(stderr, "process supervisor: kqueue failed: %s\n", strerror(errno));
        return 71;
    }
    fcntl(event_queue, F_SETFD, FD_CLOEXEC);

    struct kevent parent_event;
    EV_SET(
        &parent_event,
        (uintptr_t)parent_pid,
        EVFILT_PROC,
        EV_ADD | EV_ENABLE | EV_ONESHOT,
        NOTE_EXIT,
        0,
        NULL
    );
    if (kevent(event_queue, &parent_event, 1, NULL, 0, NULL) == -1) {
        fprintf(stderr, "process supervisor: could not watch parent PID %d: %s\n", parent_pid, strerror(errno));
        close(event_queue);
        return 69;
    }
    if (getppid() != parent_pid) {
        fprintf(stderr, "process supervisor: direct parent exited before worker launch\n");
        close(event_queue);
        return 69;
    }

    posix_spawnattr_t attributes;
    if (posix_spawnattr_init(&attributes) != 0) {
        fprintf(stderr, "process supervisor: could not initialize spawn attributes\n");
        close(event_queue);
        return 71;
    }

    sigset_t default_signals;
    sigemptyset(&default_signals);
    sigaddset(&default_signals, SIGTERM);
    sigaddset(&default_signals, SIGINT);
    sigaddset(&default_signals, SIGHUP);
    sigset_t child_signal_mask;
    sigemptyset(&child_signal_mask);

    short spawn_flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK;
    int configuration_error = posix_spawnattr_setflags(&attributes, spawn_flags);
    if (configuration_error == 0) {
        configuration_error = posix_spawnattr_setpgroup(&attributes, 0);
    }
    if (configuration_error == 0) {
        configuration_error = posix_spawnattr_setsigdefault(&attributes, &default_signals);
    }
    if (configuration_error == 0) {
        configuration_error = posix_spawnattr_setsigmask(&attributes, &child_signal_mask);
    }
    if (configuration_error != 0) {
        fprintf(stderr, "process supervisor: could not configure child process group: %s\n", strerror(configuration_error));
        posix_spawnattr_destroy(&attributes);
        close(event_queue);
        return 71;
    }

    pid_t child_pid = 0;
    int spawn_error = posix_spawn(&child_pid, argv[4], NULL, &attributes, &argv[4], environ);
    posix_spawnattr_destroy(&attributes);
    if (spawn_error != 0) {
        fprintf(stderr, "process supervisor: could not launch %s: %s\n", argv[4], strerror(spawn_error));
        close(event_queue);
        return 69;
    }

    struct kevent child_event;
    EV_SET(
        &child_event,
        (uintptr_t)child_pid,
        EVFILT_PROC,
        EV_ADD | EV_ENABLE | EV_ONESHOT,
        NOTE_EXIT,
        0,
        NULL
    );
    if (kevent(event_queue, &child_event, 1, NULL, 0, NULL) == -1) {
        fprintf(stderr, "process supervisor: could not watch child PID %d: %s\n", child_pid, strerror(errno));
        int child_status = 0;
        bool child_reaped = false;
        terminate_process_group(child_pid, child_pid, &child_status, &child_reaped);
        close(event_queue);
        return 71;
    }

    int child_status = 0;
    bool child_reaped = false;
    bool parent_died = false;
    bool child_exited = false;

    while (!parent_died && !child_exited && termination_signal == 0) {
        struct kevent events[2];
        struct timespec timeout = { .tv_sec = 0, .tv_nsec = 100 * 1000 * 1000 };
        int event_count = kevent(event_queue, NULL, 0, events, 2, &timeout);
        if (event_count == -1) {
            if (errno == EINTR) {
                continue;
            }
            fprintf(stderr, "process supervisor: event wait failed: %s\n", strerror(errno));
            termination_signal = SIGTERM;
            break;
        }
        for (int index = 0; index < event_count; index++) {
            if (events[index].filter != EVFILT_PROC) {
                continue;
            }
            if ((pid_t)events[index].ident == parent_pid) {
                parent_died = true;
            } else if ((pid_t)events[index].ident == child_pid) {
                child_exited = true;
            }
        }
    }

    if (parent_died || termination_signal != 0) {
        terminate_process_group(child_pid, child_pid, &child_status, &child_reaped);
    } else {
        reap_child_if_exited(child_pid, &child_status, &child_reaped);
        if (process_group_exists(child_pid)) {
            terminate_process_group(child_pid, child_pid, &child_status, &child_reaped);
        }
    }

    if (!child_reaped) {
        pid_t wait_result;
        do {
            wait_result = waitpid(child_pid, &child_status, 0);
        } while (wait_result == -1 && errno == EINTR);
        child_reaped = wait_result == child_pid;
    }

    close(event_queue);
    if (parent_died) {
        return EXIT_SUCCESS;
    }
    if (termination_signal != 0) {
        return 128 + termination_signal;
    }
    return exit_code_for_child_status(child_status, child_reaped);
}
