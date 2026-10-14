# Run a dev shell's environment from a store path, with no `nix develop`.
#
# `nix develop .#ci -c cmd` evaluates the flake on every call and then
# *appends the caller's PATH* — so a step quietly finds whatever the runner
# image has installed. Here the shell's environment is captured once, at
# build time, into a derivation (`capture`), and a step is a script that
# sources it (`script`): PATH is exactly the shell's, and a tool the shell
# does not provide is "command not found", not a runner-dependent accident.
{ lib, pkgs }:
let
  # The variables `nix develop` itself refuses to carry over from the build
  # (its `ignoreVars`, less the readonly ones bash never exports), plus the
  # sandbox bookkeeping that would be wrong on a runner: the build's out
  # paths, phases and working directories.
  ignored = [
    "HOME"
    "NIX_BUILD_TOP"
    "NIX_ENFORCE_PURITY"
    "NIX_LOG_FD"
    "NIX_REMOTE"
    "SHELL"
    "SSL_CERT_FILE"
    "TEMP"
    "TEMPDIR"
    "TERM"
    "TMP"
    "TMPDIR"
    "TZ"
    "NIX_BUILD_CORES"
    "OLDPWD"
    "PWD"
    "SHLVL"
    "builder"
    "buildPhase"
    "out"
    "outputs"
    "phases"
    "shellHook"
  ];

  cacert = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
in
rec {
  # The environment `nix develop` would enter, as files: `env` (re-sourceable
  # `declare -x` lines) and `shell-hook` (the hook, run at step start since it
  # touches the runner's HOME).
  capture =
    shell:
    shell.overrideAttrs (old: {
      name = "${old.name}-env";
      buildPhase = ''
        mkdir -p "$out"
        printf '%s\n' "$shellHook" > "$out/shell-hook"
        exec 3> "$out/env"
        unset ${lib.concatStringsSep " " ignored}
        export -p >&3
      '';
    });

  # A step program: `text` runs inside `env` (a `capture`). Shellchecked like
  # `writeShellApplication`; strict mode is switched on only after the hook,
  # which was written for an interactive shell.
  script =
    {
      name,
      env,
      text,
      # Store paths whose `bin/` goes before the shell's own PATH.
      path ? [ ],
    }:
    pkgs.writeTextFile {
      inherit name;
      executable = true;
      destination = "/bin/${name}";
      text = ''
        #!${pkgs.bash}/bin/bash
        set -eo pipefail
        # shellcheck source=/dev/null
        source ${env}/env
        export IN_NIX_SHELL=impure
        ${lib.optionalString (path != [ ]) "export PATH=${lib.makeBinPath path}:$PATH"}
        export SSL_CERT_FILE=${cacert} NIX_SSL_CERT_FILE=${cacert}
        # shellcheck source=/dev/null
        source ${env}/shell-hook
        set -u

        ${text}
      '';
      checkPhase = ''
        ${pkgs.shellcheck-minimal}/bin/shellcheck --severity=warning "$target"
      '';
      meta.mainProgram = name;
    };
}
