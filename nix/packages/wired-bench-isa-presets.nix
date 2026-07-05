# ISA presets for the nix-built engines of the wired runtime JSON bench
# (libs/wired/bench/runtime). The nix sandbox forbids `-march=native`, so
# every native engine derivation is built once per preset and the devshell
# picks the best preset the host supports at shell entry (see
# nix/shells/default.nix, $WIRED_BENCH_ISA). The D side of the bench needs
# no presets — dub builds it outside the sandbox with `-mcpu=native`.
#
# Not a flake-parts module: a plain function from `pkgs` to the preset list.
#   attr  — package attribute suffix (wired-bench-yyjson-${attr})
#   isa   — the human-readable name stamped into reports ($WIRED_BENCH_ISA)
#   cflags       — C/C++ codegen flag(s)
#   rustTargetCpu — rustc -C target-cpu= value (null = leave default)
pkgs:
let
  inherit (pkgs.stdenv) hostPlatform;
in
if hostPlatform.isx86_64 then
  [
    {
      attr = "v2";
      isa = "x86-64-v2";
      cflags = "-march=x86-64-v2";
      rustTargetCpu = "x86-64-v2";
    }
    {
      attr = "v4";
      isa = "x86-64-v4";
      cflags = "-march=x86-64-v4";
      rustTargetCpu = "x86-64-v4";
    }
  ]
else if hostPlatform.isAarch64 && hostPlatform.isDarwin then
  [
    {
      attr = "apple-m1";
      isa = "apple-m1";
      cflags = "-mcpu=apple-m1";
      rustTargetCpu = "apple-m1";
    }
  ]
else
  # aarch64-linux and anything else: NEON (or the platform baseline) is
  # already the default target; build one generic preset.
  [
    {
      attr = "generic";
      isa = "generic";
      cflags = "";
      rustTargetCpu = null;
    }
  ]
