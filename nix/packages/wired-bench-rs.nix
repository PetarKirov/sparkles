# The Rust staticlib shim (serde_json + simd-json + sonic-rs) for the wired
# runtime JSON bench, built reproducibly from the checked-in Cargo.lock once
# per ISA preset (uwidth-rs precedent, but installing a linkable .a + .pc
# instead of a binary). sonic-rs dispatches SIMD at compile time, so the
# preset's -C target-cpu directly determines its kernels.
{ lib, ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      fs = lib.fileset;
      presets = import ./wired-bench-isa-presets.nix pkgs;

      crate = ../../libs/wired/bench/runtime/shims/rust;
      src = fs.toSource {
        root = crate;
        fileset = fs.unions [
          (crate + "/Cargo.toml")
          (crate + "/Cargo.lock")
          (crate + "/build.rs")
          (crate + "/src")
        ];
      };

      mkShim =
        preset:
        pkgs.rustPlatform.buildRustPackage {
          pname = "wired-bench-rs-${preset.attr}";
          version = "0.1.0";
          inherit src;
          cargoLock.lockFile = crate + "/Cargo.lock";

          env.RUSTFLAGS = lib.optionalString (
            preset.rustTargetCpu != null
          ) "-C target-cpu=${preset.rustTargetCpu}";

          # panic = "abort" in the release profile breaks `cargo test` builds.
          doCheck = false;

          installPhase = ''
            runHook preInstall
            install -Dm644 target/*/release/libwired_bench_rs.a \
              $out/lib/libwired_bench_rs.a
            mkdir -p $out/lib/pkgconfig
            cat > $out/lib/pkgconfig/wired-bench-rs.pc <<EOF
            Name: wired-bench-rs
            Description: Rust JSON engines (${preset.isa} build for the wired runtime bench)
            Version: 0.1.0
            Libs: -L$out/lib -lwired_bench_rs -lpthread -ldl -lm
            EOF
            runHook postInstall
          '';
        };
    in
    {
      packages = lib.listToAttrs (
        map (p: {
          name = "wired-bench-rs-${p.attr}";
          value = mkShim p;
        }) presets
      );
    };
}
