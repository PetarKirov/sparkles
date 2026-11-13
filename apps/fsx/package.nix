# `fsx`, written as nixpkgs writes a package (docs/specs/fsx `XP1`–`XP3`):
# called with `callPackage` and nixpkgs' own arguments alone, built by
# `buildDubPackage` from the dub lock beside this file, offline, with no
# input of the repository's flake.
#
# For nixpkgs, `fsxSource` becomes a `fetchFromGitHub` of a tagged release; here it
# is the repository itself, the parts the build reads.
{
  lib,
  buildDubPackage,
  callPackage,
  llvmPackages,
  stdenv,
  withDiff ? false,
  withIroh ? true,
  fsxSource ? lib.fileset.toSource {
    root = ../..;
    # dub reads the root recipe and every sub-package's; the sources are the
    # libraries' and this program's, as git tracks them.
    fileset = lib.fileset.intersection (lib.fileset.gitTracked ../..) (
      lib.fileset.unions [
        ../../dub.sdl
        ../../libs
        (lib.fileset.fileFilter (f: f.name == "dub.sdl") ../../apps)
        ../../apps/fsx
      ]
    );
  },
}:
let
  bridge = callPackage ../../libs/iroh-send/package.nix { };
in
buildDubPackage {
  pname = "fsx";
  version = "0.1.0";
  src = fsxSource;

  dubLock = ./dub-lock.json;
  dubBuildType = "checked";
  dubBuildFlags = [
    ":fsx"
    "--config"
    (if withDiff then "full" else "application")
  ];

  # The repository links with lld on Linux (docs/guidelines/build-settings.md);
  # the wrapped bintools add the run paths a bare `ld.lld` leaves out.
  nativeBuildInputs = lib.optionals stdenv.hostPlatform.isLinux [ llvmPackages.bintools ];

  doCheck = true;
  # The suite needs no runner: the binary runs its own tests, one at a time,
  # and those that need the iroh bridge skip without it.
  # (Each phase names the package itself: the hooks put `dubFlags` after the
  # phase's own flags, past the `--` here.)
  dubTestFlags = [
    ":fsx"
    "--"
    "--no-runner"
  ];

  installPhase = ''
    runHook preInstall
    install -Dm755 apps/fsx/build/sparkles_fsx $out/bin/fsx
    ln -s fsx $out/bin/fscp
    ln -s fsx $out/bin/fsls
    ${lib.optionalString withDiff "ln -s fsx $out/bin/fsdiff"}
    # The bridge in `../lib` beside the program, where it looks first after
    # its variable, so no environment variable has to name it (`XP3`).
    ${lib.optionalString withIroh "mkdir -p $out/lib && ln -s ${bridge}/lib/* $out/lib/"}
    runHook postInstall
  '';

  passthru = { inherit bridge; };

  meta = {
    description = "Copy, list and compare the files a fileset selects, from a directory or an iroh peer";
    longDescription = ''
      fsx copies, lists and compares the members a fileset query selects from
      a directory or from a collection another machine serves with sendme.
      Every copy is verified by its content ids; from an iroh peer the filter
      is evaluated over the collection's names before any file is fetched.
    '';
    homepage = "https://github.com/PetarKirov/sparkles";
    license = lib.licenses.boost;
    mainProgram = "fsx";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
