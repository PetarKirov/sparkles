# Run the hardware probe

How to add a machine to the [hardware matrix](./index.md): run one read-only
command and send back the JSON it writes.

**Last reviewed:** October 28, 2026

## Run it

You need Nix with flakes on Linux or macOS; no D compiler, Vulkan SDK or Android
SDK. Use the exact revision given with the request:

```bash
REV=COMMIT_FROM_THE_REQUEST
nix run "github:PetarKirov/sparkles?rev=$REV#media-hw-probe" -- -o report.json
```

For an Android phone with USB debugging enabled, run it on the computer the phone
is plugged into:

```bash
nix run "github:PetarKirov/sparkles?rev=$REV#media-hw-probe" -- --list-adb
nix run "github:PetarKirov/sparkles?rev=$REV#media-hw-probe" -- \
  --adb SERIAL_FROM_THE_LIST -o phone.json
```

The run takes a few seconds. A part that cannot be probed (no Vulkan driver, no
`vainfo`, an unreachable phone) does not stop the rest, so a report is always
produced.

Every step that can fail is recorded in the `attempts` list of the section it
feeds, whether it succeeded or not. An attempt names what it gathers and how:
the exact `argv` of a command (for a phone, also the remote `shell` command
line), a system or Vulkan `call`, or a file `path`. A failed attempt adds its
`exitCode`, `osError` (`errno`), a symbolic `code` such as `ENOENT` or
`VK_ERROR_INCOMPATIBLE_DRIVER`, the `message` (standard error, or the library's
error text) and the end of standard output. Its `status` is `ok`, `failed`,
`unsupported` (the call answered "not supported"), `unavailable` (the tool,
library or file is absent) or `warning`. The Vulkan loader's own warnings and
errors are attempts too: a driver it could not load, and why (for example a
driver library that needs a newer glibc than the probe's), appears there even
when every Vulkan call succeeds. To retry a failed command by hand, run its
`argv`; for a phone, set `ANDROID_SERIAL` to the serial first, since the report
leaves the serial out.

The probe has only been run on NixOS, macOS and over `adb`. On another Linux
distribution the Nix-built Vulkan loader may not load the system's GPU driver. If
the report's `vulkan.status` is an error or its only device is `llvmpipe`, send it
anyway and say which distribution and driver you have; the `cpu`, `io` and `media`
sections are still useful.

## What it reads

| Area   | Source                                                                                         |
| ------ | ---------------------------------------------------------------------------------------------- |
| System | OS name and version, kernel release, architecture, total memory, Mac or phone model name       |
| CPU    | model name, core types, SIMD and crypto feature flags                                          |
| I/O    | `io_uring` setup features and supported opcodes (Linux)                                        |
| Vulkan | per device: name, driver, extensions, feature structs, limits, formats, video profiles         |
| Media  | `vainfo` per render node and `nvidia-smi` (Linux), VideoToolbox (macOS), codec lists (Android) |

It writes nothing except the report: no driver state changes, no files on the
device, no network access. It never reads the host name, user names, serial
numbers or device UUIDs; the `adb` serial you pass is not stored. Driver build
strings and the PCI IDs of GPUs are included. Read the JSON before sending it.

## Send it back

Send `report.json` as it is, with one line naming the machine (for example
"ThinkPad P1, RTX 4090 mobile, driver 580"). Do not edit the JSON; if something
in it must not be shared, say so and leave the file out.
