#include "GhosttyHostEnvironment.h"

#include <crt_externs.h>
#include <stdlib.h>
#include <string.h>

bool ghostty_host_detach_environment(void) {
    char ***slot = _NSGetEnviron();
    char **original = *slot;
    if (original == NULL) return true;

    size_t count = 0;
    while (original[count] != NULL) count++;

    char **replacement = calloc(count + 1, sizeof(*replacement));
    if (replacement == NULL) return false;
    for (size_t i = 0; i < count; i++) {
        replacement[i] = strdup(original[i]);
        if (replacement[i] == NULL) {
            while (i > 0) free(replacement[--i]);
            free(replacement);
            return false;
        }
    }

    // Ghostty borrows the original array and its strings. Darwin only
    // reallocates or frees owned pointers in the current environment. A
    // separate array and separate strings keep the borrowed data readable
    // for the lifetime of the library.
    *slot = replacement;
    return true;
}
