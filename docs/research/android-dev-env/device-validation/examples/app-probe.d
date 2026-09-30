#!/usr/bin/env dub
/+ dub.sdl:
    name "android-research-app-probe"
    platforms "linux"
    dflags "-betterC"
    targetPath "build"
+/
/**
 * libc-only probe suitable for a Bionic Android executable (-betterC).
 * Run from the real terminal UI, not adb shell or run-as.
 * Evidence: ../index.md#app-domain-probe.
 * Namespace changes occur only in forked children; no mounts are made.
 */
module app_probe;

import core.stdc.stdio : printf, fflush;
import core.stdc.errno : errno;
import core.sys.posix.unistd : getuid, getgid, fork, read, close, _exit;
import core.sys.posix.fcntl : open, O_RDONLY;
import core.sys.posix.sys.wait : waitpid;
import core.sys.posix.sys.socket : socket, SOCK_STREAM;

extern(C) int unshare(int flags) @nogc nothrow;

void showFile(const(char)* path) @nogc nothrow
{
    char[4096] buffer;
    const fd = open(path, O_RDONLY);
    if (fd < 0)
    {
        printf("%s: errno=%d\n", path, errno);
        return;
    }
    printf("%s:\n", path);
    while (true)
    {
        const size = read(fd, buffer.ptr, buffer.length - 1);
        if (size <= 0)
            break;
        buffer[size] = 0;
        printf("%s", buffer.ptr);
    }
    printf("\n");
    close(fd);
}

int namespaceAttempt(int flags, const(char)* name) @nogc nothrow
{
    fflush(null);
    const child = fork();
    if (child < 0)
    {
        printf("fork: errno=%d\n", errno);
        return 1;
    }
    if (child == 0)
    {
        const result = unshare(flags);
        const error = errno;
        printf("unshare(%s): result=%d errno=%d\n", name, result, result < 0 ? error : 0);
        fflush(null);
        _exit(0);
    }
    int status;
    return waitpid(child, &status, 0) != child || status != 0;
}

extern(C) int main() @nogc nothrow
{
    printf("uid=%u gid=%u\n", getuid(), getgid());
    showFile("/proc/self/attr/current");
    showFile("/proc/self/status");
    int failure = namespaceAttempt(0x10000000, "CLONE_NEWUSER");
    failure |= namespaceAttempt(0x00020000, "CLONE_NEWNS");
    failure |= namespaceAttempt(0x10000000 | 0x00020000, "CLONE_NEWUSER|CLONE_NEWNS");
    const fd = socket(40, SOCK_STREAM, 0); // Linux AF_VSOCK.
    const error = errno;
    printf("socket(AF_VSOCK): fd=%d errno=%d\n", fd, fd < 0 ? error : 0);
    if (fd >= 0)
        close(fd);
    printf("Capability absence/rejection is a result, not a probe failure.\n");
    return failure;
}
