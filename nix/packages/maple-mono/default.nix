# Maple Mono, rebuilt with a fixed set of OpenType features baked in (upstream
# ships them as optional `cvXX`/`ssXX` alternates, which a terminal or GPU text
# renderer cannot switch on — there is no shaping layer to ask).
#
# `patch_maple.hy` is VENDORED, from https://github.com/reo101/rix101 — it is
# not first-party, which matters because AGENTS.md requires substantial scripts
# to be written in D. That rule is about logic *this repository* owns; carrying
# an upstream build script in its original language is the ordinary cost of
# vendoring, and rewriting it would fork it from the source it tracks.
#
# It drives upstream's own Python build (`build.py`): regex surgery over the
# four `.fea` feature files, generation of the `calt`/`ss03` lookup blocks for
# the pill keywords, and a line patch to `build.py` itself.
{
  lib,
  stdenvNoCC,
  runCommand,
  unzip,
  python3,
  src,
  cnBaseStatic,
  ufoExtractorWheel,

  enableNerdFont ? true,
  enableCN ? true,
  enableHinting ? false,
  enableLigature ? true,
  # Frozen OpenType features (e.g. cvXX, ssXX)
  features ? [
    "cv03"
    "cv08"
    "cv61"
    "cv64"
    "ss07"
    "ss08"
    "ss09"
    "ss10"
    "zero"
  ],
  # Glyph names for characters that trigger thinned backslash (e.g. "one" for \1)
  extraEscapeChars ? [
    "zero"
    "one"
    "two"
    "three"
    "four"
    "five"
    "six"
    "seven"
    "eight"
    "nine"
  ],
  # Keywords to turn into pills (e.g. `["TASK" "DONE"]`)
  # Automatically mapped to tag styles based on length (4, 5, or 7).
  pillKeywords ? [
    "TODO"
    "TASK"
    "FIXME"
    "BUG"
  ],
  # Remove alt pill syntax (`todo))`)
  disableAltPill ? true,
  # Build specific subfamily for smaller derivation (e.g. "Regular")
  buildStyle ? null,
}:

let
  ps = python3.pkgs;

  # Flake `type = "file"` inputs land in the store as `…-source` with no
  # extension. `format = "wheel"` only recognises a `*.whl` path, so rename.
  ufoExtractorWhl = runCommand "ufo_extractor-0.8.1-py2.py3-none-any.whl" { } ''
    cp ${ufoExtractorWheel} $out
  '';

  ufo-extractor = ps.buildPythonPackage {
    pname = "ufo-extractor";
    version = "0.8.1";
    format = "wheel";
    src = ufoExtractorWhl;
    dependencies = [
      ps.fonttools
      ps.fontfeatures
    ];
    doCheck = false;
  };

  foundrytools = ps.buildPythonPackage (finalAttrs: {
    pname = "foundrytools";
    version = "0.1.4";
    pyproject = true;
    src = ps.fetchPypi {
      inherit (finalAttrs) pname version;
      hash = "sha256-pWHSIhj0g1jUs6ij5o2NGcDBrgJDBCXjQyJmSpYOxfo=";
    };
    build-system = [ ps.setuptools ];
    dependencies = [
      ps.afdko
      ps.fonttools
      ps.skia-pathops
      ps.brotli
      ps.ttfautohint-py
      ps.dehinter
      ps.ufo2ft
      ps.cffsubr
      ufo-extractor
    ];
    doCheck = false;
  });

  foundrytools-cli = ps.buildPythonPackage (finalAttrs: {
    pname = "foundrytools-cli";
    version = "2.0.2";
    pyproject = true;
    src = ps.fetchPypi {
      pname = "foundrytools_cli";
      inherit (finalAttrs) version;
      hash = "sha256-wOs6ka+M4vAvi4ydTdFHRbOvocyjI7gHWJ/n3YrV2Ws=";
    };
    build-system = [ ps.hatchling ];
    dependencies = [
      foundrytools
      ps.afdko
      ps.fonttools
      ps.skia-pathops
      ps.brotli
      ps.click
      ps.rich
      ps.loguru
      ps.pathvalidate
    ];
    doCheck = false;
  });

  python-minifier = ps.buildPythonPackage (finalAttrs: {
    pname = "python-minifier";
    version = "3.1.0";
    pyproject = true;
    src = ps.fetchPypi {
      pname = "python_minifier";
      inherit (finalAttrs) version;
      hash = "sha256-hbzPmbd1alIdaqO/XwCVDifslIDqYtZu2VW9uO7CTBQ=";
    };
    build-system = [ ps.setuptools ];
    doCheck = false;
  });

  pythonEnv = python3.withPackages (ps: [
    ps.fonttools
    ps.glyphslib
    ps.ttfautohint-py
    ps.brotli
    ps.skia-pathops
    ps.setuptools
    ps.hy
    foundrytools-cli
    python-minifier
  ]);
