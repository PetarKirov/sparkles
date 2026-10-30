# Opt-in Win32 cross-compilation + Wine test shell.
#
# Kept separate from the default shell on purpose: the MSVC CRT + Windows SDK
# import libraries (`windows.sdk`, splatted by `xwin`) are *unfree* (and must
# never be pushed to a public cache), and Wine is a sizable closure. Only the
# Win32 windowing demos under
# `docs/research/window-system-integration/os-apis/win32/` need it. Enter with:
#
#     nix develop .#win32
#
# Pipeline (verified end-to-end on 2026-10-30) — one command compiles AND
# links, because the project `ldc` (dlang.nix's `ldc-vulkan`, the
# PetarKirov/ldc fork; see nix/d-toolchain.nix) has LLD built in:
#
#     win32-ldc2 app.d -of=build/app.exe
#     WINEPREFIX=$(mktemp -d) WINEDEBUG=-all wine build/app.exe
#
# `win32-ldc2` is `ldc2 -mtriple=x86_64-pc-windows-msvc -link-internally
# -L/DEFAULTLIB:msvcrt` plus the /LIBPATHs below. Notes baked into the wiring:
#
#   - druntime and Phobos for the target are cross-built by the host
#     compiler's own `ldc-build-runtime`, from its own source
#     (nix/packages/ldc-win32-runtime.nix), so their version is the
#     compiler's; evaluation asserts it. Their C parts, and ImportC's
#     preprocessing, go through the fork LLVM's `clang --driver-mode=cl`.
#   - MinGW import libs (as LDC's release archives bundle) are NOT a
#     substitute for the SDK: exes linked against them page-fault at startup
#     under Wine (UCRT-built druntime vs classic-msvcrt startup stubs).
#   - The CRT is msvcrt, named with `/DEFAULTLIB:msvcrt`. LDC's own default,
#     `vcruntime140`, maps (case shim) to SDK's `vcruntime.lib`, which lacks
#     the startup code: alone, the link dies on `wmainCRTStartup`. And
#     `-mscrtlib=msvcrt` trips an assertion in linker-msvc.cpp: off Windows
#     LDC always takes its "internal toolchain" (MinGW libs) path, which
#     asserts a vcruntime CRT name. Release builds compile the assert out;
#     the fork's does not.
#   - The case shim covers LDC's default-lib names that the xwin splat spells
#     differently on a case-sensitive filesystem (`Bcrypt.lib`,
#     `vcruntime140.lib`).
#   - Wine needs SOME display server: on this host it loads winewayland against
#     the live wayland-0 socket (or the x11 driver under Xvfb); with no display
#     at all CreateWindowExW fails (error 1400). The loaded driver changes
#     behavior (winewayland swallows WM_SYSCOMMAND SC_SIZE/SC_MOVE; the x11
#     driver runs Wine's generic modal loop) — F03 findings have the details.
#     Do NOT run demos via `wine explorer /desktop=…` — it swallows the
#     child's stdout & exit code.
#
# `lib` is taken from the flake-level module args (see android.nix for why).
{ lib, inputs, ... }:
{
  perSystem =
    {
      system,
      config,
      inputs',
      pkgs,
      ...
    }:
    let
      inherit (config.legacyPackages) d-toolchain;

      # `windows.sdk` requires allowUnfree + the explicit Microsoft license
      # acceptance, so it comes from a separately-configured import of the
      # same nixpkgs pin (the per-system `pkgs` is configured without unfree).
      pkgsUnfree = import inputs.nixpkgs {
        inherit system;
        config = {
          allowUnfree = true;
          microsoftVisualStudioLicenseAccepted = true;
        };
      };
      # nixpkgs' xwin fixed-output fetch is intentionally tiny and, at this
      # pin, does not include a CA bundle. xwin 0.9 uses rustls and therefore
      # fails with "No CA certificates were loaded" before it can fetch the
      # accepted Microsoft SDK payload. Supply the bundle to the fetch
      # derivation itself; adding cacert only to the eventual dev shell is too
      # late because the SDK has already been built by then.
      winSdkBase = pkgsUnfree.windows.sdk;
      winSdk = winSdkBase.overrideAttrs (old: {
        src = old.src.overrideAttrs (fetchOld: {
          nativeBuildInputs = (fetchOld.nativeBuildInputs or [ ]) ++ [ pkgs.cacert ];
          SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
        });
      });

      # The raw clang of the LLVM the host LDC is built on: in cl mode, for the
      # runtime's C parts and ImportC's preprocessor.
      clang = inputs'.dlang-nix.packages.clang-sparkles-unwrapped;

      # druntime/Phobos for the MSVC target, cross-built from the source of
      # the `ldc2` on the shell's PATH. `pkgs.ldc` wraps dlang.nix's package
      # (nix/d-toolchain.nix), which wraps the compiler build itself.
      hostLdc = pkgs.ldc.unwrapped;
      ldcWin32Runtime = pkgs.callPackage ../packages/ldc-win32-runtime.nix {
        ldc = hostLdc.unwrapped;
        inherit clang winSdk;
      };
      ldcWindowsLibs =
        assert lib.assertMsg (
          ldcWin32Runtime.version == hostLdc.version
        ) "the Win32 runtime is LDC ${ldcWin32Runtime.version}, the host compiler ${hostLdc.version}";
        "${ldcWin32Runtime}/lib";

      caseShim = pkgs.runCommand "win-sdk-case-shim" { } ''
        mkdir -p $out
        ln -s ${winSdk}/sdk/lib/um/x64/bcrypt.lib $out/Bcrypt.lib
        ln -s ${winSdk}/crt/lib/x64/vcruntime.lib $out/vcruntime140.lib
      '';

      # Only `clang-cl` (the runtime's `clang --driver-mode=cl` wrapper) on
      # PATH: the rest of the unwrapped LLVM view would shadow the native
      # toolchain.
      clangCl = pkgs.runCommand "clang-cl" { } ''
        mkdir -p $out/bin
        ln -s ${ldcWin32Runtime.clangCl} $out/bin/clang-cl
      '';

      win32Ldc2 = pkgs.writeShellScriptBin "win32-ldc2" ''
        exec ldc2 -mtriple=x86_64-pc-windows-msvc -link-internally -L/DEFAULTLIB:msvcrt \
          --gcc=${ldcWin32Runtime.clangCl} \
          "-L/LIBPATH:${ldcWindowsLibs}" \
          "-L/LIBPATH:${winSdk}/crt/lib/x64" \
          "-L/LIBPATH:${winSdk}/sdk/lib/um/x64" \
          "-L/LIBPATH:${winSdk}/sdk/lib/ucrt/x64" \
          "-L/LIBPATH:${caseShim}" \
          "$@"
      '';

      win32Shell = pkgs.mkShell {
        packages = [
          # `stable`, not `minimal`: only it has the X11 driver, without which
          # Wine creates no window at all.
          pkgs.wine64Packages.stable
          clangCl
          win32Ldc2
          # What the Wine lanes (`libs/*/scripts/verify-*-wine.sh`) run: a
          # display, and `pkg-config` for the Vulkan headers.
          pkgs.xvfb-run
          pkgs.pkg-config
          pkgs.vulkan-loader.dev
        ]
        ++ d-toolchain.packages;
        shellHook = ''
          ${d-toolchain.shellExports}
          export LDC_WINDOWS_LIBDIR=${ldcWindowsLibs}
          export WIN32_SDK=${winSdk}
        '';
      };
    in
    # Cross-linking COFF + Wine: exercised on x86_64-linux only.
    lib.optionalAttrs (system == "x86_64-linux") {
      devShells.win32 = win32Shell;
    };
}
