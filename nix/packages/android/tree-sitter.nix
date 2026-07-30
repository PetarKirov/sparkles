# The tree-sitter C runtime cross-built for Android, one static archive per
# ABI, linked into libhue.so (the runtime — ts_parser_*, queries, cursors — is
# statically referenced by sparkles:syntax's precise engine; only the per-
# language grammar .so files stay dlopen'd, see ts-grammars.nix). The runtime
# amalgamates to a single C file, so this is one clang invocation per ABI.
#
# `src = pkgs.tree-sitter.src` pins the same runtime version the desktop links
# via pkg-config.
{ lib, ... }:
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

      tree-sitter-android = pkgs.stdenv.mkDerivation {
        pname = "tree-sitter-android";
        version = pkgs.tree-sitter.version;
        src = pkgs.tree-sitter.src;

        dontConfigure = true;

        buildPhase = ''
          runHook preBuild

          ${lib.concatMapStrings (t: ''
            mkdir -p out-${t.abi}
            ${t.cc} -c lib/src/lib.c -o out-${t.abi}/lib.o \
              -Ilib/include -Ilib/src -O2 -fPIC
            ${ndk.ar} rcs out-${t.abi}/libtree-sitter.a out-${t.abi}/lib.o
          '') (lib.attrValues ndk.targets)}

          runHook postBuild
        '';

        installPhase = ''
          runHook preInstall
          ${lib.concatMapStrings (t: ''
            install -Dm644 out-${t.abi}/libtree-sitter.a $out/lib/${t.abi}/libtree-sitter.a
          '') (lib.attrValues ndk.targets)}
          cp -r lib/include $out/include
          runHook postInstall
        '';

        meta = {
          description = "tree-sitter C runtime cross-built for Android, per ABI";
          homepage = "https://tree-sitter.github.io";
          license = lib.licenses.mit;
          platforms = [ "x86_64-linux" ];
        };
      };
    in
    lib.optionalAttrs (system == "x86_64-linux") {
      packages.tree-sitter-android = tree-sitter-android;
    };
}
