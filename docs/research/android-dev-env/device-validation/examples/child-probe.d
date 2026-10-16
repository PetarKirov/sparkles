#!/usr/bin/env dub
/+ dub.sdl:
    name "android-research-child-probe"
    platforms "linux"
    dflags "-betterC"
    targetPath "build"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
Bounded E8 payload. Default invocation never forks; --run starts 40 children
which exit after ten seconds even if the parent dies. The parent samples after
seven seconds, terminates only its own surviving children, and reaps them.
See ../index.md#current-target-experiments. Run only with owner approval.
*/
module child_probe;

import core.stdc.errno : errno;
import core.stdc.stdio : printf, fflush;
import core.stdc.string : strcmp;
import core.sys.posix.signal : kill, SIGTERM;
import core.sys.posix.sys.wait : waitpid, WNOHANG;
import core.sys.posix.unistd : fork, getpid, sleep, _exit;

extern(C) int main(int argc, char** argv) @system nothrow @nogc
{
    if (argc != 2 || strcmp(argv[1], "--run") != 0)
    {
        printf("SKIP: pass --run only for an approved 40-child experiment.\n");
        return 0;
    }
    int[40] children;
    size_t started;
    foreach (i; 0 .. children.length)
    {
        const child = fork();
        if (child < 0)
        {
            printf("fork: errno=%d\n", errno);
            break;
        }
        if (child == 0)
        {
            sleep(10);
            _exit(0);
        }
        children[started++] = child;
    }
    printf("parent=%d children-started=%zu\n", getpid(), started);
    fflush(null);
    sleep(7);
    size_t alive;
    foreach (child; children[0 .. started])
    {
        int status;
        const result = waitpid(child, &status, WNOHANG);
        if (result == 0)
        {
            ++alive;
            kill(child, SIGTERM);
            const reaped = waitpid(child, &status, 0);
            printf("cleanup-child=%d wait=%d status=%d\n", child, reaped, status);
        }
        else
            printf("early-child=%d wait=%d status=%d\n", child, result, status);
    }
    printf("alive-at-sample=%zu of %zu; cleanup-complete\n", alive, started);
    return started == children.length ? 0 : 1;
}
