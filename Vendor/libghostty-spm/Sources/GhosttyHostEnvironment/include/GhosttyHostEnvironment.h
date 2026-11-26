#ifndef GHOSTTY_HOST_ENVIRONMENT_H
#define GHOSTTY_HOST_ENVIRONMENT_H

#include <stdbool.h>

/// After Ghostty initializes, give libc a separate environment to mutate.
/// Run once during startup, before starting work that may change the environment.
bool ghostty_host_detach_environment(void);

#endif
