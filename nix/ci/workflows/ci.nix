# `.github/workflows/ci.yml` — the pull-request, merge-queue and rebuild
# pipeline.
#
# Every job is lazy (see ../default.nix): it covers a set of units and runs
# only for those whose closure is new. A docs-only change runs the docs, the
# markdown it touched and the whole-tree checks; it does not run the D test
# suite, because no package's closure contains a markdown file. An edit to
# `libs/base` re-runs every package that reaches `base`, every example and
# runnable markdown file that depends on one of them, and the docs (whose
# source listings render every file).
#
# Triggers. Every job runs on every trigger and none is gated on the event:
#
#   * a merge-queue run that skipped work would gate merges on nothing;
#   * a *called* workflow reports the caller's event, so on
#     `main-checks.yml`'s rebuild path `github.event_name` is `push` — a job
#     gated to `pull_request` would report green having built nothing.
#
# Laziness is the only thing that skips work, and it is keyed by content, not
# by event: the rebuild of a landed tree skips exactly what some earlier run
# already proved on the same inputs. `workflow_dispatch` with `force` re-runs
# everything.
{
  lib,
  config,
  withSystem,
  ...
}:
let
  inherit (config.ci) graph;
  inherit (import ../lib/shard.nix { inherit lib; }) lpt;

  weights = import ./test-weights.nix;
  pkgUnit = n: "pkg/${n}";

  # ── jobs over sub-packages, statically sharded ─────────────────────

  testLegs = [
    {
      system = "x86_64-linux";
      dc = "ldc2";
      shards = 4;
      timeout = 60;
    }
    {
      system = "x86_64-linux";
      dc = "dmd";
      shards = 4;
      timeout = 45;
    }
    # The macOS plan runs five jobs at once; three shards leave room for the
    # examples and the Nix build.
    {
      system = "aarch64-darwin";
      dc = "ldc2";
      shards = 3;
      timeout = 90;
    }
    # The one host where `real` is binary128 (`real.mant_dig == 113`): it
    # compiles and runs the wide-format conversion paths natively.
    {
      system = "aarch64-linux";
      dc = "ldc2";
      shards = 4;
      timeout = 120;
    }
  ];

  shardsOf =
    n:
    lpt {
      shards = n;
      weight = p: weights.${p} or 10;
    } graph.packageNames;

  # `<prefix>-1` … `<prefix>-<n>`, each covering one shard's packages.
  shardedJobs =
    {
      prefix,
      label,
      shards,
      job,
    }:
    lib.listToAttrs (
      lib.imap1 (
        i: members:
        lib.nameValuePair "${prefix}-${toString i}" (
          lib.recursiveUpdate job {
            name = "${label} (${toString i}/${toString shards})";
            lazy = {
              units = map pkgUnit members;
              granular = true;
              common = [ "harness" ];
            };
          }
        )
      ) (shardsOf shards)
    );

  testJobs = lib.foldl' (acc: leg: acc // testLeg leg) { } testLegs;
  testLeg =
    leg:
    shardedJobs {
      prefix = "test-${leg.system}-${leg.dc}";
      label = "test ${leg.system} ${leg.dc}";
      inherit (leg) shards;
      job = {
        inherit (leg) system;
        timeout-minutes = leg.timeout;
        # dub derives a package's version from `git describe`.
        checkout.fetch-depth = 0;
        # `ci` embeds its own compiler for examples; the suite honours the
        # matrix compiler, so the ldc2/dmd dimension is real.
        env.DC = leg.dc;
        steps = t: [
          {
            name = "dub test the packages whose closure is new";
            run = t.inShell "ci-test" ''
              # shellcheck disable=SC2086 # a word list, one package per word
              ci --test --fail-fast --packages $CI_UNITS
            '';
          }
        ];
      };
    };

  # AddressSanitizer + LDC's stack-overflow sanitizer. Linux LDC only:
  # nixpkgs' LDC links gcc's libasan on Linux and has no ASan runtime on
  # Darwin; LDC rejects `-fsanitize=undefined` for D.
  sanitizeJobs = shardedJobs {
    prefix = "sanitize";
    label = "sanitize";
    shards = 4;
    job = {
      # Every package rebuilt with ASan, plus a cold toolchain after a bump.
      timeout-minutes = 45;
      env.DC = "ldc2";
      steps = t: [
        {
          name = "Run the tests under ASan and stackovf";
          run = t.inShell "ci-test-sanitize" ''
            # shellcheck disable=SC2086
            ci --test-sanitize --fail-fast --packages $CI_UNITS
          '';
        }
      ];
    };
  };

  # The native Windows leg runs without Nix: there is none on the hosted
  # runner. Its toolchain comes from setup-dlang (pinned to the flake's LDC)
  # and its package list from `ci/test-windows.sh`, read here so the two
  # cannot disagree.
  windowsPackages =
    let
      script = builtins.readFile ../../../ci/test-windows.sh;
      list = builtins.head (builtins.match ".*default_packages=\\(([^)]*)\\).*" script);
    in
    builtins.filter (w: w != "") (lib.splitString " " (lib.replaceStrings [ "\n" ] [ " " ] list));

  windowsSetup = [
    {
      name = "Install D (LDC)";
      uses = config.ci.settings.actions.setup-dlang;
      "with".compiler = "ldc-1.42.0";
    }
    {
      name = "Cache DUB packages";
      uses = config.ci.settings.actions.cache;
      "with" = {
        path = "~/AppData/Local/dub";
        key = "x86_64-windows-dub-\${{ hashFiles('**/dub.sdl', '**/dub.selections.json') }}";
        restore-keys = "x86_64-windows-dub-";
      };
    }
  ];

  # The OS-API windowing demos exit after a bounded run under WSI_AUTO_EXIT
  # and print `SKIP:` when a host capability is missing.
  osApis = "docs/research/window-system-integration/os-apis";

  # `ci/prepare-cloud-env.sh` bootstraps its own toolchain, so this job is
  # the one that must start from nothing: no Nix, no caches, nothing on PATH.
  # Its steps are plain strings on the runner's shell on purpose — proving
  # the script needs none of the machinery the other jobs use *is* the test.
  # The `restricted` leg forces the two workarounds an agent container needs
  # (flake.lock github: → git+https, dub packages from git), which open
  # egress would otherwise never exercise.
  cloudEnv =
    mode: force:
    withSystem "x86_64-linux" (
      { config, ... }:
      let
        env = {
          CI_DEVSHELL = "ci";
          CI_FORCE_GIT_INPUTS = force;
          CI_FORCE_GIT_DEPS = force;
        };
      in
      {
        name = "cloud-env (${mode})";
        system = null;
        runs-on = "ubuntu-latest";
        timeout-minutes = 30;
        lazy = {
          units = [ "cloud-env" ];
          # It substitutes this shell; a new one is new work.
          drvs = [ config.devShells.ci ];
        };
        steps = _: [
          {
            name = "Assert the runner starts clean";
            run = ''
              for tool in nix dub; do
                if command -v "$tool" > /dev/null 2>&1; then
                  echo "::error::$tool is already on PATH; this job must start without it"
                  exit 1
                fi
              done
            '';
          }
          {
            name = "Run the setup script";
            run = "ci/prepare-cloud-env.sh";
            inherit env;
          }
          {
            # Only passes if the script's PATH export reached $GITHUB_ENV.
            name = "The toolchain survives into a later step";
            run = ''
              echo "dub: $(command -v dub)"
              echo "ldc2: $(command -v ldc2)"
              dub --version
              ldc2 --version | head -n1
            '';
          }
          {
            # A daemon silently drops an untrusted user's substituters: an
            # hour of compiling, not an error.
            name = "The project caches are in effect";
            run = ''
              substituters=$(nix config show substituters)
              echo "substituters: $substituters"
              case "$substituters" in
                *sparkles.cachix.org*) ;;
                *) echo "::error::sparkles.cachix.org is not an effective substituter"; exit 1 ;;
              esac
            '';
          }
          {
            name = "Tests actually run";
            run = "dub test :base";
          }
          {
            name = "Re-running is idempotent";
            run = "ci/prepare-cloud-env.sh";
            inherit env;
          }
          {
            # The rewrite is a local accommodation; committed, it would give
            # every consumer of the lock shallow git inputs.
            name = "flake.lock is not modified in a committable way";
            run = ''
              if [ -n "$(git diff --name-only -- flake.lock)" ]; then
                echo "::error::flake.lock shows as modified; the skip-worktree guard did not hold"
                git diff --stat -- flake.lock
                exit 1
              fi
            '';
          }
        ];
      }
    );

  # ── whole-derivation jobs ──────────────────────────────────────────

  nixBuild =
    {
      system,
      installable,
      timeout,
      runAfter ? null,
    }:
    withSystem system (
      { config, ... }:
      {
        inherit system;
        timeout-minutes = timeout;
        lazy.drvs = [
          config.packages.${installable}
        ]
        ++ lib.optional (runAfter != null) config.packages.${runAfter};
        env = {
          CACHIX_CACHE = "sparkles";
          CACHIX_AUTH_TOKEN = "\${{ secrets.CACHIX_AUTH_TOKEN }}";
        };
        steps =
          t:
          [
            {
              name = "Build and push .#${installable}";
              # `with-cachix.sh` pushes each path as it completes, so a run
              # that hits the cap still leaves its progress in the cache.
              run = t.ciScript "with-cachix.sh" [
                t.pkgs.cachix
                t.nix
                t.pkgs.gitMinimal
              ];
              args = [
                "nix"
                "build"
                "--print-build-logs"
                ".#${installable}"
              ];
            }
          ]
          ++ lib.optional (runAfter != null) {
            name = "Run .#${runAfter}";
            run = t.script "ci-${runAfter}" {
              runtimeInputs = [
                t.nix
                t.pkgs.gitMinimal
              ];
              text = "nix ${t.nixFlags} run .#${runAfter}";
            };
          };
      }
    );
