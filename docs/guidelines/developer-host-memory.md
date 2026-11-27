# Keeping a Developer Host Responsive Under Builds

How to configure a Linux developer machine so a large build, `ci`'s or any
other, cannot end your desktop session when memory runs out. This is item 3 of
the task-DAG plan's [memory-safe execution](../specs/build-primitives/task-dag/PLAN.md#m7-memory-safe-execution)
milestone. The rest of it is `ci`'s own: it runs heavy commands in a
memory-limited systemd scope ([CIC22](../specs/ci/task-dag/SPEC.md#_5-8-commit-checks)),
admits actions by their measured memory ([CIC23](../specs/ci/task-dag/SPEC.md#_5-8-commit-checks)),
and raises its actions' OOM score so a shortage takes them first. What follows
covers what `ci` cannot: a shortage it does not contain, and every other
program.

## Check what `ci` already does

```bash
ci test --build-only --from versions 2>&1 | grep 'memory:'
```

`memory: contained by sparkles-ci-<pid>-<n>, MemoryMax <bytes> bytes, each
action accounted` means the run is in its own scope: at `MemoryMax` the kernel
kills only the run's processes. `memory: unconfined: …` says why it is not, most
often a session without a systemd user manager (an SSH session without
lingering, a container). Lower the limit with `--memory-max=20G`, or the
`SPARKLES_CI_MEMORY_MAX` variable, when the host runs other heavy work.

## Prefer killing the build to freezing the session

The kernel's OOM killer acts late: by the time memory is exhausted, the
desktop has stalled on reclaim for seconds or minutes. A userspace OOM daemon
acts on memory pressure instead, and kills a whole cgroup.

On NixOS, `systemd-oomd` with user slices managed:

```nix
{
  systemd.oomd = {
    enable = true;
    enableUserSlices = true;
  };
}
```

Or `earlyoom`, told what to prefer and what to spare. It matches each regex
against the process's name as the kernel keeps it, `/proc/<pid>/comm`: no
path, at most 15 characters, so `gnome-session-binary` is `gnome-session-b`
and a Nix-wrapped `ci` is `.ci-wrapped`:

```nix
{
  services.earlyoom = {
    enable = true;
    freeMemThreshold = 5;
    extraArgs = [
      "--prefer" "^(ldc2|ld\\.lld|cc1|cc1plus|ci|\\.ci-wrapped)$"
      "--avoid" "^(gnome-shell|Xwayland|gnome-session-b|systemd)$"
    ];
  };
}
```

Elsewhere, install `earlyoom` from the distribution and pass the same
`--prefer` and `--avoid` lists.

## Degrade gradually: compressed swap

Without swap, a shortage goes from fine to an OOM kill in an instant. A
compressed RAM swap device absorbs a short peak at a modest CPU cost and gives
the OOM daemon time to act:

```nix
{
  zramSwap = {
    enable = true;
    memoryPercent = 50;
  };
}
```

`ci` sets `memory.swap.max` to 0 on each action it limits, so an action at its
own limit is killed rather than swapping; the swap device serves everything
else.

## Keep the disks from filling

`ci` watches the file systems a run writes, the store's, the run directory's
and the temporary directory's, and stops admitting work under a reserve of the
smaller of 5 GiB and 10 % of the file system (it evicts the store first when
the store is there), and cancels the run under half of it. When a run stops for
that, `ci cache gc` empties the store's `trash/`, collects older layouts and
evicts its results down to 20 GiB (`--bound` sets another), freeing their
bytes in the same command; `nix-collect-garbage -d` frees the Nix store.
