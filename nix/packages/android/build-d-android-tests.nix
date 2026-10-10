# `legacyPackages.buildDAndroidTests`: a D package's unittests as one Android
# executable per ABI, run by sparkles:test-runner — the same runner, flags and
# output as `dub test`, pushed to a device or emulator with adb.
#
# Raw ldc2, as in build-d-android-lib.nix: dub cannot drive a cross build, so
# this derivation writes the `dub_test_root` module dub would generate (every
# module under `testedDirs`, `package.d` excepted, as dub omits it) and hands it
# to `-i` together with the runner's two halves: the shim's registration module
# and the impl's entry module, which `-i` cannot reach through the `extern(C)`
# seam between them. `libs/ui/src` stays off the import path; the runner's
# reports degrade to plain text without it.
{ inputs, lib, ... }:
let
  # Whether this system can build Android at all (./host.nix).
  androidHost = import ./host.nix { inherit inputs; };
in
{
  perSystem =
    {
      config,
      pkgs,
      system,
      ...
    }:
    let
      ndk = config.legacyPackages.androidNdk;
      sources = config.legacyPackages.sparklesSources;
      # The runner and the libraries its impl imports (sparkles:base and its
      # closure); its sparkles:ui dependency is left out on purpose (above).
      runnerDirs = sources.libsClosure [ "base" ] ++ [
        "libs/test-runner/src"
        "libs/test-runner-impl/src"
      ];
    in
    lib.optionalAttrs (androidHost system).supported {
      legacyPackages.buildDAndroidTests =
        {
          pname,
          # The executable's name on the device.
          exeName,
          # Source directories (repo-relative) whose every module the runner
          # tests: the package's `src`, and its test tree if it has one.
          testedDirs,
          # Further `-I` directories (repo-relative): the package's in-tree
          # dependency closure. The runner's own closure is added here.
          srcDirs ? [ ],
          # The dub `versions` of the configuration being mirrored, including
          # the `Have_*` set of its dependency graph.
          versions ? [ ],
          # dub-registry dependencies: `{ name; src; }` with `src` the
          # registry zip (a flake input). Their own unittests are not built.
          dubDeps ? [ ],
          description ? "D unittests as Android executables, per ABI",
        }:
        let
          importDirs = lib.unique (testedDirs ++ srcDirs ++ runnerDirs);
        in
        pkgs.stdenv.mkDerivation {
          inherit pname;
          version = "0.1.0";
          src = sources.sourceFor importDirs;

          nativeBuildInputs = [
            (androidHost system).ldcAndroid
            pkgs.unzip
          ];

          buildPhase = ''
            runHook preBuild

            ${lib.concatMapStrings (d: ''
              mkdir -p dub-imports/${d.name}
              (cd dub-imports/${d.name} && unzip -q ${d.src})
            '') dubDeps}

            modules=$(for dir in ${toString testedDirs}; do
              (cd "$dir" && find . -name '*.d' ! -name package.d)
            done | sed 's|^\./||; s|\.d$||; s|/|.|g' | sort)
            {
              echo 'module dub_test_root;'
              for m in $modules; do echo "static import $m;"; done
              echo 'alias allModules = imported!"std.meta".AliasSeq!('
              for m in $modules; do echo "    $m,"; done
              echo ');'
              echo 'void main() {}'
            } > dub_test_root.d

            ${lib.concatMapStrings (t: ''
              ldc2 -mtriple=${t.triple} -gcc=${t.cc} -relocation-model=pic -O1 \
                -preview=in -preview=dip1000 -unittest -checkaction=context -allinst \
                ${toString (map (v: "-d-version=${v}") versions)} \
                ${toString (map (dir: "-I=${dir}") importDirs)} \
                ${toString (map (d: ''-I="$(echo dub-imports/${d.name}/*/source)" -i=-${d.name}'') dubDeps)} \
                -i dub_test_root.d \
                libs/test-runner/src/sparkles/test_runner/register.d \
                libs/test-runner-impl/src/sparkles/test_runner/runner_impl.d \
                -link-defaultlib-shared=false -L-pie -L-llog -L-lm -L-ldl \
                -L-Wl,--warn-unresolved-symbols \
                -of=${exeName}-${t.abi}
            '') (lib.attrValues ndk.targets)}

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            ${lib.concatMapStrings (t: ''
              install -Dm755 ${exeName}-${t.abi} $out/bin/${t.abi}/${exeName}
            '') (lib.attrValues ndk.targets)}
            runHook postInstall
          '';

          dontStrip = true;

          meta = {
            inherit description;
            platforms = (androidHost system).platforms;
          };
        };
    };
}
