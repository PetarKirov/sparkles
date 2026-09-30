# Adjacent approaches and escape hatches

**Last reviewed:** September 30, 2026.

These options widen the design space without being interchangeable with the four main backends. They have not been implemented or benchmarked in this research.

| Approach                             | What it changes                                                            | Fit for custom terminal                                             | Principal cost                                                                                    |
| ------------------------------------ | -------------------------------------------------------------------------- | ------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| QEMU system emulation / TCG          | Emulates guest CPU and devices without requiring usable EL2 virtualization | Own emulator lifecycle and guest PTY transport; full Linux possible | CPU, battery and boot/memory overhead; substantial native packaging                               |
| SSH to remote NixOS                  | Moves store, builds and kernel services off device                         | Existing terminal can render a remote PTY                           | Connectivity, latency, host administration and offline limitations                                |
| Remote Nix builders                  | Offloads build execution                                                   | Useful adjunct to any local Nix client                              | Local result still needs a compatible runtime and logical store                                   |
| Bionic-native Nix / package universe | Targets Android libc and filesystem/security model                         | Native app integration potentially simpler                          | Separate platform/package coverage; ordinary glibc Linux outputs are not automatically compatible |
| Root bind/chroot helper              | Supplies canonical store without PRoot                                     | Owned privilege broker plus native PTY                              | Root policy, UID separation and Android kernel limitations                                        |

[QEMU's system emulation documentation][qemu] distinguishes full system emulation and accelerators; do not confuse PRoot with CPU emulation. A native `crosvm`/QEMU wrapper seen in [DroidVM][droidvm] is architectural prior art, not permission to assume a particular accelerator is available.

[Nix's distributed build model][builders] solves build placement, not local loader compatibility. [The ELF example][elf] demonstrates why a successful remote build does not make its interpreter path appear on Android.

A Bionic port would need explicit packaging and cache policy, loader assumptions, dependency coverage and store mapping. This survey found no locally demonstrated drop-in Bionic replacement for the inspected nix-on-droid Linux bootstrap. Treat it as a separate portability project rather than a near-term substitute.

## Sources

- [QEMU system emulation][qemu], [Nix distributed builds][builders].
- [DroidVM source][droidvm], [execution concepts][concepts].

<!-- References -->

[qemu]: https://www.qemu.org/docs/master/system/introduction.html
[builders]: https://nix.dev/manual/nix/2.34/advanced-topics/distributed-builds
[droidvm]: https://github.com/Droid-VM/DroidVM/blob/5c896915789294e3dbb9af81d6a53ee5f436887b/README.md
[elf]: ./concepts/examples/elf-loader.d
[concepts]: ./concepts/index.md
