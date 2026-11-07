# Hardware matrix

What the machines available to the image and video work actually expose, measured
with one probe rather than taken from vendor documentation: CPU SIMD features,
`io_uring` opcodes, Vulkan texture and YCbCr formats, Vulkan Video profiles,
compute features and the platform media API.

| Field        | Value                                                                                                 |
| ------------ | ----------------------------------------------------------------------------------------------------- |
| Probe        | [`media-hw-probe.d`][probe], flake app `media-hw-probe`                                               |
| Probe build  | each report records its schema (`sparkles.media-hw-probe/1` to `/3`) and the commit it ran            |
| Reports      | nine: three Linux desktops, three Linux laptops, one Mac, two Android phones (raw JSON in `reports/`) |
| Missing      | Windows, on-device Android; see [Gaps](#gaps)                                                         |
| Contributing | [Run the probe](./contributing.md)                                                                    |

**Last reviewed:** October 28, 2026

Every cell on this page is _verified on device_: it is what the driver or the
operating system reported to the probe on the date above. A claim about hardware
that is not in this table is _documented_ only, and the catalog marks it so.

## Devices

| Report                       | OS and kernel                      | CPU                                       | GPUs, Vulkan driver                                                                                         | Media API                                  |
| ---------------------------- | ---------------------------------- | ----------------------------------------- | ----------------------------------------------------------------------------------------------------------- | ------------------------------------------ |
| [RX Vega 56][r-vega]         | NixOS 25.11, Linux 6.18.26         | Ryzen 9 7940HX (Zen 4), 32 threads        | Radeon RX Vega 56 and Radeon 610M iGPU; RADV, Mesa 25.2.6, Vulkan 1.4.318                                   | VA-API, `radeonsi`                         |
| [RX 9070 XT][r-9070]         | NixOS 25.11, Linux 6.19.7          | Ryzen 9 7940HX (Zen 4), 32 threads        | Radeon RX 9070 XT (GFX1201) and Radeon 610M iGPU; RADV, Mesa 25.2.6                                         | VA-API, `radeonsi`                         |
| [RTX 4060 Laptop][r-4060]    | NixOS 24.11, Linux 6.11.11         | Ryzen 9 7945HX (Zen 4), 32 threads        | GeForce RTX 4060 Laptop (Ada), NVIDIA 565.77, Vulkan 1.3.289; Radeon 610M iGPU on RADV, Mesa 24.2.6         | VA-API (`radeonsi`, `nvidia-vaapi-driver`) |
| [RTX 4090 Laptop][r-4090]    | NixOS 26.11, Linux 7.3.0           | Core i9-13900HX (Raptor Lake), 32 threads | GeForce RTX 4090 Laptop (Ada), NVIDIA 595.112.07, Vulkan 1.4.329; UHD Graphics 770 iGPU on ANV, Mesa 26.2.5 | VA-API (`iHD` 26.3.5; NVIDIA node failed)  |
| [Lunar Lake][r-lnl]          | NixOS 25.05, Linux 6.17.6          | Core Ultra 7 258V (Lunar Lake), 8 cores   | Intel Graphics (Xe2) on ANV, Mesa 25.0.7, Vulkan 1.4.305                                                    | VA-API failed (`vainfo` exit 3)            |
| [Arc A380][r-a380]           | NixOS 26.11, Linux 7.2.9-zen1      | Core i7-7700K (Kaby Lake), 8 threads      | Intel Arc A380 (DG2) on ANV, Mesa 26.2.5, Vulkan 1.4.354                                                    | VA-API (`iHD` 26.3.5)                      |
| [Apple M4 Max][r-m4]         | macOS 27.0.1                       | M4 Max, 10 performance + 4 efficiency     | M4 Max through MoltenVK 1.4.2, Vulkan 1.4.357                                                               | VideoToolbox                               |
| [Snapdragon 888][r-adreno]   | Android 14 (SDK 34), Linux 5.4.289 | SM8350, 8 cores                           | Adreno 660, Qualcomm driver of January 2023, Vulkan 1.1.128 (`cmd gpu vkjson`)                              | MediaCodec (Codec2)                        |
| [Snapdragon 8 Elite][r-a830] | Android 16 (SDK 36), Linux 6.6.77  | SM8750P (Oryon), 8 cores                  | Adreno 830, Qualcomm driver of July 2025, Vulkan 1.3.284 (`cmd gpu vkjson`)                                 | MediaCodec (Codec2)                        |

The Android reports are collected from the host over `adb`, so their Vulkan
sections come from `cmd gpu vkjson`. It carries the `Vulkan11`–`Vulkan13` feature
structs when the driver is new enough (the Adreno 830's is, the Adreno 660's is
not), but no video capabilities and only core formats; the `io_uring` rows are
empty because the shell does not share an app's context.

## CPU SIMD

| Feature                                 | Zen 4 (AMD hosts) | Raptor Lake | Kaby Lake | Lunar Lake | Apple M4 Max | Snapdragon 888 | Snapdragon 8 Elite |
| --------------------------------------- | ----------------- | ----------- | --------- | ---------- | ------------ | -------------- | ------------------ |
| AVX2, FMA, F16C                         | yes               | yes         | yes       | yes        | -            | -              | -                  |
| AVX-512 F, BW, VL, DQ, CD               | yes               | no          | no        | no         | -            | -              | -                  |
| AVX-512 VBMI, VBMI2, IFMA               | yes               | no          | no        | no         | -            | -              | -                  |
| AVX-512 VNNI, BF16, BITALG              | yes               | no          | no        | no         | -            | -              | -                  |
| AVX-512 FP16                            | no                | no          | no        | no         | -            | -              | -                  |
| GFNI, VAES, VPCLMULQDQ                  | yes               | yes         | no        | yes        | -            | -              | -                  |
| AVX-VNNI (256-bit)                      | no                | yes         | no        | yes        | -            | -              | -                  |
| NEON (Advanced SIMD), FP16              | -                 | -           | -         | -          | yes          | yes            | yes                |
| Dot product (`asimddp`, `FEAT_DotProd`) | -                 | -           | -         | -          | yes          | yes            | yes                |
| I8MM, BF16                              | -                 | -           | -         | -          | yes          | no             | yes                |
| SVE, SVE2                               | -                 | -           | -         | -          | no           | no             | no                 |
| SME, SME2                               | -                 | -           | -         | -          | yes          | no             | no                 |

The reports show which features the kernel enabled, not how fast they run: Zen 4
executes 512-bit instructions on 256-bit units, and that cost needs a benchmark,
not a probe. The M4 Max reports SME and SME2 but no SVE, and neither phone has either, so
NEON with dot product is the AArch64 baseline these devices share; the 8 Elite
adds I8MM and BF16, which the Snapdragon 888 lacks. Neither Intel part has
AVX-512 (Raptor Lake disables it on its hybrid parts, Lunar Lake does not have
it); both have the 256-bit AVX-VNNI that Zen 4 lacks. AVX2 with FMA and F16C is
therefore the x86 baseline, and AVX-512 an optional path for AMD; the Kaby Lake
server has nothing above it (no GFNI, VAES or VNNI of either width).

## Texture and YCbCr formats

Optimal-tiling support. `S` sampled, `L` linear filtering, `W` storage image,
`Y` YCbCr conversion with linear filtering, `V` usable as a Vulkan Video picture;
`-` not supported; blank cells were not reported.

| Format                                             | Vega 56 | 9070 XT | 610M | M4 Max | Adreno 660 | Adreno 830 | RTX 4060 | RTX 4090 | UHD 770 | Lunar Lake | Arc A380 |
| -------------------------------------------------- | ------- | ------- | ---- | ------ | ---------- | ---------- | -------- | -------- | ------- | ---------- | -------- |
| `BC1_RGBA_UNORM_BLOCK` … `BC7_UNORM_BLOCK`         | SL      | SL      | SL   | SL     | -          | SL         | SL       | SL       | SL      | SL         | SL       |
| `BC6H_UFLOAT_BLOCK`                                | SL      | SL      | SL   | SL     | -          | SL         | SL       | SL       | SL      | SL         | SL       |
| `ETC2_R8G8B8A8_UNORM_BLOCK`, `EAC_R11G11`          | SL      | -       | -    | SL     | SL         | SL         | -        | -        | SL      | SL         | SL       |
| `ASTC_4x4_UNORM_BLOCK` (LDR)                       | -       | -       | -    | SL     | SL         | SL         | -        | -        | SL      | -          | -        |
| `ASTC_4x4_SFLOAT_BLOCK` (HDR)                      | -       | -       | -    | SL     |            |            | SL       | -        | -       | -          | -        |
| `E5B9G9R9_UFLOAT_PACK32`                           | SL      | SL      | SL   | SL     | SL         | SL         | SL       | SL       | SL      | SL         | SL       |
| `B10G11R11_UFLOAT_PACK32`, `R16G16B16A16_SFLOAT`   | SLW     | SLW     | SLW  | SLW    | SLW        | SLW        | SLW      | SLW      | SLW     | SLW        | SLW      |
| `A2B10G10R10_UNORM_PACK32`                         | SLW     | SLW     | SLW  | SLW    | SLW        | SLW        | SLW      | SLW      | SLW     | SLW        | SLW      |
| `G8B8G8R8_422_UNORM` (YUY2)                        | -       | -       | -    | SLY    | S          | S          | -        | -        | SL      | SL         | SL       |
| `G8_B8R8_2PLANE_420_UNORM` (NV12)                  | SLY     | SLYV    | SLYV | SLY    | SLY        | SLY        | SLYV     | SLYV     | SLY     | SLY        | SLY      |
| `G8_B8_R8_3PLANE_420_UNORM` (I420)                 | SLY     | SLY     | SLY  | SLY    | SLY        | SLY        | SLY      | SLY      | SLY     | SLY        | SLY      |
| `G10X6_B10X6R10X6_2PLANE_420_UNORM_3PACK16` (P010) | SLY     | SLYV    | SLYV | SLY    | -          | SLY        | SLYV     | SLYV     | SL      | SL         | SL       |
| `G12X4_B12X4R12X4_2PLANE_420_UNORM_3PACK16` (P012) | SLY     | SLYV    | SLYV | SLY    |            |            | SLYV     | SLYV     | -       | -          | -        |
| `G16_B16R16_2PLANE_420_UNORM` (P016)               | SLY     | SLY     | SLY  | SLY    |            |            | SLYV     | SLYV     | SLY     | SLY        | SLY      |
| `G8_B8R8_2PLANE_444_UNORM`, 10-bit 4:4:4           | -       | -       | -    | -      |            |            | SLYV     | SLYV     | SLY     | SLY        | SLY      |

The RTX 4060 reports `ASTC_4x4_SFLOAT_BLOCK` as sampleable while it supports
neither ASTC LDR nor the `textureCompressionASTC_HDR` feature; a format query
alone is not evidence of support, so the library should check the feature bit
as well. The two NVIDIA GPUs are the only devices that decode into 2-plane
4:4:4 and P016.

No single compressed family is universal: BCn is absent on the Adreno 660 (the
Adreno 830 has it), ASTC on every AMD part, and ETC2 on the RDNA parts. The Adreno
830, the M4 Max and the UHD 770 are the only devices with BCn, ETC2 and ASTC LDR
together; the 830 also reports ASTC HDR
in `Vulkan13Features`, though vkjson's core-format list cannot show the format. Uncompressed HDR
(`E5B9G9R9`, `B10G11R11`, half float) and NV12 with sampler YCbCr conversion are.
That is the case for a transcoding path (Basis Universal, KTX2) rather than one
shipped compressed format, and for NV12/P010 as the decoded-video interchange.

## Vulkan Video

Profiles queried with `vkGetPhysicalDeviceVideoCapabilitiesKHR`; extents are the
maximum coded extent; levels are as reported.

| Profile                   | 9070 XT and 610M, Mesa 25.2.6      | Vega 56 | M4 Max (MoltenVK) | Adreno 660               | Adreno 830               | RTX 4060                           | RTX 4090                           | Intel: UHD 770, Lunar Lake, Arc A380 (ANV) |
| ------------------------- | ---------------------------------- | ------- | ----------------- | ------------------------ | ------------------------ | ---------------------------------- | ---------------------------------- | ------------------------------------------ |
| Decode H.264 High, 8-bit  | 4096×4096, level 5.1, 17 DPB slots | none    | none              | not queryable over `adb` | not queryable over `adb` | 4096×4096, level 5.2, 17 DPB slots | 4096×4096, level 5.2, 17 DPB slots | none                                       |
| Decode H.265 Main/Main 10 | 8192×4352, level 5.1               | none    | none              |                          |                          | 8192×8192, level 6.1               | 8192×8192, level 6.1               | none                                       |
| Decode AV1 Main, 8/10-bit | 8192×4352, level 6.1, 9 DPB slots  | none    | none              |                          |                          | 8192×8192, level 7.3, 16 DPB slots | 8192×8192, level 7.3, 16 DPB slots | none                                       |
| Decode VP9 profile 0/2    | 8192×4352, level 6.2               | none    | none              |                          |                          | none                               | 8192×8192, level reported 1.0      | none                                       |
| Encode H.264 High         | 4096×4096                          | none    | none              |                          |                          | 4096×4096, level 5.2               | 4096×4096, level 5.2               | none                                       |
| Encode H.265 Main/Main 10 | 8192×4352                          | none    | none              |                          |                          | 8192×8192, level 6.2               | 8192×8192, level 6.2               | none                                       |
| Encode AV1 Main, 8/10-bit | 9070 XT only, 8192×4352, level 6.0 | none    | none              |                          |                          | none                               | 8192×8192, level 7.3               | none                                       |

- Every supported profile writes NV12 (8-bit) or P010 (10-bit) pictures in optimal
  tiling, the same formats the table above marks `V`.
- RADV reports the H.264 and H.265 encode level as 1.0 on both RDNA parts. RADV
  passes on the kernel's value (`ext->maxLevelIdc = cap ? cap->max_level : 0;` in
  [`radv_video.c`][radv-video] at `mesa-25.2.6`), so a library must not treat the
  encode level as a limit without a fallback.
