# Hardware matrix

What the machines available to the image and video work actually expose, measured
with one probe rather than taken from vendor documentation: CPU SIMD features,
`io_uring` opcodes, Vulkan texture and YCbCr formats, Vulkan Video profiles,
compute features and the platform media API.

| Field        | Value                                                                         |
| ------------ | ----------------------------------------------------------------------------- |
| Probe        | [`media-hw-probe.d`][probe], flake app `media-hw-probe`                       |
| Probe build  | one build, schema `sparkles.media-hw-probe/1`, for every report below         |
| Reports      | four: two Linux desktops, one Mac, one Android phone (raw JSON in `reports/`) |
| Missing      | Intel (Lunar Lake), NVIDIA, Snapdragon 8 Elite, Windows; see [Gaps](#gaps)    |
| Contributing | [Run the probe](./contributing.md)                                            |

**Last reviewed:** October 28, 2026

Every cell on this page is _verified on device_: it is what the driver or the
operating system reported to the probe on the date above. A claim about hardware
that is not in this table is _documented_ only, and the catalog marks it so.

## Devices

| Report                     | OS and kernel                      | CPU                                   | GPUs, Vulkan driver                                                            | Media API           |
| -------------------------- | ---------------------------------- | ------------------------------------- | ------------------------------------------------------------------------------ | ------------------- |
| [RX Vega 56][r-vega]       | NixOS 25.11, Linux 6.18.26         | Ryzen 9 7940HX (Zen 4), 32 threads    | Radeon RX Vega 56 and Radeon 610M iGPU; RADV, Mesa 25.2.6, Vulkan 1.4.318      | VA-API, `radeonsi`  |
| [RX 9070 XT][r-9070]       | NixOS 25.11, Linux 6.19.7          | Ryzen 9 7940HX (Zen 4), 32 threads    | Radeon RX 9070 XT (GFX1201) and Radeon 610M iGPU; RADV, Mesa 25.2.6            | VA-API, `radeonsi`  |
| [Apple M4 Max][r-m4]       | macOS 27.0.1                       | M4 Max, 10 performance + 4 efficiency | M4 Max through MoltenVK 1.4.2, Vulkan 1.4.357                                  | VideoToolbox        |
| [Snapdragon 888][r-adreno] | Android 14 (SDK 34), Linux 5.4.289 | SM8350, 8 cores                       | Adreno 660, Qualcomm driver of January 2023, Vulkan 1.1.128 (`cmd gpu vkjson`) | MediaCodec (Codec2) |

The Android report is collected from the host over `adb`, so its Vulkan section
comes from `cmd gpu vkjson`, which carries no Vulkan 1.2+ feature structs and no
video capabilities; its `io_uring` row is empty for the same reason.

## CPU SIMD

| Feature                                 | Zen 4 (both Linux hosts) | Apple M4 Max | Snapdragon 888 |
| --------------------------------------- | ------------------------ | ------------ | -------------- |
| AVX2, FMA, F16C                         | yes                      | -            | -              |
| AVX-512 F, BW, VL, DQ, CD               | yes                      | -            | -              |
| AVX-512 VBMI, VBMI2, IFMA               | yes                      | -            | -              |
| AVX-512 VNNI, BF16, BITALG              | yes                      | -            | -              |
| AVX-512 FP16                            | no                       | -            | -              |
| GFNI, VAES, VPCLMULQDQ                  | yes                      | -            | -              |
| NEON (Advanced SIMD), FP16              | -                        | yes          | yes            |
| Dot product (`asimddp`, `FEAT_DotProd`) | -                        | yes          | yes            |
| I8MM, BF16                              | -                        | yes          | no             |
| SVE, SVE2                               | -                        | no           | no             |
| SME, SME2                               | -                        | yes          | no             |

The reports show which features the kernel enabled, not how fast they run: Zen 4
executes 512-bit instructions on 256-bit units, and that cost needs a benchmark,
not a probe. The M4 Max reports SME and SME2 but no SVE, and the phone neither, so
NEON with dot product is the AArch64 baseline these devices share.

## Texture and YCbCr formats

Optimal-tiling support. `S` sampled, `L` linear filtering, `W` storage image,
`Y` YCbCr conversion with linear filtering, `V` usable as a Vulkan Video picture;
`-` not supported; blank cells were not reported.

| Format                                             | Vega 56 | 9070 XT | 610M | M4 Max | Adreno 660 |
| -------------------------------------------------- | ------- | ------- | ---- | ------ | ---------- |
| `BC1_RGBA_UNORM_BLOCK` … `BC7_UNORM_BLOCK`         | SL      | SL      | SL   | SL     | -          |
| `BC6H_UFLOAT_BLOCK`                                | SL      | SL      | SL   | SL     | -          |
| `ETC2_R8G8B8A8_UNORM_BLOCK`, `EAC_R11G11`          | SL      | -       | -    | SL     | SL         |
| `ASTC_4x4_UNORM_BLOCK` (LDR)                       | -       | -       | -    | SL     | SL         |
| `ASTC_4x4_SFLOAT_BLOCK` (HDR)                      | -       | -       | -    | SL     |            |
| `E5B9G9R9_UFLOAT_PACK32`                           | SL      | SL      | SL   | SL     | SL         |
| `B10G11R11_UFLOAT_PACK32`, `R16G16B16A16_SFLOAT`   | SLW     | SLW     | SLW  | SLW    | SLW        |
| `A2B10G10R10_UNORM_PACK32`                         | SLW     | SLW     | SLW  | SLW    | SLW        |
| `G8B8G8R8_422_UNORM` (YUY2)                        | -       | -       | -    | SLY    | S          |
| `G8_B8R8_2PLANE_420_UNORM` (NV12)                  | SLY     | SLYV    | SLYV | SLY    | SLY        |
| `G8_B8_R8_3PLANE_420_UNORM` (I420)                 | SLY     | SLY     | SLY  | SLY    | SLY        |
| `G10X6_B10X6R10X6_2PLANE_420_UNORM_3PACK16` (P010) | SLY     | SLYV    | SLYV | SLY    | -          |
| `G12X4_B12X4R12X4_2PLANE_420_UNORM_3PACK16` (P012) | SLY     | SLYV    | SLYV | SLY    |            |
| `G16_B16R16_2PLANE_420_UNORM` (P016)               | SLY     | SLY     | SLY  | SLY    |            |
| `G8_B8R8_2PLANE_444_UNORM`, 10-bit 4:4:4           | -       | -       | -    | -      |            |

No single compressed family is universal across these four: BCn is absent on the
phone, ASTC on every AMD part, and ETC2 on the RDNA parts. Uncompressed HDR
(`E5B9G9R9`, `B10G11R11`, half float) and NV12 with sampler YCbCr conversion are.
That is the case for a transcoding path (Basis Universal, KTX2) rather than one
shipped compressed format, and for NV12/P010 as the decoded-video interchange.

## Vulkan Video

Profiles queried with `vkGetPhysicalDeviceVideoCapabilitiesKHR`; extents are the
maximum coded extent; levels are as reported.

| Profile                   | 9070 XT and 610M (RDNA 4, RDNA 2)  | Vega 56 | M4 Max (MoltenVK) | Adreno 660               |
| ------------------------- | ---------------------------------- | ------- | ----------------- | ------------------------ |
| Decode H.264 High, 8-bit  | 4096×4096, level 5.1, 17 DPB slots | none    | none              | not queryable over `adb` |
| Decode H.265 Main/Main 10 | 8192×4352, level 5.1               | none    | none              |                          |
| Decode AV1 Main, 8/10-bit | 8192×4352, level 6.1, 9 DPB slots  | none    | none              |                          |
| Decode VP9 profile 0/2    | 8192×4352, level 6.2               | none    | none              |                          |
| Encode H.264 High         | 4096×4096                          | none    | none              |                          |
| Encode H.265 Main/Main 10 | 8192×4352                          | none    | none              |                          |
| Encode AV1 Main, 8/10-bit | 9070 XT only, 8192×4352, level 6.0 | none    | none              |                          |

- Every supported profile writes NV12 (8-bit) or P010 (10-bit) pictures in optimal
  tiling, the same formats the table above marks `V`.
- RADV reports the H.264 and H.265 encode level as 1.0 on both RDNA parts. RADV
  passes on the kernel's value (`ext->maxLevelIdc = cap ? cap->max_level : 0;` in
  [`radv_video.c`][radv-video] at `mesa-25.2.6`), so a library must not treat the
  encode level as a limit without a fallback.
