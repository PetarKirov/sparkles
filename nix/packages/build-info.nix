# The build-info document every shipped binary carries (`TPG2`): the section
# it lives in, the JSON written into it, and the checks run on it at
# evaluation time. Exported through `legacyPackages` for `buildSparklesApp`
# and the Android libraries, which stamp it in a second step.
{ lib, inputs, ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      # ELF `.build_info`, Mach-O `__DATA,__build_info`, PE `.bldinfo`.
      # Android `.so` files are ELF even when the builder is Linux; that
      # caller passes `.build_info` itself.
      buildInfoSectionName =
        if pkgs.stdenv.hostPlatform.isWindows then
          ".bldinfo"
        else if pkgs.stdenv.hostPlatform.isDarwin then
          "__DATA,__build_info"
        else
          ".build_info";

      emptyBuildInfoJson = pkgs.writeText "build-info-empty.json" "{}";

      # `target` is a shell word. ELF `--update-section` resizes. Mach-O
      # refuses a larger replacement, so the old section is removed first.
      # A PE section keeps its bytes only when flagged as initialized data;
      # VirtualSize is then the content and SizeOfRawData is file-aligned.
      #
      # Editing a linked Mach-O invalidates its code signature, and arm64
      # macOS kills an unsigned binary at exec, so on Darwin the edit is
      # followed by an ad-hoc re-sign (the linker's own kind of signature).
      # sigtool's `codesign` execs `codesign_allocate` (cctools) from PATH,
      # which a bare `runCommand` (step 2) does not have.
      buildInfoObjcopy =
        {
          section,
          json,
          target,
          replace ? false,
        }:
        let
          sec = lib.escapeShellArg section;
          file = lib.escapeShellArg "${json}";
          drop = lib.optionalString replace "--remove-section ${sec}";
          edit =
            if section == ".bldinfo" then
              "llvm-objcopy ${drop} --add-section ${sec}=${file} --set-section-flags ${sec}=data,readonly ${target}"
            else if replace && lib.hasInfix "," section then
              "llvm-objcopy --remove-section ${sec} --add-section ${sec}=${file} ${target}"
            else if replace then
              "llvm-objcopy --update-section ${sec}=${file} ${target}"
            else
              "llvm-objcopy --add-section ${sec}=${file} ${target}";
        in
        edit
        + lib.optionalString (lib.hasInfix "," section && pkgs.stdenv.hostPlatform.isDarwin) ''

          PATH=${pkgs.cctools}/bin:$PATH ${pkgs.darwin.sigtool}/bin/codesign -f -s - ${target}
        '';

      # Direct native inputs, keyed by pname. A `dev` output is dropped
      # when that pname is already listed, whatever order the list has.
      nativeComponents =
        pkgsList:
        let
          described = map (pkg: {
            pname = pkg.pname or pkg.name;
            dev = (pkg.outputName or "out") == "dev";
            value = {
              version = pkg.version or "unknown";
              storePath = pkg.outPath;
            };
          }) pkgsList;
          mainNames = map (d: d.pname) (lib.filter (d: !d.dev) described);
          kept = lib.filter (d: !d.dev || !(lib.elem d.pname mainNames)) described;
        in
        lib.listToAttrs (
          map (d: {
            name = d.pname;
            value = d.value;
          }) kept
        );

      inTreeComponents =
        names:
        lib.listToAttrs (
          map (n: {
            name = "sparkles:${n}";
            value = {
              version = "in-tree";
            };
          }) names
        );

      sparklesBuildInfo =
        {
          name,
          version,
          buildType ? "checked",
          links ? { },
          components ? { },
        }:
        let
          short = inputs.self.shortRev or null;
          dirtyRev = inputs.self.dirtyShortRev or null;
          commit =
            if short != null then
              short
            else if dirtyRev != null then
              lib.removeSuffix "-dirty" dirtyRev
            else
              null;
          # A clean rev still records dirty = false. Neither rev: omit both.
          dirty = short == null && dirtyRev != null;
          document = {
            inherit name version buildType;
          }
          // lib.optionalAttrs (commit != null) { inherit commit dirty; }
          // lib.optionalAttrs (links != { }) { inherit links; }
          // {
            inherit components;
          };
        in
        {
          inherit document;
          json = builtins.toJSON document;
        };

      # The contract every stamped document keeps: in-tree sparkles packages
      # carry no store path, a dev output is never its own component, test
      # scaffolding is not linked, and the commit is recorded exactly when the
      # flake has one. `buildSparklesApp` runs it (and the caller's
      # `checkBuildInfo`) while evaluating step 2, so a violation fails
      # evaluation of the package rather than waiting for someone to read it.
      assertBuildInfo =
        doc:
        let
          c = doc.components;
          base = c."sparkles:base" or { };
          hasRev = (inputs.self.shortRev or null) != null || (inputs.self.dirtyShortRev or null) != null;
        in
        assert lib.assertMsg (base.version or "" == "in-tree") "sparkles:base.version must be in-tree";
        assert lib.assertMsg (!(base ? storePath)) "sparkles:base must not carry a storePath";
        assert lib.assertMsg (lib.all (n: !(lib.hasSuffix ".dev" n)) (
          lib.attrNames c
        )) "a dev output must not be its own component";
        assert lib.assertMsg (
          if hasRev then (doc ? commit && doc ? dirty) else (!(doc ? commit) && !(doc ? dirty))
        ) "commit and dirty are present exactly when the flake has a rev";
        assert lib.assertMsg (
          !(c ? "sparkles:test-utils")
        ) "test-utils is a test configuration, not a linked input";
        assert lib.assertMsg (
          !(c ? "sparkles:test-runner")
        ) "the test-runner shim is an import path for UDAs, not a linked input";
        assert lib.assertMsg (
          !(c ? "sparkles:test-runner-impl")
        ) "test-runner-impl is linked only into a test binary";
        doc;

      # `name` is a linked native input: a store path, and the output that was
      # linked rather than its dev output.
      assertLinked =
        name: doc:
        let
          p = doc.components.${name} or { };
        in
        assert lib.assertMsg (
          p ? storePath && lib.hasPrefix "/nix/store/" p.storePath
        ) "${name}.storePath must be a store path";
        assert lib.assertMsg (
          !(lib.hasSuffix "-dev" p.storePath)
        ) "${name} must be the output that was linked, not its dev output";
        doc;

      # A PATH-only runtime wrapper input is not a linked component.
      assertNotLinked =
        name: doc:
        assert lib.assertMsg (!(doc.components ? ${name})) "${name} is a PATH wrapper, not a linked input";
        doc;

      # The default configurations draw on the native arm: raylib is not in
      # them; the `raylib` configurations link it.
      assertRaylib =
        linked: doc:
        if linked then
          assertLinked "raylib" doc
        else
          assert lib.assertMsg (!(doc.components ? raylib)) "the native arm's configuration links no raylib";
          doc;

      # The terminal's about page (`TPG1`): the GUI configuration links
      # libghostty-vt and not the TUI backend.
      checkTerminalBuildInfoWith =
        raylib: doc:
        let
          c = doc.components;
        in
        assert lib.assertMsg (
          !(c ? "sparkles:ui-tui") && !(c ? "sparkles:tui")
        ) "the gui configuration does not link the tui backend";
        lib.pipe doc [
          (assertLinked "libghostty-vt")
          (assertRaylib raylib)
          (assertNotLinked "fontconfig")
        ];

      # hue ships both front ends (`BLD1`) and links its native inputs.
      checkHueBuildInfoWith =
        raylib: doc:
        assert lib.assertMsg (doc.components ? "sparkles:tui") "hue links its TUI front end";
        lib.pipe doc [
          (assertLinked "libghostty-vt")
          (assertRaylib raylib)
          (assertLinked "tree-sitter")
          (assertNotLinked "fontconfig")
        ];
      checkTerminalBuildInfo = checkTerminalBuildInfoWith false;
      checkHueBuildInfo = checkHueBuildInfoWith false;
    in
    {
      # Where a binary carries the document, for the stamping steps.
      legacyPackages.buildInfoSectionName = buildInfoSectionName;
      legacyPackages.nativeComponents = nativeComponents;
      # The build stamp an application reports as its version and commit
      # (`sparkles.base.build_stamp`, docs/specs/terminal/pages.md `TPG2`): a
      # directory holding `sparkles-build-stamp`, for the compiler's `-J`.
      # Only a release build (`withCommit`) records the commit — and then a
      # tree with uncommitted changes is stamped `<rev>-dirty`, never as its
      # last commit. Every other build carries the version alone, so it stays
      # cached across commits that do not touch its sources. `components`
      # names the versions of what it links in (an about page lists them,
      # `TPG1`), as `component.<name>=<version>` lines.
      legacyPackages.sparklesBuildInfo = sparklesBuildInfo;
      legacyPackages.assertBuildInfo = assertBuildInfo;
      legacyPackages.checkTerminalBuildInfo = checkTerminalBuildInfo;
      legacyPackages.checkHueBuildInfo = checkHueBuildInfo;
      legacyPackages.checkTerminalRaylibBuildInfo = checkTerminalBuildInfoWith true;
      legacyPackages.checkHueRaylibBuildInfo = checkHueBuildInfoWith true;
      legacyPackages.inTreeComponents = inTreeComponents;
      legacyPackages.buildInfoObjcopy = buildInfoObjcopy;
      legacyPackages.emptyBuildInfoJson = emptyBuildInfoJson;

      legacyPackages.mkBuildStamp =
        {
          version,
          withCommit ? false,
          components ? { },
        }:
        let
          rev = if withCommit then inputs.self.shortRev or inputs.self.dirtyShortRev or null else null;
        in
        pkgs.writeTextDir "sparkles-build-stamp" (
          "version=${version}\n"
          + lib.optionalString (rev != null) "commit=${rev}\n"
          + lib.concatStrings (lib.mapAttrsToList (n: v: "component.${n}=${v}\n") components)
        );

    };
}
