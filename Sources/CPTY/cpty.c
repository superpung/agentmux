#include "cpty.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <util.h>

pid_t agentmux_spawn_pty(const char *path,
                         char *const argv[],
                         char *const envp[],
                         unsigned short columns,
                         unsigned short rows,
                         int *master_fd) {
    struct winsize ws = {.ws_row = rows, .ws_col = columns};
    int fd = -1;
    pid_t pid = forkpty(&fd, NULL, NULL, &ws);
    if (pid < 0) {
        return -1;
    }
    if (pid == 0) {
        // Child: only async-signal-safe calls from here to execve.
        sigset_t empty;
        sigemptyset(&empty);
        sigprocmask(SIG_SETMASK, &empty, NULL);
        struct sigaction dfl = {0};
        dfl.sa_handler = SIG_DFL;
        for (int sig = 1; sig < NSIG; sig++) {
            sigaction(sig, &dfl, NULL);
        }
        // Do not leak the app's other descriptors (other ptys, sockets).
        int max = (int)sysconf(_SC_OPEN_MAX);
        if (max < 0 || max > 65536) {
            max = 65536;
        }
        for (int i = 3; i < max; i++) {
            close(i);
        }
        execve(path, argv, envp);
        _exit(127);
    }

    int flags = fcntl(fd, F_GETFL);
    if (flags >= 0) {
        fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    }
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    *master_fd = fd;
    return pid;
}

int agentmux_set_window_size(int master_fd, unsigned short columns, unsigned short rows) {
    struct winsize ws = {.ws_row = rows, .ws_col = columns};
    return ioctl(master_fd, TIOCSWINSZ, &ws);
}