- **The Vega 56 has no Vulkan Video, but VA-API on the same card decodes and
  encodes H.264 and HEVC** (and decodes MPEG-2 and VC-1). Vulkan Video therefore
  covers less than the platform API on hardware still in use, which supports the
  decision to keep platform APIs beside it.

## Platform media APIs

| Report      | API          | Hardware decode                                  | Hardware encode                 |
| ----------- | ------------ | ------------------------------------------------ | ------------------------------- |
| RX 9070 XT  | VA-API       | H.264, HEVC Main/Main 10, VP9 0/2, AV1 0, JPEG   | H.264, HEVC Main/Main 10, AV1 0 |
| 610M (both) | VA-API       | H.264, HEVC Main/Main 10, VP9 0/2, AV1 0, JPEG   | H.264, HEVC Main/Main 10        |
| RX Vega 56  | VA-API       | MPEG-2, VC-1, H.264, HEVC Main/Main 10           | H.264, HEVC Main                |
| M4 Max      | VideoToolbox | H.264, HEVC, AV1, VP9, ProRes 422 and 4444, JPEG | not probed                      |
| Adreno 660  | MediaCodec   | H.264, HEVC, VP9 (to 4096×2176), MPEG-2          | H.264, HEVC, HEIC (to 16384²)   |

