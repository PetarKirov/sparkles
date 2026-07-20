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
# Pipeline (verified end-to-end on 2026-06-10) — one command compiles AND
# links, because `win32-ldc2` wraps dlang.nix's `ldc-binary-1_41_0`, the
# official upstream release binary, which ships with integrated LLD (the
# project-wide `pkgs.ldc` stays nixpkgs' source build, which is built
# without LLD and rejects `-link-internally`):
#
#     win32-ldc2 app.d -of=build/app.exe
#     WINEPREFIX=$(mktemp -d) WINEDEBUG=-all wine64 build/app.exe
#
# `win32-ldc2` is `ldc2 -mtriple=x86_64-pc-windows-msvc -link-internally
# -mscrtlib=msvcrt` plus the /LIBPATHs below. Notes baked into the wiring:
#
#   - The Windows druntime/phobos import libs come from the official LDC
#     release archive for the *same version* as the host compiler.
#     TODO(dlang.nix): replace the local fetch with
#     `inputs'.dlang-nix.packages.ldc-binary-windows-libs.override { … }`
#     once the `feat/ldc-windows-cross-libs` branch lands in the pinned input.
#   - LDC's bundled mingw import libs are NOT a substitute for the SDK: exes
#     linked against them page-fault at startup under Wine (UCRT-built
#     druntime vs classic-msvcrt startup stubs).
#   - `-mscrtlib=msvcrt` is required: LDC otherwise selects `vcruntime140`
#     as the CRT lib and the link dies on `wmainCRTStartup`.
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

      # The cross compiler: the official upstream release binary (integrated
      # LLD, so `-link-internally` works). Deliberately NOT the project-wide
      # `pkgs.ldc` — the closure scrubs in nix/packages/{default,examples}.nix
      # are built around nixpkgs' ldc and its separate `include` output. Keep
      # the version in lockstep with `ldcWindowsLibs` below — cross-linking
      # mixes this compiler with the Windows druntime/phobos import libs of
      # the same release.
      ldcBinary = inputs'.dlang-nix.packages."ldc-binary-1_41_0";

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
      winSdk = pkgsUnfree.windows.sdk;

      # Windows druntime/phobos import libs from the official LDC release
      # archive — fixed-output fetch, in lockstep with the pinned host LDC.
      ldcVersion = "1.41.0";
      ldcWindowsLibs = pkgs.stdenvNoCC.mkDerivation {
        pname = "ldc-windows-x64-libs";
        version = ldcVersion;
        src = pkgs.fetchurl {
          url = "https://github.com/ldc-developers/ldc/releases/download/v${ldcVersion}/ldc2-${ldcVersion}-windows-x64.7z";
          hash = "sha256-HbEeXu7RAjZynUXN6GH7UZfRzHFrQYZgD8p/xrtIyBA=";
        };
        nativeBuildInputs = [ pkgs.p7zip ];
        unpackPhase = "7z x $src";
        installPhase = ''
          mkdir -p $out
          cp -r ldc2-${ldcVersion}-windows-x64/lib/* $out/
        '';
      };

      caseShim = pkgs.runCommand "win-sdk-case-shim" { } ''
        mkdir -p $out
        ln -s ${winSdk}/sdk/lib/um/x64/bcrypt.lib $out/Bcrypt.lib
        ln -s ${winSdk}/crt/lib/x64/vcruntime.lib $out/vcruntime140.lib
      '';

      win32Ldc2 = pkgs.writeShellScriptBin "win32-ldc2" ''
        exec ${ldcBinary}/bin/ldc2 -mtriple=x86_64-pc-windows-msvc -link-internally -mscrtlib=msvcrt \
          "-L/LIBPATH:${ldcWindowsLibs}" \
          "-L/LIBPATH:${winSdk}/crt/lib/x64" \
          "-L/LIBPATH:${winSdk}/sdk/lib/um/x64" \
          "-L/LIBPATH:${winSdk}/sdk/lib/ucrt/x64" \
          "-L/LIBPATH:${caseShim}" \
          "$@"
      '';

      win32Shell = pkgs.mkShell {
        packages = [
          pkgs.wine64Packages.minimal
          win32Ldc2
        ]
        ++ d-toolchain.packages;
        shellHook = ''
          ${lib.concatStringsSep "\n" (
            lib.mapAttrsToList (name: value: "export ${name}=${lib.escapeShellArg value}") d-toolchain.env
          )}
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
