#!/usr/bin/env dub
/+ dub.sdl:
    name "freebsd_vm"
    dflags "-preview=in" "-preview=dip1000"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
A local FreeBSD virtual machine for the code no hosted runner reaches: the
`_umtx_op` seam of `sparkles.base.sync`, and anything else FreeBSD-specific.

    nix run .#freebsd-vm -- test                  # boot if needed, copy the tree, run base.sync
    nix run .#freebsd-vm -- test :base -- -i vfs  # any `dub test` arguments
    nix run .#freebsd-vm -- start | stop | reset
    nix run .#freebsd-vm -- ssh [command…]
    nix run .#freebsd-vm -- sync                  # copy the working tree to ~/sparkles

The machine boots the release's cloud-init image under KVM, from a
copy-on-write overlay, with a NoCloud seed that creates a `sparkles` user with
a generated key (in the `operator` group, so it may power the machine off)
and installs `ldc`, `dub` and `git`. Its state (the overlay,
the key, the serial log) lives in `$XDG_STATE_HOME/sparkles/freebsd-vm`; `reset`
deletes it. `sync` copies the files `git ls-files` lists — tracked and
untracked, ignored ones left out — so uncommitted edits are tested too.

The Nix package (`nix/packages/freebsd-vm.nix`) provides the image and the
tools: `FREEBSD_VM_IMAGE` names the compressed image, and `qemu-system-x86_64`,
`qemu-img`, `xorriso`, `xz`, `ssh` and `ssh-keygen` are on `PATH`.
*/
module freebsd_vm;

import core.thread : Thread;
import core.time : MonoTime, seconds;

import std.array : join;
import std.conv : to;
import std.file : exists, mkdirRecurse, readText, rmdirRecurse, write;
import std.format : format;
import std.path : buildPath;
import std.process : environment, execute, spawnProcess, wait;
import std.stdio : stderr, writeln;
import std.string : strip;

enum string defaultTest = `dub test :base --compiler=ldc2 -- -i 'sync\.'`;

struct Vm
{
    string state, image, key, port;

    static Vm open()
    {
        const home = environment.get("HOME");
        const base = environment.get("XDG_STATE_HOME", buildPath(home, ".local/state"));
        Vm vm;
        vm.state = buildPath(base, "sparkles", "freebsd-vm");
        vm.image = environment.get("FREEBSD_VM_IMAGE");
        vm.key = buildPath(vm.state, "id_ed25519");
        vm.port = environment.get("FREEBSD_VM_SSH_PORT", "10022");
        return vm;
    }

    string path(string name) const => buildPath(state, name);

    bool running() const
    {
        if (!path("qemu.pid").exists)
            return false;
        const pid = path("qemu.pid").readText.strip;
        return execute(["kill", "-0", pid]).status == 0;
    }

    string[] sshArgs() const => ["ssh", "-i", key, "-p", port, "-o", "BatchMode=yes",
        "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
        "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=5", "sparkles@127.0.0.1"];

    int ssh(string command) const => spawnProcess(sshArgs ~ command).wait;

    bool sshQuiet(string command) const => execute(sshArgs ~ command).status == 0;

