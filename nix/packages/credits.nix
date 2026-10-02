# The credits document (docs/credits/, docs/specs/terminal/pages.md
# TPG12–TPG16): its licence texts, staged from each component's own source,
# and the bundle the documentation site and the APKs both carry.
#
#   packages.credits                    docs/credits/*.md + parts/ + licenses/
#   legacyPackages.sparklesCredits      { bundle; notice = app: …; }
#
# The parts are the single source. Each part's `Version source` field says
# where the component comes from, and its include directives say which of
# that source's files are its licence texts: a part that includes
# `../licenses/<id>/COPYING` gets `COPYING` copied from that source to
# `licenses/<id>/COPYING`. A named file the source lacks fails the build, so
# a site built from this bundle has every licence its parts include.
#
# `docs/scripts/build-credits.sh` copies `licenses/` into the docs tree for
# `yarn docs:build` (it is git-ignored there), and the APK builders copy the
# whole bundle as assets — the same derivation, so the two cannot disagree
# (TPG16). `ci --check-credits` checks the parts against the build inputs.
{ inputs, lib, ... }:
{
  perSystem =
    { config, pkgs, ... }:
    let
      creditsDir = ../../docs/credits;
      partsDir = creditsDir + "/parts";

      dubLock = (lib.importJSON ../dub-lock.json).dependencies;

      partIds = map (lib.removeSuffix ".md") (
        builtins.filter (lib.hasSuffix ".md") (builtins.attrNames (builtins.readDir partsDir))
      );

      lines = text: lib.splitString "\n" text;
      firstMatch =
        re: text:
        let
          ms = builtins.filter (m: m != null) (map (builtins.match re) (lines text));
        in
        if ms == [ ] then null else builtins.head ms;
      allMatches = re: text: builtins.filter (m: m != null) (map (builtins.match re) (lines text));

      # A `| Name | value |` row of a part's field table; null when absent.
      field =
        name: text:
        let
          m = firstMatch "[[:space:]]*\\|[[:space:]]*${name}[[:space:]]*\\|[[:space:]]*(.*[^[:space:]])[[:space:]]*\\|[[:space:]]*" text;
        in
        if m == null then null else builtins.head m;

      plain = s: builtins.replaceStrings [ "`" "<" ">" ] [ "" "" "" ] s;

      readPart =
        id:
        let
          text = builtins.readFile (partsDir + "/${id}.md");
          required =
            name:
            let
              v = field name text;
            in
            if v == null then throw "docs/credits/parts/${id}.md: no `${name}` field" else v;
          source = builtins.match "(flake input|nixpkgs|dub package|grammar bundle) `([^`]+)`.*" (
            required "Version source"
          );
          heading = firstMatch "### (.*)" text;
        in
        if source == null then
          throw "docs/credits/parts/${id}.md: unreadable `Version source`"
        else
          {
            inherit id;
            name = if heading == null then id else builtins.head heading;
            kind = builtins.elemAt source 0;
            ref = builtins.elemAt source 1;
            licence = plain (required "Licence");
            home = plain (required "Home");
            notice = field "Notice" text;
            files = map builtins.head (
              allMatches ".*<!--[[:space:]]*@include:[[:space:]]*\\.\\./licenses/${id}/([^[:space:]]+)[[:space:]]*-->.*" text
            );
          };

      parts = lib.genAttrs partIds readPart;

      # Where a part's licence files are read from.
      sourceOf =
        p:
        if p.kind == "flake input" then
          inputs.${p.ref}
        else if p.kind == "nixpkgs" then
          (lib.attrByPath (lib.splitString "." p.ref) (throw "credits: no nixpkgs attribute `${p.ref}`") pkgs)
          .src
        else if p.kind == "dub package" then
          "${config.packages.dub-sources}/.dub/packages/${p.ref}/${dubLock.${p.ref}.version}/${p.ref}"
        else
          null;

      # " — MIT" from nixpkgs' licence metadata, or nothing when it has none
      # (most grammar packages carry none; their own licence file follows).
      spdxSuffix =
        l:
        lib.optionalString (l != null) (
          " — " + lib.concatMapStringsSep " AND " (m: m.spdxId or m.shortName or "unknown") (lib.toList l)
        );

      # The grammar bundle has one part and many sources: its one licence file
      # is generated, every grammar's upstream licence under its own header.
      grammarEntries =
        let
          s = config.legacyPackages.tsGrammarSources;
        in
        lib.mapAttrsToList (name: g: {
          label = "tree-sitter-${name} ${g.version}${spdxSuffix g.license}";
          inherit (g) src;
          location = if g.location == null then "." else g.location;
        }) s.grammars
        ++ [
          {
            label = "nvim-treesitter ${s.nvim-treesitter.version} (the latex and unison highlight queries)${spdxSuffix s.nvim-treesitter.license}";
            inherit (s.nvim-treesitter) src;
            location = ".";
          }
        ];

      stagePart =
        p:
        if p.kind == "grammar bundle" then
          ''
            mkdir -p "$out/licenses/${p.id}"
            {
              echo "The tree-sitter grammars hue ships, each with the licence its source carries."
              ${lib.concatMapStrings (g: ''
                echo
                echo "==== ${g.label} ===="
                echo
                licenceText ${g.src} ${lib.escapeShellArg g.location}
              '') grammarEntries}
            } > "$out/licenses/${p.id}/${builtins.head p.files}"
          ''
        else
          ''
            stage ${p.id} ${sourceOf p} ${lib.escapeShellArgs p.files}
          '';

      bundle =
        pkgs.runCommand "sparkles-credits"
          {
            nativeBuildInputs = [ pkgs.unzip ];
            pages = lib.fileset.toSource {
              root = creditsDir;
              fileset = lib.fileset.fileFilter (f: f.hasExt "md") creditsDir;
            };
            meta.description = "The credits document with its staged licence texts";
          }
          ''
            # The licence root of a source: the directory itself, or the one
            # directory an archive unpacks to (a zip of loose files is its
            # own root).
            sourceRoot() {
              if [ -d "$1" ]; then
                echo "$1"
                return
              fi
              local tmp
              tmp=$(mktemp -d)
              (cd "$tmp" && unpackFile "$1" >&2)
              local entries=("$tmp"/*)
              if [ ''${#entries[@]} -eq 1 ] && [ -d "''${entries[0]}" ]; then
                echo "''${entries[0]}"
              else
                echo "$tmp"
              fi
            }

            stage() {
              local id=$1 src=$2 root
              shift 2
              root=$(sourceRoot "$src")
              for f in "$@"; do
                if [ ! -f "$root/$f" ]; then
                  echo "credits: docs/credits/parts/$id.md includes $f, which $src does not have" >&2
                  exit 1
                fi
                install -Dm644 "$root/$f" "$out/licenses/$id/$f"
              done
            }

            # A grammar's licence: the first licence-like file in the
            # grammar's own directory (its `location` in a monorepo), then at
            # the source root. A grammar with none fails the build — its
            # credit would otherwise be a header over nothing.
            licenceText() {
              local root dir f
              root=$(sourceRoot "$1")
              for dir in "$root/$2" "$root"; do
                for f in "$dir"/LICENSE* "$dir"/LICENCE* "$dir"/COPYING* "$dir"/license*; do
                  if [ -f "$f" ]; then
                    cat "$f"
                    return
                  fi
                done
              done
              echo "credits: no licence file in $1 ($2)" >&2
              exit 1
            }

            mkdir -p $out
            cp -r $pages/. $out/
            chmod -R u+w $out

            ${lib.concatMapStrings stagePart (lib.attrValues parts)}
          '';

      # The APK's plain NOTICE (TPG16), generated from the parts the
      # application's page includes.
      notice =
        app:
        let
          page = builtins.readFile (creditsDir + "/${app}.md");
          ids = map builtins.head (
            allMatches ".*<!--[[:space:]]*@include:[[:space:]]*\\./parts/([^[:space:]]+)\\.md[[:space:]]*-->.*" page
          );
        in
        pkgs.writeText "${app}-NOTICE" ''
          sparkles:${app} links or bundles the third-party components below. Their
          licence texts are in credits/licenses/, and credits/${app}.md says what
          each one does here. Generated from docs/credits/ — do not edit.

          ${lib.concatMapStrings (
            id:
            let
              p = parts.${id};
            in
            ''
              ${p.name}
                licence: ${p.licence}
                home:    ${p.home}
              ${lib.optionalString (p.notice != null) "  notice:  ${plain p.notice}\n"}
            ''
          ) ids}
          sparkles itself is BSL-1.0; see its LICENSE.
        '';
    in
    {
      packages.credits = bundle;
      legacyPackages.sparklesCredits = {
        inherit bundle notice;
      };
    };
}
