# `legacyPackages.buildDAndroidLib`: a D application's whole closure as one
# shared library per ABI — the `lib<name>.so` a NativeActivity APK loads.
#
# Raw ldc2, not dub: dub cannot drive a cross build. `-i` compiles every module
# the main file reaches (the in-tree closure and the registry deps unzipped
# from their flake inputs), so the module graph, not a source list, is the
# build surface — which is also why an Android build only ever type-checks the
# `version (Android)` code it actually reaches (see docs/specs/hue/android.md).
#
# Shared by hue (hue.nix) and the terminal (terminal.nix); anything either of
# them needs that the other does not is a parameter here, never a fork.
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
    in
    lib.optionalAttrs (androidHost system).supported {
      legacyPackages.buildDAndroidLib =
        {
          pname,
          # The `.so` stem: `lib<libName>.so`, which is also what the
          # manifest's `android.app.lib_name` names.
          libName,
          # The D entry module, relative to the repo root.
          mainFile,
          # Source directories (repo-relative): the closure `-I` paths plus
          # anything else the build reads (C shims, string imports).
          srcDirs,
          # The dub `versions` of the configuration being mirrored, including
          # the `Have_*` set of its dependency graph.
          versions,
          # dub-registry dependencies: `{ name; src; }` with `src` the
          # registry zip (a flake input).
          dubDeps ? [ ],
          stringImportDirs ? [ ],
          # C files compiled through ImportC. List implementation files
          # explicitly: -i reaches declarations but not unimported bodies.
          cFiles ? [ "libs/android/c/jni_c.c" ],
          # Extra ImportC include dirs (store paths).
          cIncludes ? [ ],
          # Static archives to link, per ABI: `abi: [ path ... ]`.
          staticLibs ? (abi: [ ]),
          description ? "D application as an Android shared library, per ABI",
        }:
        pkgs.stdenv.mkDerivation {
          inherit pname;
          version = "0.1.0";
          src = sources.sourceFor srcDirs;

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

            ${lib.concatMapStrings (t: ''
              # -gcc: link through the NDK clang at minSdk, not the API-21
              # driver ldc2.conf names, so every libc symbol resolves against
              # the stubs of the API level the APK actually declares.
              ldc2 -mtriple=${t.triple} -gcc=${t.cc} -relocation-model=pic -O2 \
                -preview=in -preview=dip1000 \
                ${toString (map (v: "-d-version=${v}") versions)} \
                ${toString (map (dir: "-J=${dir}") stringImportDirs)} \
                ${toString (map (dir: "-I=${dir}") srcDirs)} \
                ${toString (map (d: ''-I="$(echo dub-imports/${d.name}/*/source)"'') dubDeps)} \
                -P-U__SIZEOF_INT128__ \
                ${toString (map (inc: "-P-I${inc}") cIncludes)} \
                -P-I${ndk.sysrootInclude} \
                -i \
                ${mainFile} \
                ${toString cFiles} \
                ${toString (staticLibs t.abi)} \
                -shared -link-defaultlib-shared=false \
                -L-Wl,-u,ANativeActivity_onCreate \
                -L-Wl,--wrap=fopen \
                -L-llog -L-landroid -L-lEGL -L-lGLESv2 -L-lOpenSLES -L-lm -L-ldl \
                -L${ndk.pageAlignFlags} \
                -of=lib${libName}-${t.abi}.so
            '') (lib.attrValues ndk.targets)}

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            ${lib.concatMapStrings (t: ''
              install -Dm644 lib${libName}-${t.abi}.so $out/lib/${t.abi}/lib${libName}.so
            '') (lib.attrValues ndk.targets)}
            runHook postInstall
          '';

          # Unstripped for ndk-stack; the APK carries the same bytes so a device
          # tombstone symbolizes against this output directly.
          dontStrip = true;

          meta = {
            inherit description;
            platforms = (androidHost system).platforms;
          };
        };
    };
}