    /// Creates the overlay, the key and the seed, once.
    void prepare()
    {
        if (image is null)
            fail("FREEBSD_VM_IMAGE is unset: run this through `nix run .#freebsd-vm`");
        mkdirRecurse(state);
        if (!path("base.qcow2").exists)
        {
            writeln("freebsd-vm: decompressing ", image);
            run(["sh", "-c", format!`xz -dc '%s' > '%s.tmp' && mv '%s.tmp' '%s'`(image,
                path("base.qcow2"), path("base.qcow2"), path("base.qcow2"))]);
        }
        if (!path("disk.qcow2").exists)
            run(["qemu-img", "create", "-q", "-f", "qcow2", "-F", "qcow2", "-b",
                path("base.qcow2"), path("disk.qcow2"), "24G"]);
        if (!key.exists)
            run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "freebsd-vm", "-f", key]);
        if (!path("seed.iso").exists)
        {
            const seed = path("seed");
            mkdirRecurse(seed);
            write(buildPath(seed, "meta-data"), "instance-id: sparkles-freebsd-vm\n"
                ~ "local-hostname: sparkles-freebsd\n");
            write(buildPath(seed, "user-data"), format!`#cloud-config
users:
    -   name: sparkles
        shell: /bin/sh
        groups: operator
        ssh_authorized_keys:
            - %s
packages:
    - ldc
    - dub
    - git
`((key ~ ".pub").readText.strip));
            run(["xorriso", "-as", "mkisofs", "-quiet", "-V", "cidata", "-J", "-r", "-o",
                path("seed.iso"), seed]);
        }
    }

    void start()
    {
        if (running)
            return;
        prepare();
        const cpus = environment.get("FREEBSD_VM_CPUS", "4");
        const memory = environment.get("FREEBSD_VM_MEMORY", "4G");
        run(["qemu-system-x86_64", "-machine", "q35,accel=kvm", "-cpu", "host", "-smp", cpus,
            "-m", memory, "-display", "none", "-daemonize", "-pidfile", path("qemu.pid"),
            "-serial", "file:" ~ path("serial.log"),
            "-drive", "file=" ~ path("disk.qcow2") ~ ",if=virtio,format=qcow2",
            "-drive", "file=" ~ path("seed.iso") ~ ",media=cdrom,readonly=on",
            "-nic", "user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:" ~ port ~ "-:22"]);
        writeln("freebsd-vm: booting (serial log: ", path("serial.log"), ")");
        // The first boot installs the packages after the network comes up, so
        // the machine is ready once `dub` is there, not when sshd answers.
        await(() => sshQuiet("command -v dub && command -v ldc2"), 900);
        writeln("freebsd-vm: ready on port ", port);
    }

    void stop()
    {
        if (!running)
            return;
        // `operator` may run shutdown(8); the seed puts the user in it.
        sshQuiet("shutdown -p now");
        const pid = path("qemu.pid").readText.strip;
        if (!awaitQuietly(() => !running, 60))
            execute(["kill", pid]);
        writeln("freebsd-vm: stopped");
    }

    /// Copies the working tree to `~/sparkles`, replacing what was there.
    void sync()
    {
        import std.algorithm : filter, joiner, map;
        import std.process : pipe;
        import std.stdio : stdin;

        const files = execute(["git", "ls-files", "-z", "--cached", "--others",
            "--exclude-standard"]);
        if (files.status != 0)
            fail("not in a git checkout: " ~ files.output);
        // A deleted file git still tracks would fail tar, so the list keeps
        // only the files that exist.
        const list = path("files");
        write(list, files.output.splitNul.filter!exists.map!(n => n ~ '\0').joiner.to!string);
        auto p = pipe();
        auto tar = spawnProcess(["tar", "-c", "--null", "-T", list, "-f", "-"], stdin,
            p.writeEnd);
        auto remote = spawnProcess(sshArgs
            ~ "rm -rf sparkles && mkdir sparkles && tar -x -C sparkles -f -", p.readEnd);
        if (wait(tar) != 0 || wait(remote) != 0)
            fail("copying the tree failed");
    }
}

string[] splitNul(string s)
{
    import std.algorithm : filter, splitter;
    import std.array : array;

    return s.splitter('\0').filter!(n => n.length > 0).array;
}

void run(string[] argv)
{
    const r = execute(argv);
    if (r.status != 0)
        fail(argv[0] ~ " failed:\n" ~ r.output);
}

bool awaitQuietly(bool delegate() ready, int timeoutSeconds)
{
    const deadline = MonoTime.currTime + timeoutSeconds.seconds;
    while (!ready())
    {
        if (MonoTime.currTime > deadline)
            return false;
        Thread.sleep(2.seconds);
    }
    return true;
}

void await(bool delegate() ready, int timeoutSeconds)
{
    if (!awaitQuietly(ready, timeoutSeconds))
        fail(format!"the machine was not ready within %d s"(timeoutSeconds));
}

noreturn fail(string message)
{
    stderr.writeln("freebsd-vm: ", message);
    import core.stdc.stdlib : exit;

    exit(1);
}

int main(string[] args)
{
    auto vm = Vm.open();
    const command = args.length > 1 ? args[1] : "test";
    const rest = args.length > 2 ? args[2 .. $] : [];
    switch (command)
    {
    case "start":
        vm.start();
        return 0;
    case "stop":
        vm.stop();
        return 0;
    case "reset":
        vm.stop();
        if (vm.state.exists)
            rmdirRecurse(vm.state);
        return 0;
    case "ssh":
        vm.start();
        return vm.ssh(rest.join(" "));
    case "sync":
        vm.start();
        vm.sync();
        return 0;
    case "test":
        vm.start();
        vm.sync();
        const test = rest.length ? "dub test " ~ rest.quoteAll.join(" ") : defaultTest;
        return vm.ssh("cd sparkles && " ~ test);
    default:
        fail("unknown command " ~ command ~ "; expected test, start, stop, reset, ssh or sync");
    }
}

string[] quoteAll(const string[] words)
{
    import std.algorithm : map;
    import std.array : array, replace;

    return words.map!(w => "'" ~ w.replace("'", `'\''`) ~ "'").array;
}