- **The driver version decides as much as the silicon.** The same Radeon 610M
  exposes the full decode and encode set under Mesa 25.2.6 and no
  `VK_KHR_video_*` extension at all under Mesa 24.2.6 (the RTX 4060 laptop).
- The RTX 4060 (driver 565.77) exposes no VP9 decode and no AV1 encode through
  Vulkan, although its VA-API driver decodes VP9. The RTX 4090, the same Ada
  generation on driver 595.112.07, exposes both, so on NVIDIA too the driver
  decides. Levels are reported in full (H.264 5.2, HEVC 6.1/6.2, AV1 7.3), except
  VP9 decode, which the 4090's driver reports as level 1.0.
- **No Intel GPU reports a `VK_KHR_video_*` extension** under ANV: not the UHD
  770 or Lunar Lake iGPUs, and not the discrete Arc A380 (Mesa 25.0.7 and 26.2.5,
  all NixOS builds). The Intel media driver on the same GPUs has the widest
  VA-API lists here, encode included, and on the Arc A380 encodes AV1.
- **The Vega 56 has no Vulkan Video, but VA-API on the same card decodes and
  encodes H.264 and HEVC** (and decodes MPEG-2 and VC-1). Vulkan Video therefore
  covers less than the platform API on hardware still in use, which supports the
  decision to keep platform APIs beside it.