in

stdenvNoCC.mkDerivation (
  finalAttrs:
  let
    no = bool: lib.optionalString (!bool) "no-";

    outDir =
      if enableNerdFont && enableCN then
        "NF-CN"
      else if enableNerdFont then
        "NF"
      else if enableCN then
        "CN"
      else if enableHinting then
        "TTF-AutoHint"
      else
        "TTF";

    fontName =
      "Maple Mono" + lib.optionalString enableNerdFont " NF" + lib.optionalString enableCN " CN";
  in
  {
    pname = "maple-mono-custom";
    version = "7.9";

    inherit src;

    nativeBuildInputs = [
      pythonEnv
      unzip
    ];

    # KNOWN: this build is not reproducible. `nix build --rebuild` reports the
    # derivation as possibly non-deterministic.
    #
    # What was measured, so the next attempt does not start from zero:
    #   * ~574 bytes differ out of a ~20 MB face, clustered from offset ~193 —
    #     i.e. in the table directory (checksums/offsets), not in glyph data;
    #   * the `head` table's created AND modified timestamps are IDENTICAL
    #     across runs, so it is not a clock and SOURCE_DATE_EPOCH is already
    #     being honoured;
    #   * `PYTHONHASHSEED = 0` does NOT fix it — tried and measured, so the
    #     cause is not Python string-hash randomisation. Most likely an
    #     iteration- or ordering-sensitive step inside the font tooling that
    #     lays tables out differently between runs.
    #
    # Consequence worth knowing: the APK is bit-reproducible (build-apk.nix)
    # only for a *fixed* font input. Rebuild the font and the APK changes too.
    # Fixing this means going into upstream's build.py, which is vendored —
    # so it belongs upstream rather than as a local patch.

    postUnpack = ''
      ${lib.optionalString enableCN ''
        mkdir -p $sourceRoot/source/cn/static
        ${lib.getExe unzip} ${cnBaseStatic} -d $sourceRoot/source/cn/static
      ''}
      cp ${./patch_maple.hy} $sourceRoot/patch_maple.hy
      pushd $sourceRoot
      ${pythonEnv}/bin/hy patch_maple.hy \
        ${lib.escapeShellArg (lib.concatStringsSep "," extraEscapeChars)} \
        ${lib.escapeShellArg (lib.concatStringsSep "," pillKeywords)} \
        ${if disableAltPill then "1" else "0"}
      popd
    '';

    buildPhase =
      let
        featFlag =
          lib.optionalString (features != [ ])
            "--feat ${
              lib.pipe features [
                (lib.map lib.escapeShellArg)
                (lib.concatStringsSep ",")
              ]
            }";
        styleFlag = lib.optionalString (buildStyle != null) "--style ${lib.escapeShellArg buildStyle}";
      in
      # bash
      ''
        runHook preBuild
        python build.py ${featFlag} ${styleFlag} --apply-fea-file --${no enableHinting}hinted --${no enableLigature}liga --${no enableNerdFont}nf --${no enableCN}cn
        runHook postBuild
      '';

    installPhase =
      # bash
      ''
        runHook preInstall

        test -d "fonts/${outDir}" || { echo "Expected output dir fonts/${outDir} not found"; exit 1; }

        find "fonts/${outDir}" -maxdepth 1 -type f -name '*.ttf' \
          -exec install -Dm444 -t "$out/share/fonts/truetype" {} \;
        find "fonts/${outDir}" -maxdepth 1 -type f -name '*.otf' \
          -exec install -Dm444 -t "$out/share/fonts/opentype" {} \;

        runHook postInstall
      '';

    passthru = {
      inherit fontName outDir;
    };

    meta = {
      description = "Maple Mono - custom build with frozen OpenType features";
      homepage = "https://github.com/subframe7536/maple-font";
      license = lib.licenses.ofl;
      platforms = lib.platforms.all;
    };
  }
)
