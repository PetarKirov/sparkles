# BLAKE3 against the C reference

Standalone D package comparing `sparkles.base.hash.blake3` with the official C
implementation, `libblake3` (which picks its own SIMD level at runtime). Only
this package links the C library; `sparkles:base` has no C dependency. The dev
shell provides `libblake3` and its `pkg-config` file.

## Correctness, then measurement

```sh
dub test --root=libs/base/bench/blake3 -b bench -- -i blake3_bench.agree
dub test --root=libs/base/bench/blake3 -b bench -- --bench \
  -i blake3_bench.throughput --group-by=size --bench-min-time=300
```

`blake3_bench.agree` checks every supported D backend against the C digest,
and the keyed and key-derivation modes' 1000-byte extended outputs, at lengths
from 0 to 3 MiB. The benchmark hashes 1 KiB, 64 KiB and 1 MiB inputs with each
supported D backend and the C library, one thread.

## Results

AMD Ryzen 9 7940HX (Zen 4), LDC 1.42.0 (`-O3 -mcpu=native`, assertions
live), `libblake3` 1.8.5 from nixpkgs, GB/s:

| Input  | D portable | D SSE4.1 | D AVX2 | D AVX-512 | C libblake3 |
| ------ | ---------: | -------: | -----: | --------: | ----------: |
| 1 KiB  |       0.96 |     1.19 |   1.19 |      1.19 |        1.23 |
| 64 KiB |       0.92 |     3.62 |   6.93 |      7.86 |        8.89 |
| 1 MiB  |       0.91 |     3.62 |   7.00 |      7.93 |        9.01 |

The best D backend is within 1.14× of the C library at 64 KiB and above, and
within 4% at 1 KiB (a single chunk, compressed one block at a time).

On an arm64 Android 14 phone (Cortex-A55), the `sparkles:base` test binary
from `legacyPackages.buildDAndroidTests` (`-O1`) measured NEON at 0.58 GB/s
against 0.19 GB/s portable at 64 KiB and 1 MiB.
