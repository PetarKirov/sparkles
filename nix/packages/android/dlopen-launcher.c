/*
 * Runs a D test binary built as a shared library: `dlopen`s `lib<name>.so`
 * from this executable's directory and calls the `main` it exports, as a
 * NativeActivity loads an app's library. The D code's TLS is then a
 * dynamically loaded module's, not an executable's initial-exec block.
 */
#include <dlfcn.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    char path[PATH_MAX];
    ssize_t n = readlink("/proc/self/exe", path, sizeof path - 1);
    if (n < 0) {
        perror("readlink /proc/self/exe");
        return 127;
    }
    path[n] = '\0';
    char *slash = strrchr(path, '/');
    const char *name = slash ? slash + 1 : path;
    char lib[PATH_MAX];
    int len = snprintf(lib, sizeof lib, "%.*s/lib%s.so",
        slash ? (int)(slash - path) : 1, slash ? path : ".", name);
    if (len < 0 || (size_t)len >= sizeof lib) {
        fprintf(stderr, "library path too long\n");
        return 127;
    }

    void *handle = dlopen(lib, RTLD_NOW | RTLD_LOCAL);
    if (!handle) {
        fprintf(stderr, "dlopen %s: %s\n", lib, dlerror());
        return 127;
    }
    int (*entry)(int, char **) = (int (*)(int, char **))dlsym(handle, "main");
    if (!entry) {
        fprintf(stderr, "dlsym main: %s\n", dlerror());
        return 127;
    }
    return entry(argc, argv);
}