On macOS, VP9 reports as hardware only after the process calls
`VTRegisterSupplementalVideoDecoderIfAvailable`; without it the probe saw a
software decoder. On the phone, AV1 is software only (`c2.android.av1-dav1d.decoder`
and `c2.android.av1.decoder`), which is the dav1d fallback the video plan assumes.

## Compute

| Property                                | Vega 56 | 9070 XT                        | 610M   | M4 Max          | Adreno 660    |
| --------------------------------------- | ------- | ------------------------------ | ------ | --------------- | ------------- |
| Subgroup size (min–max)                 | 64      | 32–64                          | 32–64  | 4–32            | 64            |
| Shared memory per workgroup             | 64 KiB  | 64 KiB                         | 64 KiB | 32 KiB          | 32 KiB        |
| `shaderFloat16`, `shaderInt8`           | yes     | yes                            | yes    | yes             | not in vkjson |
| Cooperative matrix                      | no      | 16×16×16: f16, bf16, fp8, int8 | no     | no              | no            |
| `VK_EXT_external_memory_host` alignment | 4 KiB   | 4 KiB                          | 4 KiB  | 16 KiB          | absent        |
| `hostImageCopy` (Vulkan 1.4)            | no      | no                             | no     | yes             | no            |
| Memory decompression                    | no      | no                             | no     | no              | no            |
| Device-local heap                       | 8 GiB   | 16 GiB                         | shared | 36 GiB, unified | unified       |

None of the probed devices exposes `VK_EXT_memory_decompression` or
`VK_NV_memory_decompression`; GPU decompression on these machines is a compute
shader the library ships, not a driver feature.

## `io_uring`

Both Linux hosts (kernels 6.18 and 6.19) report every opcode a file-to-GPU path
would use: `READ`, `READ_FIXED`, `READV_FIXED`, `OPENAT2`, `STATX`, `FADVISE`,
`READ_MULTISHOT`, `URING_CMD`, `FUTEX_WAIT`, `FIXED_FD_INSTALL`, and the setup
features `EXT_ARG`, `REG_REG_RING`, `RW_ATTR` and `NO_IOWAIT`. The 6.19 kernel adds
two opcodes over 6.18 (65 against 63). macOS has none; Android was not probed
from an app context.

## Gaps

- **Intel Lunar Lake** (Core Ultra 256V, NixOS): reachable when connected; adds
  ANV Vulkan Video, the Intel media driver for VA-API, and an x86 part without
  AVX-512.
- **NVIDIA** (RTX 4060/4090 mobile): collected last, by colleagues running the
  flake app; adds NVDEC/NVENC through Vulkan Video and `nvidia-smi`, and
  `VK_NV_memory_decompression` if the driver exposes it.
- **Snapdragon 8 Elite** (Adreno 830): a current Android GPU, to compare with the
  Adreno 660's Vulkan 1.1 floor.
- **Windows** (IoRing, DirectStorage, Media Foundation): the probe does not build
  for Windows; these stay _documented_.
- **On-device Android run**: Vulkan 1.2+ features, video capabilities and
  `io_uring` from an app's own context need the probe built for Android and run
  on the phone, not over `adb`.

## Sources

- [`media-hw-probe.d`][probe], and the four raw reports linked from [Devices](#devices).
- [`radv_video.c`][radv-video], Mesa `mesa-25.2.6`, for the encode-level source.

<!-- References -->

[probe]: ./examples/media-hw-probe.d
[r-vega]: ./reports/linux-radeon-rx-vega56.json
[r-9070]: ./reports/linux-radeon-rx-9070-xt.json
[r-m4]: ./reports/macos-apple-m4-max.json
[r-adreno]: ./reports/android-adreno-660.json
[radv-video]: https://gitlab.freedesktop.org/mesa/mesa/-/blob/mesa-25.2.6/src/amd/vulkan/radv_video.c