## Platform media APIs

| Report      | API            | Hardware decode                                                                                | Hardware encode                                                         |
| ----------- | -------------- | ---------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------- |
| RX 9070 XT  | VA-API         | H.264, HEVC Main/Main 10, VP9 0/2, AV1 0, JPEG                                                 | H.264, HEVC Main/Main 10, AV1 0                                         |
| 610M (both) | VA-API         | H.264, HEVC Main/Main 10, VP9 0/2, AV1 0, JPEG                                                 | H.264, HEVC Main/Main 10                                                |
| RX Vega 56  | VA-API         | MPEG-2, VC-1, H.264, HEVC Main/Main 10                                                         | H.264, HEVC Main                                                        |
| RTX 4060    | VA-API (NVDEC) | MPEG-2, VC-1, H.264, HEVC Main/10/12 and 4:4:4 8/10/12-bit, VP8, VP9 0/2, AV1 0                | none (the VA-API driver decodes only)                                   |
| UHD 770     | VA-API (`iHD`) | MPEG-2, VC-1, H.264, HEVC Main/10/12, 4:2:2 10/12, 4:4:4 8/10/12 and SCC, VP9 0–3, AV1 0, JPEG | MPEG-2, H.264, HEVC Main/10/12, 4:2:2 and 4:4:4 and SCC, VP9 0–3, JPEG  |
| RTX 4090    | VA-API         | not reported: `vainfo` exited 3 on the NVIDIA node                                             |                                                                         |
| Lunar Lake  | VA-API         | not reported: `vainfo` exited 3                                                                |                                                                         |
| Arc A380    | VA-API (`iHD`) | MPEG-2, H.264, HEVC Main/10/12, 4:2:2 10/12, 4:4:4 8/10/12 and SCC, VP9 0–3, AV1 0, JPEG       | H.264, HEVC Main/10, 4:2:2 10, 4:4:4 8/10 and SCC, VP9 0–3, AV1 0, JPEG |
| M4 Max      | VideoToolbox   | H.264, HEVC, AV1, VP9, ProRes 422 and 4444, JPEG                                               | not probed                                                              |
| Adreno 660  | MediaCodec     | H.264, HEVC, VP9 (to 4096×2176), MPEG-2                                                        | H.264, HEVC, HEIC (to 16384²)                                           |
| Adreno 830  | MediaCodec     | H.264, HEVC, VP9, AV1 (to 4096×2176)                                                           | H.264, HEVC, HEIC (to 16384²)                                           |

