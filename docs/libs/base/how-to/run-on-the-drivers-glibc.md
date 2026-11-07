# Run a GPU program on its drivers' glibc

Call `reexecOntoDriverGlibc` first in `main`, before anything opens Vulkan or
OpenGL, and find the program's own files through `thisProgramPath`:

```d
import std.path : buildPath, dirName;

import sparkles.base.driver_libc : reexecOntoDriverGlibc, thisProgramPath;

int main(string[] args)
{
    reexecOntoDriverGlibc();
    const share = thisProgramPath.dirName.buildPath("../share/my-app");
    // …
}
```

A process has one C library, and the GPU drivers that the Vulkan loader and
libglvnd open share it. A Nix-built program carries its own glibc, while on
NixOS the drivers come from the system's nixpkgs. When the system is newer, a
driver that needs the newer glibc does not load. Mesa's RADV, lavapipe and
radeonsi link LLVM, which needs it, and the loader logs:

```text
libm.so.6: version `GLIBC_2.44' not found (required by …/libLLVM.so.21.1)
```

Linking the C library statically does not help: the drivers are shared objects,
and they bring `libc.so.6` with them.

## What the call does

1. It reads every Vulkan driver manifest (`vulkan/icd.d`) and EGL vendor
   manifest (`glvnd/egl_vendor.d`), where the loaders look: the files named by
   `VK_DRIVER_FILES` or `__EGL_VENDOR_LIBRARY_FILENAMES` when set, else the XDG
   directories, `/etc` and NixOS's `/run/opengl-driver/share`.
2. For each driver library it finds the glibc it loads: the first directory
   with `libc.so.6` and glibc's dynamic linker, from the library's run path
   (NixOS), its own directory, or the system's library directories.
3. When the newest of those glibc releases is newer than the one running, the
   program runs itself again through that glibc's dynamic linker, with that
   directory searched first. glibc runs programs built against older releases,
   so the whole process then shares the drivers' C library.

The program restarts from the beginning with the same arguments and
environment, so the call returns in the new process, with status
`reexecuted`. Two environment variables tell it that it was re-executed; it
clears them at once, so the programs it starts do not inherit them.

| Status        | Meaning                                                                        |
| ------------- | ------------------------------------------------------------------------------ |
| `unsupported` | not Linux with glibc: macOS, Windows, Android and musl have nothing to do      |
| `current`     | the running glibc is at least as new as every driver's                         |
| `reexecuted`  | this process is the re-executed one; `startedOn` is the glibc it started on    |
| `declined`    | a driver needs a newer glibc and the caller passed `allow: false`              |
| `failed`      | a driver needs a newer glibc and running on it failed; `error` holds the errno |

Only report, without re-executing, with `reexecOntoDriverGlibc(allow: false)`.
`forEachDriverLibc` is the scan on its own: it visits each manifest with the
driver library and glibc it leads to.

## Why `thisProgramPath`

A re-executed program runs as an argument of the dynamic linker, so its
`/proc/self/exe`, and Phobos' `thisExePath`, name the linker. `thisProgramPath`
is the program's own executable either way. Use it wherever a program finds
files next to itself or reads its own build information; `sparkles:core-cli`'s
`--version` does.
