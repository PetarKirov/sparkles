# Shared builder for the executable sub-packages under `apps/`. Wraps nixpkgs'
# `buildDubPackage` with the sparkles-specific plumbing every app needs: the
# shared `nix/dub-lock.json`, an in-tree source fileset (the manifests of the
# root package's declared sub-packages plus the `.d`/`.c`/`.i` sources of the
# app's transitive `sparkles:*` closure), the writable-build-tree fixup dub
# needs, a `build/<pname>` install,
# `makeWrapper` on the build inputs, and a `remove-references-to` scrub *derived*
# from a default Phobos-leak set (minus anything in `buildInputs`) so callers
# configure the leak list in one place. The derivation returned to callers is
# a second step: it copies the compile and replaces a `{}` section with the
# build-info JSON. The compile does not see the commit, and the wrapper runs
# only after the replace.
#
# Exposed as `legacyPackages.buildSparklesApp` (flake-parts' escape hatch for
# non-derivation values — see `d-toolchain` for precedent); internal
# consumers call it via `config.legacyPackages.buildSparklesApp`.
#
# The manifest graph it reads is nix/packages/manifest-graph.nix, the
# build-info document it stamps nix/packages/build-info.nix.
{ lib, ... }:
{
  perSystem =
    { config, pkgs, ... }:
    let
      inherit (config.legacyPackages)
        nativeLibs
        assertBuildInfo
        buildInfoObjcopy
        buildInfoSectionName
        emptyBuildInfoJson
        inTreeComponents
        nativeComponents
        sparklesBuildInfo
        ;
      inherit (config.legacyPackages.sparklesSources)
        sourceFor
        needsUiShaders
        uiShaderDirs
        needsUiVulkanShaders
        placeUiShaders
        placeUiVulkanShaders
        ;
      sparklesSrcClosure = config.legacyPackages.sparklesSources.srcClosure;
      shippedComponentNames = config.legacyPackages.sparklesSources.componentNames;
      fromRoot = lib.path.append ../..;
    in
    {
      # Step 1 is `buildDubPackage` plus a stable `{}` section. Step 2 copies
      # it, replaces the section with the JSON, then runs the caller's
      # `postFixup` (makeWrapper records the ELF it execs, so the wrapper has
      # to be written after the replace). The commit is read only while
      # building step 2.
      #
      # Step 2 is opt-in (`stampBuildInfo = true`): its output changes with
      # every commit, so an app that is an input to other builds (`ui-shaders`)
      # or sits in the dev shell (`ci`) must not have one. Without it, step 1
      # runs the caller's `postFixup` itself and is the package; its
      # `--version` reports the unstamped `dev`. `checkBuildInfo` adds
      # app-specific assertions to `assertBuildInfo`.
      legacyPackages.buildSparklesApp =
        let
          unstampedSparklesApp = lib.extendMkDerivation {
            constructDrv = pkgs.buildDubPackage;

            # `sourceDirs`, `appDir` and `links` are consumed here, not mkDerivation
            # attributes.
            excludeDrvArgNames = [
              "sourceDirs"
              "appDir"
              "generatesShaders"
              "links"
              "stampBuildInfo"
              "checkBuildInfo"
            ];

            extendDrvArgs =
              finalAttrs: args:
              let
                # The application's directory: `apps/<pname>` unless another
                # configuration of an app is its own package (`terminal-raylib`).
                appDir = args.appDir or "apps/${finalAttrs.pname}";
                # Explicit `sourceDirs` override, else the computed closure.
                srcDirs = args.sourceDirs or (sparklesSrcClosure appDir);
                # ImportC's headers and the linked shaping libraries travel with
                # every raylib-text consumer, including transitive UI consumers.
                shapingInputs = lib.optionals (builtins.elem "libs/raylib-text/src" srcDirs) nativeLibs.shaping;
                # The window system's native libraries (`libs "wayland-client"
                # "xcb" … "xkbcommon-x11"` in libs/wsi, Linux-only) and the Vulkan
                # loader travel the same way, with every consumer of the native arm.
                wsiInputs = lib.optionals (builtins.elem "libs/wsi/src" srcDirs) nativeLibs.wsi;
                vulkanInputs = lib.optionals (builtins.elem "libs/vulkan/src" srcDirs) nativeLibs.vulkan;
                buildInputs = (args.buildInputs or [ ]) ++ shapingInputs ++ wsiInputs ++ vulkanInputs;
                dubBuildType = args.dubBuildType or "checked";
                stamp = args.stampBuildInfo or false;
                buildInfoComponents =
                  inTreeComponents (shippedComponentNames appDir) // nativeComponents buildInputs;

                # The build compiler. `ldc.reproducible` maps its own store paths
                # out of `__FILE__`, assertion messages and debug info
                # (nix/d-toolchain.nix, toolchain spec TC15), so none reaches the
                # program. A caller's compiler without that map leaves them, and
                # they are removed after the build.
                compiler = args.compiler or pkgs.ldc.reproducible;
                # Every layer of it — the driver join and each compiler it joins
                # over, down to the inner package whose `include/d` druntime's and
                # Phobos' sources are read from — asserted absent.
                layersOf = p: [ p ] ++ lib.optionals (p ? unwrapped) (layersOf p.unwrapped);
                compilerPaths = layersOf compiler ++ lib.optionals (compiler ? include) [ compiler.include ];
                # Phobos' service paths, the nixpkgs-patched `libcurl.so.4` dlopen
                # path and the tzdata directory: compiled into Phobos itself, and
                # never reached by a static program that loads neither, so they are
                # removed. A runtime dependency the caller lists in `buildInputs`
                # is a genuine reference, and stays.
                servicePaths = [
                  pkgs.curl.out
                  pkgs.tzdata
                ];
                # A caller's own `disallowedReferences` is removed as it was given.
                removed =
                  if args ? disallowedReferences then
                    disallowed
                  else
                    lib.subtractLists buildInputs (
                      servicePaths ++ lib.optionals (!(compiler.mapsStorePaths or false)) compilerPaths
                    );
                # The assertion. A package needing a compiler at run time (`ci`)
                # puts one on PATH in `postFixup`: not the build compiler's path,
                # so nothing here disallows it.
                disallowed = lib.subtractLists buildInputs (
                  args.disallowedReferences or (compilerPaths ++ servicePaths)
                );
                scrubFlags = lib.concatMapStringsSep " " (r: "-t ${r}") removed;
              in
              {
                # The toolchain's variables (nix/d-toolchain.nix): on macOS, the C
                # compiler `ldc2` links with and the SDK.
                env = args.env or config.legacyPackages.d-toolchain.env;

                # All sparkles nix packages share the one Nix-format lockfile.
                inherit compiler;

                dubLock = args.dubLock or (fromRoot "nix/dub-lock.json");

                # Which dub build type the app is compiled with (the build hook's
                # own knob, surfaced here so callers set it as an argument and get
                # a default they can read).
                #
                # `checked` — `optimize` + `inline` + `debugInfo`, and neither
                # `releaseMode` nor `debugMode` — is the repo's build for every
                # shipped artifact. The two dub defaults are each wrong for one:
                #
                #   * `release` implies `-release`, which deletes assert
                #     *expressions* outright. An assertion that never runs is not
                #     a cheap assertion, it is an absent one — and a call written
                #     inside an assert silently stops happening.
                #   * `debug` implies `-debug`, which compiles `debug { }` blocks
                #     in. Those exist to hold checks too expensive to ship (an
                #     `isSorted` over the whole input), so they do not belong in
                #     an artifact either.
                #
                # `checked` keeps assertions and drops the debug blocks, at ~3%
                # over `release` where it was measured (`apps/twoslash-extract`).
                # Where even that is too much for a hot path, the lever is
                # `-checkaction=halt` on that code — not deleting the check.
                inherit dubBuildType;

                # Not part of the derivation hash. Step 2 reads these; step 1's
                # builder must not.
                passthru = (args.passthru or { }) // {
                  # The D compiler, for `checks.d-compiler-is-fork` (toolchain
                  # spec TC1).
                  inherit compiler;
                  stampBuildInfo = stamp;
                  checkBuildInfo = args.checkBuildInfo or (doc: doc);
                  callerPostFixup = args.postFixup or "";
                  buildInfoLinks = args.links or { };
                  buildInfoBuildType = dubBuildType;
                  inherit buildInfoComponents;
                };

                src = args.src or (sourceFor (srcDirs ++ uiShaderDirs srcDirs));
                sourceRoot = args.sourceRoot or "${finalAttrs.src.name}/${appDir}";

                nativeBuildInputs =
                  (args.nativeBuildInputs or [ ])
                  ++ [
                    pkgs.makeWrapper
                    pkgs.llvm-binutils-sparkles
                    pkgs.lld-sparkles
                  ]
                  ++ lib.optional (shapingInputs != [ ]) pkgs.pkg-config;
                inherit buildInputs;

                # dub writes into the unpacked (read-only) source tree.
                preBuild =
                  (args.preBuild or ''chmod -R u+w "$NIX_BUILD_TOP"'')
                  + "\n"
                  + lib.optionalString (needsUiShaders srcDirs) (
                    placeUiShaders "$NIX_BUILD_TOP/${finalAttrs.src.name}"
                  )
                  # Not into a build that generates them: that is their source.
                  + lib.optionalString (needsUiVulkanShaders srcDirs && !(args.generatesShaders or false)) (
                    placeUiVulkanShaders "$NIX_BUILD_TOP/${finalAttrs.src.name}"
                  );

                # dub names the binary after the package (`appDir`), the derivation
                # after `pname`: they differ for a second configuration of an app
                # (`terminal-raylib`).
                installPhase =
                  args.installPhase or ''
                    install -Dm755 build/${baseNameOf appDir} $out/bin/${finalAttrs.pname}
                  '';

                disallowedReferences = disallowed;

                # Scrub compiler leaks, then add the stable `{}` section. A
                # stamped app's wrapper runs in step 2, after the JSON replaces
                # it; an unstamped app's runs here.
                postFixup =
                  (lib.optionalString (removed != [ ]) ''
                    find "$out" -type f -exec remove-references-to ${scrubFlags} '{}' +
                  '')
                  + ''
                    if [ -f "$out/bin/${finalAttrs.pname}" ]; then
                      ${buildInfoObjcopy {
                        section = buildInfoSectionName;
                        json = emptyBuildInfoJson;
                        target = ''"$out/bin/${finalAttrs.pname}"'';
                      }}
                    fi
                  ''
                  + lib.optionalString (!stamp) (args.postFixup or "");
              };
          };

          stampSparklesApp =
            step1:
            let
              pname = step1.pname;
              version = step1.version or "0.1.0";
              info = sparklesBuildInfo {
                name = "sparkles:${pname}";
                inherit version;
                buildType = step1.passthru.buildInfoBuildType or "checked";
                links = step1.passthru.buildInfoLinks or { };
                components = step1.passthru.buildInfoComponents or { };
              };
              # Forcing the checks here puts them on the path to the drvPath:
              # any build or `nix flake check` of the package evaluates them.
              checked = step1.passthru.checkBuildInfo (assertBuildInfo info.document);
              json = pkgs.writeText "build-info.json" (builtins.seq checked info.json);
            in
            pkgs.runCommand "${pname}-${version}"
              {
                inherit pname version;
                dontStrip = true;
                nativeBuildInputs = [
                  pkgs.llvm-binutils-sparkles
                  pkgs.makeWrapper
                ];
                passthru = {
                  unstamped = step1;
                  buildInfo = checked;
                };
                meta = step1.meta or { };
              }
              ''
                cp -a ${step1} "$out"
                chmod -R u+w "$out"
                if [ -f "$out/bin/${pname}" ]; then
                  ${buildInfoObjcopy {
                    section = buildInfoSectionName;
                    json = json;
                    target = ''"$out/bin/${pname}"'';
                    replace = true;
                  }}
                fi
                ${step1.passthru.callerPostFixup or ""}
              '';
        in
        callerArgs:
        let
          step1 = unstampedSparklesApp callerArgs;
        in
        if step1.passthru.stampBuildInfo then stampSparklesApp step1 else step1;

      # `legacyPackages.buildSparklesAndroidLib`: an app's `android` dub
      # configuration, built by dub for every ABI the NDK targets — the shared
      # library a NativeActivity loads, `lib/<abi>/lib<libName>.so`. dub cross
      # compiles (`--arch=<triple>`; the Android LDC's ldc2.conf sections give
      # each target its runtime and NDK driver), so the versions, configurations
      # and paths are the recipes' own, never a list kept here; pkg-config
      # (`android-pkg-config`, one directory per ABI) resolves the C libraries
      # the recipes name, and SPARKLES_ANDROID_MIN_SDK the API level
      # `sparkles:android` links for. Only evaluated where Android builds.
      legacyPackages.buildSparklesAndroidLib =
        {
          pname,
          appDir,
          # The `.so` stem: `lib<libName>.so`, the configuration's `targetName`
          # and what the manifest's `android.app.lib_name` names.
          libName,
          ldcAndroid,
          dubConfig ? "android",
          dubBuildType ? "checked",
          version ? "0.1.0",
          # Reserve the empty `.build_info` section `stampAndroidLib` patches
          # (`TPG2`), as the raw cross build's option of the same name does.
          emptyBuildInfo ? false,
          description ? "${appDir} as an Android shared library, per ABI, built by dub",
        }:
        let
          ndk = config.legacyPackages.androidNdk;
          # The JNI shim sits outside every source path (libs/android/dub.sdl).
          srcDirs = sparklesSrcClosure appDir ++ [ "libs/android/c" ];
          src = sourceFor (srcDirs ++ uiShaderDirs srcDirs);
          pkgConfig = config.packages.android-pkg-config;
        in
        pkgs.buildDubPackage {
          inherit pname version src;
          sourceRoot = "${src.name}/${appDir}";
          dubLock = fromRoot "nix/dub-lock.json";
          compiler = ldcAndroid;
          # lld links the host tools a pre-generate step builds (`shader-compile`,
          # which checks the prebuilt shaders' stamp), as for any app.
          nativeBuildInputs = [
            pkgs.pkg-config-unwrapped
            pkgs.llvm-binutils-sparkles
            pkgs.lld-sparkles
          ];
          preBuild = ''
            chmod -R u+w "$NIX_BUILD_TOP"
          ''
          + lib.optionalString (needsUiShaders srcDirs) (placeUiShaders "$NIX_BUILD_TOP/${src.name}")
          + lib.optionalString (needsUiVulkanShaders srcDirs) (
            placeUiVulkanShaders "$NIX_BUILD_TOP/${src.name}"
          );
          buildPhase = ''
            runHook preBuild
            ${lib.concatMapStrings (t: ''
              PKG_CONFIG_LIBDIR=${pkgConfig}/${t.abi} PKG_CONFIG_PATH= \
              SPARKLES_ANDROID_MIN_SDK=${ndk.minSdk} \
                dub build --skip-registry=all --compiler=ldc2 --arch=${t.triple} \
                  --config=${dubConfig} --build=${dubBuildType}
              install -Dm644 build/lib${libName}.so "$NIX_BUILD_TOP/android-libs/${t.abi}/lib${libName}.so"
              ${lib.optionalString emptyBuildInfo ''
                llvm-objcopy --add-section .build_info=${config.legacyPackages.emptyBuildInfoJson} \
                  "$NIX_BUILD_TOP/android-libs/${t.abi}/lib${libName}.so"
              ''}
            '') (lib.attrValues ndk.targets)}
            runHook postBuild
          '';
          installPhase = ''
            runHook preInstall
            mkdir -p $out/lib
            cp -r "$NIX_BUILD_TOP/android-libs/." $out/lib/
            runHook postInstall
          '';
          # Unstripped for ndk-stack, as the raw cross build leaves it; the APK
          # carries the bytes, not the store paths assert messages name.
          dontStrip = true;
          disallowedReferences = [ ];
          meta.description = description;
        };
    };
}