On macOS, VP9 reports as hardware only after the process calls
`VTRegisterSupplementalVideoDecoderIfAvailable`; without it the probe saw a
software decoder. On the Adreno 660 phone, AV1 is software only
(`c2.android.av1-dav1d.decoder` and `c2.android.av1.decoder`), which is the dav1d
fallback the video plan assumes; the Snapdragon 8 Elite decodes AV1 in hardware.
Neither phone's Vulkan driver advertises any `VK_KHR_video_*` extension, so on
these phones hardware video is reachable only through MediaCodec.

## Compute

| Property                                | Vega 56 | 9070 XT                        | 610M   | M4 Max          | Adreno 660    | Adreno 830 | RTX 4060                                           | RTX 4090                                                                          | UHD 770 | Lunar Lake                  | Arc A380                        |
| --------------------------------------- | ------- | ------------------------------ | ------ | --------------- | ------------- | ---------- | -------------------------------------------------- | --------------------------------------------------------------------------------- | ------- | --------------------------- | ------------------------------- |
| Subgroup size (min–max)                 | 64      | 32–64                          | 32–64  | 4–32            | 64            | 64         | 32                                                 | 32                                                                                | 8–32    | 16–32                       | 8–32                            |
| Shared memory per workgroup             | 64 KiB  | 64 KiB                         | 64 KiB | 32 KiB          | 32 KiB        | 32 KiB     | 48 KiB                                             | 48 KiB                                                                            | 48 KiB  | 128 KiB                     | 48 KiB                          |
| `shaderFloat16`, `shaderInt8`           | yes     | yes                            | yes    | yes             | not in vkjson | yes        | yes                                                | yes                                                                               | yes     | yes                         | yes                             |
| Cooperative matrix                      | no      | 16×16×16: f16, bf16, fp8, int8 | no     | no              | no            | no         | 16×16×16, 16×8×16, 16×8×8: f16; 16×{8,16}×32: int8 | 16×16×16, 16×8×16, 16×8×8: f16; 16×16×16: bf16; 16×16×32: fp8; 16×{8,16}×32: int8 | no      | 8×16×16: f16; 8×16×32: int8 | 8×8×16: f16, bf16; 8×8×32: int8 |
| `VK_EXT_external_memory_host` alignment | 4 KiB   | 4 KiB                          | 4 KiB  | 16 KiB          | absent        | absent     | 4 KiB                                              | 4 KiB                                                                             | absent  | 4 KiB                       | 4 KiB                           |
| `hostImageCopy` (Vulkan 1.4)            | no      | no                             | no     | yes             | no            | no         | extension only (driver is 1.3)                     | yes                                                                               | yes     | yes                         | yes                             |
| Memory decompression                    | no      | no                             | no     | no              | no            | no         | GDeflate 1.0 (`VK_NV_memory_decompression`)        | GDeflate 1.0 (`VK_EXT_memory_decompression`)                                      | no      | no                          | no                              |
| Device-local heap                       | 8 GiB   | 16 GiB                         | shared | 36 GiB, unified | unified       | unified    | 8 GiB                                              | 16 GiB                                                                            | shared  | shared                      | 6 GiB                           |

