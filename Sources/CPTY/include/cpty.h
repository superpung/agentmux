#ifndef AGENTMUX_CPTY_H
#define AGENTMUX_CPTY_H

#include <sys/types.h>

/// Spawns `path` with `argv` / `envp` on a new pseudo-terminal of the given
/// size. The child becomes a session leader whose controlling terminal is
/// the pty, so window-size changes reach it as SIGWINCH.
///
/// On success returns the child pid and stores the master fd (non-blocking,
/// close-on-exec) in `*master_fd`. On failure returns -1 with errno set.
pid_t agentmux_spawn_pty(const char *path,
                         char *const argv[],
                         char *const envp[],
                         unsigned short columns,
                         unsigned short rows,
                         int *master_fd);

/// Sets the pty window size. Returns 0 or -1 with errno set.
int agentmux_set_window_size(int master_fd, unsigned short columns, unsigned short rows);

#endif
