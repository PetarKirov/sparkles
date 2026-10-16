#!/usr/bin/env dub
/+ dub.sdl:
    name "android-research-start-bench"
    platforms "linux"
    dflags "-betterC"
    targetPath "build"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
E7's bounded process-start microbenchmark: five trials of 1,000 fork/exec/waits.
Default invocation does nothing. --run PROGRAM [ARGS...] runs that exact argv
under the caller's actual app domain, stopping on the first failed child.
See ../index.md#current-target-experiments. Run only with owner approval.
*/
module start_bench;

import core.stdc.errno : errno, EINTR;
import core.stdc.stdio : printf, fflush;
import core.stdc.string : strcmp;
import core.sys.posix.sys.wait : waitpid;
import core.sys.posix.time : clock_gettime, CLOCK_MONOTONIC, timespec;
import core.sys.posix.unistd : fork, execve, _exit;

extern(C) extern __gshared char** environ;

extern(C) int main(int argc, char** argv) @system nothrow @nogc
{
    if (argc < 3 || strcmp(argv[1], "--run") != 0)
    {
        printf("SKIP: pass --run PROGRAM [ARGS...] for an approved benchmark.\n");
        return 0;
    }
    enum count = 1000;
    foreach (trial; 0 .. 5)
    {
        timespec start, end;
        if (clock_gettime(CLOCK_MONOTONIC, &start) != 0)
            return 1;
        foreach (i; 0 .. count)
        {
            const child = fork();
            if (child < 0)
            {
                printf("fork: errno=%d\n", errno);
                return 1;
            }
            if (child == 0)
            {
                execve(argv[2], cast(const(char)**) (argv + 2), cast(const(char)**) environ);
                _exit(127);
            }
            int status;
            int result;
            do
                result = waitpid(child, &status, 0);
            while (result < 0 && errno == EINTR);
            if (result != child || status != 0)
            {
                printf("trial=%d iteration=%d wait=%d status=%d\n", trial + 1, i, result, status);
                return 1;
            }
        }
        if (clock_gettime(CLOCK_MONOTONIC, &end) != 0)
            return 1;
        const ns = (end.tv_sec - start.tv_sec) * 1_000_000_000L + end.tv_nsec - start.tv_nsec;
        printf("trial=%d successful=%d elapsed-ns=%lld ns-per-start=%lld\n",
            trial + 1, count, cast(long) ns, cast(long) (ns / count));
        fflush(null);
    }
    return 0;
}
