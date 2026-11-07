#include <stdio.h>
#include <unistd.h>
#include <stdlib.h>
#include <mach-o/dyld.h>
#include <libgen.h>
#include <limits.h>
#include <string.h>

int main(int argc, char *argv[]) {
    char path[PATH_MAX];
    uint32_t size = sizeof(path);
    if (_NSGetExecutablePath(path, &size) != 0) return 1;
    char dir[PATH_MAX];
    strncpy(dir, dirname(path), sizeof(dir));

    char dylib[PATH_MAX];
    snprintf(dylib, sizeof(dylib), "%s/../Frameworks/librumble_bridge_native.dylib", dir);
    setenv("DYLD_INSERT_LIBRARIES", dylib, 1);

    char bin[PATH_MAX];
    snprintf(bin, sizeof(bin), "%s/project-reclaimer-bin", dir);

    return execv(bin, argv);
}
