/**
D bindings for the foreign-engine shims (`shims/include/wired_bench_shim.h`),
imported through ImportC. Header cflags and the link recipe (our static lib,
libstdc++, simdjson) resolve through `wired-bench-cpp-shim.pc`, installed by
the ISA-preset build in `nix/packages/wired-bench-cpp-shim.nix`.
*/
module sparkles.bench_shim;

public import sparkles.bench_shim.bench_shim_c;
