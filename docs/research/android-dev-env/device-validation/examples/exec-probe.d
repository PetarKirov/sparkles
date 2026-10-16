#!/usr/bin/env dub
/+ dub.sdl:
    name "android-research-exec-probe"
    platforms "linux"
    dflags "-betterC"
    targetPath "build"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
Libc-only E1–E4 payload: report the real app context, argv and executable;
optionally try execve or dlopen. See ../index.md#current-target-experiments.
No ADB calls, policy changes, namespace changes or persistent child processes.
Compile with -version=ExecProbeStatic to omit dynamic-loader calls for E4.
*/
module exec_probe;

import core.stdc.errno : errno;
import core.stdc.stdio : printf, fflush, fopen, fclose, fgets;
import core.stdc.string : strcmp;
import core.sys.posix.unistd : getuid, getgid, readlink, execve;

version (ExecProbeStatic) {} else
    import core.sys.posix.dlfcn : dlopen, dlclose, dlerror, RTLD_NOW, RTLD_LOCAL;

extern(C) extern __gshared char** environ;

extern(C) int main(int argc, char** argv) @system nothrow @nogc
{
    printf("uid=%u gid=%u\n", getuid(), getgid());
    char[4096] buffer;
    auto context = fopen("/proc/self/attr/current", "r");
    if (context is null)
        printf("context: errno=%d\n", errno);
    else
    {
        if (fgets(buffer.ptr, cast(int) buffer.length, context) !is null)
            printf("context=%s\n", buffer.ptr);
        fclose(context);
    }
    const size = readlink("/proc/self/exe", buffer.ptr, buffer.length - 1);
    if (size < 0)
        printf("readlink: errno=%d\n", errno);
    else
    {
        buffer[size] = 0;
        printf("exe=%s\n", buffer.ptr);
    }
    foreach (i; 0 .. argc)
        printf("argv[%d]=%s\n", i, argv[i]);
    if (argc == 3 && strcmp(argv[1], "--exec") == 0)
    {
        const(char)*[2] childArgs = [argv[2], null];
        fflush(null);
        execve(argv[2], childArgs.ptr, cast(const(char)**) environ);
        const error = errno;
        printf("execve(%s): errno=%d\n", argv[2], error);
        return 1;
    }
    version (ExecProbeStatic) {} else
    {
        if (argc == 3 && strcmp(argv[1], "--dlopen") == 0)
        {
            auto handle = dlopen(argv[2], RTLD_NOW | RTLD_LOCAL);
            if (handle is null)
            {
                printf("dlopen: %s\n", dlerror());
                return 1;
            }
            printf("dlopen: success\n");
            return dlclose(handle) == 0 ? 0 : 1;
        }
    }
    return 0;
}