Only the NVIDIA GPUs expose memory decompression, with the GDeflate 1.0 method
and an effectively unbounded indirect count: the RTX 4060 on driver 565.77 as
`VK_NV_memory_decompression`, the RTX 4090 on 595.112.07 also as the
cross-vendor `VK_EXT_memory_decompression`. Every other device lacks both, so GPU
decompression has to exist as a compute shader the library ships, with the
driver path as an optimisation where present. Cooperative matrices are on the
RX 9070 XT, both NVIDIA GPUs, the Arc A380 (8×8 tiles; ANV also advertises
`VK_NV_cooperative_matrix2`) and Lunar Lake, the only iGPU with them, and the only device with 128 KiB of workgroup shared
memory.

## `io_uring`

The Linux hosts report every opcode a file-to-GPU path would use: `READ`,
`READ_FIXED`, `OPENAT2`, `STATX`, `FADVISE`, `READ_MULTISHOT`, `URING_CMD`,
`FUTEX_WAIT` and `FIXED_FD_INSTALL`, plus `READV_FIXED` from 6.15 on. Measured
against the 65 opcodes of the Linux 7.3-rc6 UAPI header, which the probe's
vendored `during` 0.6.0 binding (`sparkles:event-horizon-sys`) mirrors in full:

| Kernel (report)                                       | Opcodes | Missing                                                                                         |
| ----------------------------------------------------- | ------- | ----------------------------------------------------------------------------------------------- |
| 6.11 (RTX 4060 laptop)                                | 58      | `READV_FIXED`, `WRITEV_FIXED`, `RECV_ZC`, `EPOLL_WAIT` (6.15), `PIPE` (6.16), and the two below |
| 6.17 (Lunar Lake), 6.18 (Vega 56)                     | 63      | `NOP128`, `URING_CMD128` (6.19)                                                                 |
| 6.19 (9070 XT), 7.2 (Arc A380), 7.3 (RTX 4090 laptop) | 65      | none                                                                                            |

