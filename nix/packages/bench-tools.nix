# Third-party terminal benchmark tools, pinned and packaged so the benchmark
# harness (apps/terminal-benchmark) and the dev shell have a reproducible,
# always-available environment instead of relying on ad-hoc local clones.
#
#   - vtebench (alacritty): generates escape-sequence workloads and times how
#     long writing to the terminal blocks (sink throughput).
#   - termbench (cmuratori): measures how fast a terminal accepts large output.
#
# Neither is in nixpkgs, so both are flake inputs pinned in flake.lock.
{ inputs, ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      packages.vtebench = pkgs.rustPlatform.buildRustPackage {
        pname = "vtebench";
        version = "0.3.1-unstable-2025-01-20";

        src = inputs.vtebench-src;

        # Use the vendored lockfile (fetched per-crate via fetchurl) instead of
        # cargoHash: the cargo-vendor fetcher hits the crates.io API without a
        # User-Agent and gets a 403, whereas fetchurl's curl UA is accepted.
        # The lockfile is pinned to the same revision as `src` above.
        cargoLock.lockFile = ./vtebench-Cargo.lock;

        # The benchmark definitions under `benchmarks/` are data the runtime
        # `--benchmarks` flag points at; install them alongside the binary so a
        # packaged vtebench is self-contained.
        postInstall = ''
          mkdir -p $out/share/vtebench
          cp -r benchmarks extra_benchmarks $out/share/vtebench/
        '';

        meta = {
          description = "Terminal emulator benchmark (alacritty/vtebench)";
          homepage = "https://github.com/alacritty/vtebench";
          mainProgram = "vtebench";
        };
      };

      packages.termbench = pkgs.stdenv.mkDerivation {
        pname = "termbench";
        version = "2-unstable-2024-03-19";

        src = inputs.termbench-src;

        # Single translation unit; the repo's build.sh just invokes the
        # compiler with -O3. -Ofast is upstream's flag but adds nothing for a
        # plain output sink, so stick to -O3.
        buildPhase = ''
          runHook preBuild
          $CXX -O3 -o termbench termbench.cpp
          runHook postBuild
        '';

        installPhase = ''
          runHook preInstall
          install -Dm755 termbench $out/bin/termbench
          runHook postInstall
        '';

        meta = {
          description = "Terminal output throughput benchmark (cmuratori/termbench)";
          homepage = "https://github.com/cmuratori/termbench";
          mainProgram = "termbench";
        };
      };
    };
}