in
{
  ci.workflows.ci = {
    name = "CI";
    on = {
      # The rebuild path: `main-checks.yml` calls this workflow when a merge
      # lands a tree no pull request built.
      workflow_call.secrets.CACHIX_AUTH_TOKEN.required = false;
      workflow_dispatch.inputs.force = {
        description = "Run every job, ignoring the stamps of earlier passes";
        type = "boolean";
        default = false;
      };
      merge_group = { };
      pull_request = { };
    };
    permissions.contents = "read";
    concurrency = {
      group = "\${{ github.workflow }}-\${{ github.repository }}-\${{ github.event.pull_request.number || github.ref }}";
      # Superseded PR pushes are worth cancelling; a rebuild of `main` is not.
      cancel-in-progress = "\${{ github.event_name == 'pull_request' }}";
    };

    jobs =
      testJobs
      // sanitizeJobs
      // {
        test-windows = {
          name = "test x86_64-windows ldc2";
          system = null;
          runs-on = "windows-latest";
          timeout-minutes = 40;
          # As on the Nix test legs: dub derives a package's version from
          # `git describe`.
          checkout.fetch-depth = 0;
          lazy = {
            units = map pkgUnit windowsPackages;
            granular = true;
            common = [ "ci-scripts" ];
          };
          steps =
            _:
            windowsSetup
            ++ [
              {
                name = "dub test the packages whose closure is new";
                shell = "bash";
                # On the step, not the job: setup-dlang exports `DC` as a full
                # path through GITHUB_ENV, which overrides a job-level `env`.
                # Given the full path the `@ctfe` probe runs, and on Windows it
                # cannot yet find its import roots; given `ldc2` it skips, as
                # it always has on this leg.
                env.DC = "ldc2";
                run = ''
                  # shellcheck disable=SC2086 # a word list, one package per word
                  ci/test-windows.sh $CI_UNITS
                '';
              }
            ];
        };

        # The native half of what `libs/wsi/scripts/verify-win32-wine.sh`
        # certifies under Wine: the WSI conformance suite through the Win32
        # driver, then the OS-API example and demos. Counts are pinned so a
        # driver that skipped everything cannot pass.
        wsi-windows = {
          name = "wsi x86_64-windows";
          system = null;
          runs-on = "windows-latest";
          timeout-minutes = 30;
          checkout.fetch-depth = 0;
          env.WSI_AUTO_EXIT = "1";
          lazy.units = [
            "pkg/wsi"
            "os-api/win32"
          ];
          steps =
            _:
            windowsSetup
            ++ [
              {
                name = "The sparkles:wsi Win32 conformance driver";
                shell = "bash";
                run = ''
                  dub run --single --compiler=ldc2 libs/wsi/examples/win32-hosted-smoke.d | tee smoke.log
                  grep -q '^ok: Win32 WSI conformance (18 checked, 3 skipped)' smoke.log
                  grep -q '^ok: Win32 text commit' smoke.log
                '';
              }
              {
                name = "The OS-API windowing example and demos (Win32)";
                shell = "bash";
                run = ''
                  base=${osApis}
                  dub run --compiler=ldc2 --root="$base/win32/example"
                  for d in "$base"/win32/examples/*/; do
                    [ -f "$d/dub.sdl" ] || continue
                    echo "::group::win32 $d"
                    dub run --compiler=ldc2 --root="$d"
                    echo "::endgroup::"
                  done
                '';
              }
            ];
        };

        # `--test` runs a `@betterC` test as an ordinary unittest; only this
        # mode extracts it, compiles it without druntime and runs it (and
        # likewise cross-compiles `@wasm` tests). `--require-toolchain` turns
        # a missing wasm-ld into a failure rather than a green skip.
        extracted-tests = {
          name = "extracted test modes (--better-c, --wasm)";
          timeout-minutes = 20;
          env.DC = "ldc2";
          lazy = {
            units = map pkgUnit graph.packageNames;
            granular = true;
            common = [ "harness" ];
          };
          steps = t: [
            {
              name = "--better-c and --wasm for the packages that use them";
              run = t.inShell "ci-test-extracted" ''
                # shellcheck disable=SC2086
                ci --test-extracted --fail-fast --packages $CI_UNITS
              '';
            }
          ];
        };

        # The OS-API windowing example and per-feature demos: multi-file
        # ImportC dub packages outside `--example-files`. X11 under Xvfb,
        # Wayland under a headless weston.
        wsi-demos = {
          name = "wsi x86_64-linux (X11, Wayland)";
          timeout-minutes = 30;
          env.WSI_AUTO_EXIT = "1";
          lazy.units = [
            "os-api/x11"
            "os-api/wayland"
          ];
          steps = t: [
            {
              name = "Build and run the X11 and Wayland examples and demos";
              run = t.inShell "ci-wsi-demos" ''
                base=${osApis}
                xvfb-run -a dub run --compiler=ldc2 --root="$base/x11/example"
                dub run --compiler=ldc2 --root="$base/wayland/example"
                # An interactive probe: compile only, running it would wait forever.
                dub build --single --compiler=ldc2 \
                  docs/research/window-system-integration/cursor-shapes/cursor-shapes.d
                for d in "$base"/x11/examples/*/; do
                  [ -f "$d/dub.sdl" ] || continue
                  echo "::group::x11 $d"
                  xvfb-run -a dub run --compiler=ldc2 --root="$d"
                  echo "::endgroup::"
                done
                XDG_RUNTIME_DIR=$(mktemp -d)
                export XDG_RUNTIME_DIR
                weston --backend=headless --socket=wsi-ci --idle-time=0 &
                weston_pid=$!
                sleep 3
                for d in "$base"/wayland/examples/*/; do
                  [ -f "$d/dub.sdl" ] || continue
                  echo "::group::wayland $d"
                  WAYLAND_DISPLAY=wsi-ci dub run --compiler=ldc2 --root="$d"
                  echo "::endgroup::"
                done
                kill "$weston_pid"
              '';
            }
          ];
        };

        # Runnable markdown: each file is its own unit, depending on the
        # packages its fences' recipes name.
        md-examples = {
          name = "markdown examples";
          timeout-minutes = 35;
          # The 1-minute load average after Nix setup once picked one worker
          # for every example; pin the fan-out.
          env.SPARKLES_CI_JOBS = "2";
          lazy = {
            units = map (f: "md/${f}") graph.runnableMarkdown;
            granular = true;
            common = [ "harness" ];
          };
          steps = t: [
            {
              name = "Verify the runnable markdown whose closure is new";
              run = t.inShell "ci-md-examples" ''
                dub run --single apps/ci/tools/prepare-event-horizon-comparisons.d --temp-build -b checked
                # shellcheck disable=SC2086
                ci --verify --fail-fast --files $CI_UNITS
              '';
            }
          ];
        };

        # The tree-wide checks: their honest input is the whole tree.
        lint = {
          name = "lint & local links";
          timeout-minutes = 20;
          checkout.fetch-depth = 0;
          lazy.units = [ "repo" ];
          steps = t: [
            {
              name = "Restore the lychee cache";
              uses = config.ci.settings.actions.cache-restore;
              "with" = {
                path = ".lycheecache";
                enableCrossOsArchive = true;
                key = "cache-lychee-v4-\${{ github.run_id }}";
                restore-keys = "cache-lychee-v4-";
              };
            }
            {
              # Everything except the networked link check (which runs over
              # the diff below), the markdown examples (their own job), the
              # workflow drift hook (the flake check covers it) and the
              # don't-commit-to-main developer guard.
              name = "Every pre-commit hook over the whole tree";
              run = t.preCommit "ci-lint" {
                skip = [
                  "verify-md-examples"
                  "lychee"
                  "no-commit-to-branch"
                  "ci-workflows"
                ];
                text = ''
                  prek run --config "$PRE_COMMIT_CONFIG" --all-files --show-diff-on-failure --color always
                '';
              };
              env.GITHUB_TOKEN = "\${{ github.token }}";
            }
            {
              # A pull request can only add a dead URL in a file it touched;
              # rot elsewhere is `link-check.yml`'s nightly business.
              name = "Check the links this pull request added or changed";
              "if" = "github.event_name == 'pull_request'";
              run = t.preCommit "ci-lint-diff-links" {
                only = [ "lychee" ];
                text = ''
                  git fetch --no-tags --depth=1 origin "$BASE_REF"
                  prek run --config "$PRE_COMMIT_CONFIG" lychee --from-ref "origin/$BASE_REF" --to-ref HEAD \
                    --show-diff-on-failure --color always
                '';
              };
              env = {
                GITHUB_TOKEN = "\${{ github.token }}";
                BASE_REF = "\${{ github.base_ref }}";
              };
            }
            {
              # Never overwritten under one key, so the key changes every run
              # while the restore prefix stays stable.
              name = "Save the lychee cache";
              "if" = "always()";
              uses = config.ci.settings.actions.cache-save;
              "with" = {
                path = ".lycheecache";
                enableCrossOsArchive = true;
                key = "cache-lychee-v4-\${{ github.run_id }}";
              };
            }
          ];
        };

        docs = {
          name = "documentation site";
          # The build sits near node's default heap; the wasm toolchain may
          # need building when the cache lacks it.
          timeout-minutes = 40;
          lazy.units = [ "repo" ];
          env.COREPACK_ENABLE_DOWNLOAD_PROMPT = "0";
          steps = t: [
            {
              name = "Cache Yarn";
              uses = config.ci.settings.actions.cache;
              "with" = {
                path = "~/.yarn/berry/cache";
                key = "yarn-\${{ runner.os }}-\${{ hashFiles('yarn.lock') }}";
                restore-keys = "yarn-\${{ runner.os }}-";
              };
            }
            {
              name = "Build the VitePress site";
              run = import ./docs-build.nix t;
            }
          ];
        };

        spec-evidence = {
          name = "spec evidence & credits";
          timeout-minutes = 15;
          cachix.push = false;
          lazy = {
            units = [ "repo" ];
            common = [ "harness" ];
          };
          steps = t: [
            {
              name = "Every cited symbol resolves";
              run = t.script "ci-spec-evidence" {
                runtimeInputs = [ t.pkgs.gitMinimal ];
                text = "${lib.getExe t.ciMinimal} --check-spec-evidence";
              };
            }
            {
              name = "Every shipped component is credited";
              run = t.script "ci-check-credits" {
                runtimeInputs = [ t.pkgs.gitMinimal ];
                text = "${lib.getExe t.ciMinimal} --check-credits";
              };
            }
          ];
        };

        # The complete authenticated Unicode corpora, offline in the sandbox.
        text-conformance = withSystem "x86_64-linux" (
          { config, ... }:
          {
            name = "Unicode conformance";
            lazy.drvs = [ config.checks.text-conformance ];
            steps = t: [
              {
                name = "Run the official corpora";
                run = t.script "ci-text-conformance" {
                  runtimeInputs = [
                    t.nix
                    t.pkgs.gitMinimal
                  ];
                  text = "nix ${t.nixFlags} build -L .#checks.x86_64-linux.text-conformance";
                };
              }
            ];
          }
        );

        nix-build-x86_64-linux = nixBuild {
          system = "x86_64-linux";
          installable = "all-desktop";
          runAfter = "run-all-examples";
          timeout = 60;
        };
        nix-build-aarch64-darwin = nixBuild {
          system = "aarch64-darwin";
          installable = "all-desktop";
          runAfter = "run-all-examples";
          timeout = 90;
        };
        # The APK closure: dual-ABI druntimes, the cross C libraries, every
        # grammar, the font build and the signing-free assembly.
        nix-build-android = nixBuild {
          system = "x86_64-linux";
          installable = "all-android";
          timeout = 90;
        };
      }
      // lib.concatMapAttrs (system: jobs: jobs) (
        lib.genAttrs [ "x86_64-linux" "aarch64-darwin" ] (system: {
          # Single-file examples: each its own unit, depending on what its
          # inline recipe names.
          "examples-${system}" = {
            name = "examples ${system}";
            inherit system;
            timeout-minutes = 60;
            env.SPARKLES_CI_JOBS = if system == "aarch64-darwin" then "3" else "4";
            lazy = {
              units = map (f: "example/${f}") graph.exampleFiles;
              granular = true;
              common = [ "harness" ];
            };
            steps = t: [
              {
                name = "Build and run the examples whose closure is new";
                run = t.inShell "ci-examples" ''
                  if [ "$(uname -s)" = Linux ]; then
                    dub run --single apps/ci/tools/prepare-event-horizon-comparisons.d --temp-build -b checked
                  fi
                  # shellcheck disable=SC2086
                  ci --example-files --fail-fast --files $CI_UNITS
                '';
              }
            ];
          };

          # Evaluates every output and builds this system's checks — the
          # workflow drift check among them.
          "flake-check-${system}" = withSystem system (
            { config, ... }:
            {
              name = "nix flake check ${system}";
              inherit system;
              timeout-minutes = 45;
              lazy = {
                units = [ "nix" ];
                drvs = builtins.attrValues config.checks;
              };
              steps = t: [
                {
                  name = "nix flake check";
                  run = t.script "ci-flake-check" {
                    runtimeInputs = [
                      t.nix
                      t.pkgs.gitMinimal
                    ];
                    text = "nix ${t.nixFlags} flake check -L";
                  };
                }
              ];
            }
          );
        })
      )
      // lib.mapAttrs' (mode: force: lib.nameValuePair "cloud-env-${mode}" (cloudEnv mode force)) {
        # What a container with open egress gets: tarball inputs, the registry.
        native = "0";
        # What an agent container gets: git inputs, dub packages from git.
        restricted = "1";
      };
  };
}
