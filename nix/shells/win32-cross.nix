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
# Pipeline (verified end-to-end on 2026-06-10):
#
#   1. compile:  ldc2 -mtriple=x86_64-pc-windows-msvc -c app.d -of=app.obj
#   2. link:     win32-link app.obj /OUT:app.exe /SUBSYSTEM:CONSOLE
#   3. run:      WINEPREFIX=$(mktemp -d) WINEDEBUG=-all wine64 app.exe
#
# Notes baked into the wrapper/script choices:
#   - nixpkgs' ldc2 is built *without* integrated LLD, so `-link-internally`
#     is rejected — hence the standalone `lld-link` (wrapped as `win32-link`
#     with the LIBPATHs and the default-lib set the COFF objects don't carry).
#   - LDC's bundled mingw import libs are NOT a substitute for the SDK: exes
#     linked against them page-fault at startup under Wine (UCRT-built
#     druntime vs classic-msvcrt startup stubs).
#   - Wine's null driver delivers WM_PAINT/message-pump behavior fully
#     headless (no DISPLAY needed). Do NOT run demos via
#     `wine explorer /desktop=…` — it swallows the child's stdout & exit code.
#
# `lib` is taken from the flake-level module args (see android.nix for why).
{ lib, inputs, ... }:
{
  perSystem =
    {
      system,
      config,
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

      win32Link = pkgs.writeShellScriptBin "win32-link" ''
        exec lld-link "$@" \
          "/LIBPATH:${ldcWindowsLibs}" \
          "/LIBPATH:${winSdk}/crt/lib/x64" \
          "/LIBPATH:${winSdk}/sdk/lib/um/x64" \
          "/LIBPATH:${winSdk}/sdk/lib/ucrt/x64" \
          druntime-ldc.lib phobos2-ldc.lib msvcrt.lib \
          legacy_stdio_definitions.lib kernel32.lib user32.lib gdi32.lib
      '';

      win32Shell = pkgs.mkShell {
        packages = [
          pkgs.lld
          pkgs.wine64Packages.minimal
          win32Link
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