No opcode was added between 6.19 and 7.3-rc6; the identical counts are the
kernel's, not a limit of the probe. The setup features differ the same way: 6.11
lacks `MIN_TIMEOUT`, `RW_ATTR` and `NO_IOWAIT`. macOS has none; Android was not
probed from an app context.

The opcode probe answers only "does the kernel know this opcode". Schema 3 adds
the ring-less `IORING_REGISTER_QUERY` (Linux 6.18), which reports the setup,
enter and SQE flags a kernel accepts, and the `kernel.io_uring_disabled` and
`kernel.io_uring_group` sysctls; none of the reports above carries them yet. No
report shows whether a seccomp or io_uring BPF filter would refuse this
process, or which `URING_CMD` targets a driver implements.

## Gaps

- **VA-API on Lunar Lake and on the RTX 4090's node**: `vainfo` exited with
  status 3 on both, and those reports predate schema 2, so the cause was not
  recorded. A rerun with the current probe keeps `libva`'s error text.
- **Windows** (IoRing, DirectStorage, Media Foundation): the probe does not build
  for Windows; these stay _documented_.
- **On-device Android run**: Vulkan 1.2+ features, video capabilities and
  `io_uring` from an app's own context need the probe built for Android and run
  on the phone, not over `adb`.

## Sources

- [`media-hw-probe.d`][probe], and the nine raw reports linked from [Devices](#devices).
- [`radv_video.c`][radv-video], Mesa `mesa-25.2.6`, for the encode-level source.

<!-- References -->

[probe]: ./examples/media-hw-probe.d
[r-vega]: ./reports/linux-radeon-rx-vega56.json
[r-9070]: ./reports/linux-radeon-rx-9070-xt.json
[r-4060]: ./reports/linux-geforce-rtx-4060-laptop.json
[r-4090]: ./reports/linux-geforce-rtx-4090-laptop.json
[r-lnl]: ./reports/linux-intel-lunar-lake.json
[r-a380]: ./reports/linux-intel-arc-a380.json
[r-m4]: ./reports/macos-apple-m4-max.json
[r-adreno]: ./reports/android-adreno-660.json
[r-a830]: ./reports/android-adreno-830.json
[radv-video]: https://gitlab.freedesktop.org/mesa/mesa/-/blob/mesa-25.2.6/src/amd/vulkan/radv_video.c
