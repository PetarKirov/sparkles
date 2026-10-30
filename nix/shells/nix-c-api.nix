# The Nix C API `sparkles:nix` binds through ImportC, as the dev and CI
# shells provide it: the libraries to link, and a pkg-config path whose
# headers ImportC can parse. Exported as `legacyPackages.nixCApi`.
{
  perSystem =
    { pkgs, ... }:
    let
      inherit (pkgs) lib;

      # The Nix C API libraries `sparkles:nix` binds, as nixpkgs builds them:
      # cache.nixos.org has them, so no Nix source build.
      nixCLibs = pkgs.nixVersions.latest.libs;

      # LDC's ImportC cannot parse the C23 `[[deprecated(...)]]` attribute that
      # `nix_api_value.h` / `nix_api_expr.h` put on the deprecated `Value`
      # typedef (which `sparkles:nix` does not use). Strip it from a copy of
      # `nix-expr-c`'s dev output and repoint the pkg-config includedir at the
      # patched headers. Prepending this on PKG_CONFIG_PATH (below) makes it
      # win over the unpatched copy that `nix-flake-c` propagates.
      nix-expr-c-dev-patched = pkgs.runCommand "nix-expr-c-dev-patched" { } ''
        cp -r ${nixCLibs.nix-expr-c.dev} $out
        chmod -R u+w $out
        sed -i -E 's/\[\[[^]]*\]\]//g' \
          $out/include/nix_api_value.h \
          $out/include/nix_api_expr.h
        substituteInPlace $out/lib/pkgconfig/nix-expr-c.pc \
          --replace-quiet ${nixCLibs.nix-expr-c.dev} $out
      '';

      # All Nix C API headers are supplied via pkg-config (PKG_CONFIG_PATH),
      # NOT via buildInputs `.dev` outputs — otherwise the nix cc wrapper would
      # inject the unpatched nix-expr-c include dir into NIX_CFLAGS_COMPILE and
      # shadow nix-expr-c-dev-patched. The patched expr dev is listed first.
      nixCApiPkgConfigPath = lib.makeSearchPath "lib/pkgconfig" [
        nix-expr-c-dev-patched
        nixCLibs.nix-util-c.dev
        nixCLibs.nix-store-c.dev
        nixCLibs.nix-fetchers-c.dev
        nixCLibs.nix-flake-c.dev
        nixCLibs.nix-main-c.dev
      ];

    in
    {
      legacyPackages.nixCApi = {
        # Only the `out` outputs (the .so's), for linking; headers come
        # through `pkgConfigPath`, so the patched nix-expr-c headers are used
        # and the unpatched ones never reach NIX_CFLAGS_COMPILE.
        libs = [
          nixCLibs.nix-util-c
          nixCLibs.nix-store-c
          nixCLibs.nix-expr-c
          nixCLibs.nix-fetchers-c
          nixCLibs.nix-flake-c
          nixCLibs.nix-main-c
        ];
        pkgConfigPath = nixCApiPkgConfigPath;
      };
    };
}
