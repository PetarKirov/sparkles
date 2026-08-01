# Grammar parsers cross-compiled for Android: one `libtree_sitter_<lang>.so`
# (`-` folded to `_`) per language per ABI, shipped in the APK's `lib/<abi>/`
# so the app's classloader linker namespace resolves them by bare soname —
# `GrammarRegistry.fromSonames` dlopens `grammarSoname(lang)` with no paths and
# no env vars. (Extracted app storage is not an option: targetSdk ≥ 29 forbids
# exec-mmap of writable app files.)
#
# Sources come from the same `pkgs.tree-sitter-grammars` pins the desktop
# bundle uses. Multi-grammar repos (markdown, typescript, ocaml) are handled
# generically: among the `*/src/parser.c` candidates, the one whose
# grammar-root basename equals `<lang>` or `tree-sitter-<lang>` wins, else the
# single candidate. A C++ scanner (`scanner.cc`) switches the link to clang++
# with `-static-libstdc++`.
#
# Queries are NOT here: the APK reuses the desktop bundle's normalized
# `queries/` dirs (nix/packages/ts-grammars.nix) as extracted assets — see
# hue.nix.
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
      g = pkgs.tree-sitter-grammars;

      # Same language list as nix/packages/ts-grammars.nix.
      languages = [
        "bash"
        "c"
        "c-sharp"
        "cpp"
        "css"
        "d"
        "go"
        "haskell"
        "html"
        "java"
        "javascript"
        "json"
        "kotlin"
        "markdown"
        "markdown-inline"
        "nix"
        "python"
        "rust"
        "scala"
        "toml"
        "typescript"
        "tsx"
        "ocaml"
        "xml"
        "yaml"
        "zig"
      ];

      soname = lang: "libtree_sitter_${builtins.replaceStrings [ "-" ] [ "_" ] lang}.so";

      grammarSo =
        lang:
        let
          grammar = g."tree-sitter-${lang}";
        in
        pkgs.stdenv.mkDerivation {
          pname = "ts-grammar-android-${lang}";
          version = grammar.version;
          src = grammar.src;

          dontConfigure = true;

          buildPhase = ''
            runHook preBuild

            # Pick the grammar root: exact basename match beats the first
            # candidate (multi-grammar repos: markdown vs markdown-inline,
            # typescript vs tsx, ocaml's grammars/ dir).
            candidates=$(find . -path '*/src/parser.c' | sort)
            pick=""
            for c in $candidates; do
              base=$(basename "$(dirname "$(dirname "$c")")")
              if [ "$base" = "${lang}" ] || [ "$base" = "tree-sitter-${lang}" ]; then
                pick=$c
                break
              fi
            done
            [ -n "$pick" ] || pick=$(echo "$candidates" | head -1)
            [ -n "$pick" ] || { echo "no src/parser.c found for ${lang}" >&2; exit 1; }
            gsrc=$(dirname "$pick")
            echo "grammar root for ${lang}: $gsrc"

            scanner=""
            cxxlink=""
            [ -f "$gsrc/scanner.c" ] && scanner="$gsrc/scanner.c"
            if [ -f "$gsrc/scanner.cc" ]; then
              scanner="$gsrc/scanner.cc"
              cxxlink=1
            fi

            ${lib.concatMapStrings (t: ''
              cc=${t.cc}
              extra=""
              if [ -n "$cxxlink" ]; then
                cc=${t.cxx}
                extra="-static-libstdc++"
              fi
              # shellcheck disable=SC2086
              "$cc" -shared -fPIC -O2 -I"$gsrc" "$pick" $scanner $extra \
                ${ndk.pageAlignFlags} \
                -o ${soname lang}-${t.abi}
            '') (lib.attrValues ndk.targets)}

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            ${lib.concatMapStrings (t: ''
              install -Dm644 ${soname lang}-${t.abi} $out/lib/${t.abi}/${soname lang}
            '') (lib.attrValues ndk.targets)}
            runHook postInstall
          '';

          meta = {
            description = "tree-sitter ${lang} grammar cross-built for Android, per ABI";
            platforms = [ "x86_64-linux" ];
          };
        };

      grammarSos = lib.genAttrs languages grammarSo;

      # One tree: lib/<abi>/libtree_sitter_<lang>.so for every language.
      ts-grammars-android =
        pkgs.runCommand "sparkles-ts-grammars-android"
          {
            meta = {
              description = "tree-sitter grammar parsers cross-built for Android, per ABI";
              platforms = [ "x86_64-linux" ];
            };
          }
          ''
            mkdir -p $out
            ${lib.concatMapStrings (
              lang:
              lib.concatMapStrings (t: ''
                install -Dm644 ${grammarSos.${lang}}/lib/${t.abi}/${soname lang} \
                  $out/lib/${t.abi}/${soname lang}
              '') (lib.attrValues ndk.targets)
            ) languages}
          '';
    in
    lib.optionalAttrs (system == "x86_64-linux") {
      packages.ts-grammars-android = ts-grammars-android;

      # The soname set as *data*, so consumers never have to look inside the
      # derivation to learn what it contains. `builtins.readDir` on a store
      # path with derivation context is import-from-derivation: it forces the
      # whole grammar closure (NDK + 27 cross-compiled parsers) to be REALISED
      # during evaluation, which drags `nix flake check` — a pure-evaluation
      # step in the 12-minute `test` job — into building the Android world.
      # The names are computable, so compute them.
      legacyPackages.tsGrammarsAndroid = {
        inherit languages soname;
        sonames = map soname languages;
      };
    };
}
