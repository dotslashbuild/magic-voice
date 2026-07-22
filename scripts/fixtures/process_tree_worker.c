#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

static volatile sig_atomic_t received_signal = 0;

static void record_signal(int signal_number) {
    received_signal = signal_number;
}

static int write_text_file(const char *directory, const char *name, const char *text) {
    char path[4096];
    if (snprintf(path, sizeof(path), "%s/%s", directory, name) >= (int)sizeof(path)) {
        return -1;
    }
    int descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (descriptor == -1) {
        return -1;
    }
    size_t length = strlen(text);
    ssize_t written = write(descriptor, text, length);
    int saved_errno = errno;
    close(descriptor);
    errno = saved_errno;
    return written == (ssize_t)length ? 0 : -1;
}

static int write_pid_file(const char *directory, const char *name) {
    char pid_text[64];
    snprintf(pid_text, sizeof(pid_text), "%d\n", getpid());
    return write_text_file(directory, name, pid_text);
}

static void write_signal_marker(const char *directory, const char *role) {
    char marker_name[128];
    snprintf(marker_name, sizeof(marker_name), "signal.%s", role);
    char signal_text[64];
    snprintf(signal_text, sizeof(signal_text), "%d\n", received_signal);
    write_text_file(directory, marker_name, signal_text);
}

static int install_signal_recorder(void) {
    struct sigaction action = {0};
    action.sa_handler = record_signal;
    sigemptyset(&action.sa_mask);
    return sigaction(SIGTERM, &action, NULL);
}

static int run_cooperative(const char *directory) {
    if (install_signal_recorder() != 0
        || write_pid_file(directory, "worker.pid") != 0
        || write_text_file(directory, "ready", "ready\n") != 0) {
        return EXIT_FAILURE;
    }

    char line[256];
    while (true) {
        if (received_signal != 0) {
            write_signal_marker(directory, "worker");
            received_signal = 0;
        }
        errno = 0;
        if (fgets(line, sizeof(line), stdin) == NULL) {
            if (errno == EINTR) {
                clearerr(stdin);
                continue;
            }
            return EXIT_FAILURE;
        }
        if (strcmp(line, "{\"type\":\"shutdown\"}\n") == 0
            || strcmp(line, "{\"type\": \"shutdown\"}\n") == 0) {
            return write_text_file(directory, "graceful", "shutdown\n") == 0
                ? EXIT_SUCCESS
                : EXIT_FAILURE;
        }
    }
}

static int run_ignoring_term(const char *directory) {
    if (install_signal_recorder() != 0 || write_pid_file(directory, "worker.pid") != 0) {
        return EXIT_FAILURE;
    }

    pid_t grandchild = fork();
    if (grandchild == -1) {
        return EXIT_FAILURE;
    }
    if (grandchild == 0) {
        if (install_signal_recorder() != 0
            || write_pid_file(directory, "grandchild.pid") != 0) {
            _exit(EXIT_FAILURE);
        }
        while (true) {
            pause();
            if (received_signal != 0) {
                write_signal_marker(directory, "grandchild");
                received_signal = 0;
            }
        }
    }

    char grandchild_text[64];
    snprintf(grandchild_text, sizeof(grandchild_text), "%d\n", grandchild);
    if (write_text_file(directory, "spawned-grandchild.pid", grandchild_text) != 0
        || write_text_file(directory, "ready", "ready\n") != 0) {
        return EXIT_FAILURE;
    }

    while (true) {
        pause();
        if (received_signal != 0) {
            write_signal_marker(directory, "worker");
            received_signal = 0;
        }
    }
}

int main(int argc, char *argv[]) {
    if (argc != 3) {
        fprintf(stderr, "Usage: %s cooperative|ignore-term STATE_DIRECTORY\n", argv[0]);
        return 64;
    }
    if (strcmp(argv[1], "cooperative") == 0) {
        return run_cooperative(argv[2]);
    }
    if (strcmp(argv[1], "ignore-term") == 0) {
        return run_ignoring_term(argv[2]);
    }
    fprintf(stderr, "process tree fixture: unknown mode %s\n", argv[1]);
    return 64;
}
