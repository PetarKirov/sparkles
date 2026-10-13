# The work CI does, once each: `ci.tasks.<name>`. A task is a program built
# from the `tools.nix` factories, the units it covers (its laziness), the
# dev-shell features beyond what those units need, and the tasks it runs
# after. Workflows only place tasks: which runner, which shard, which env.
#
#   nix run .#ciTasks.test -- base core-cli     # what a test shard runs
#   nix eval --json .#ci.tasks                  # what each covers and needs
{ lib, config, ... }:
let
  inherit (config.ci) graph;
  pkgUnit = n: "pkg/${n}";
  packages = map pkgUnit graph.packageNames;
  osApis = "docs/research/window-system-integration/os-apis";

  # `nix build` an installable with every path pushed as it completes, so a
  # run that hits the cap still leaves its progress in the cache.
  nixBuild = installable: {
    description = "Build and push .#${installable}";
    drvs = t: [ t.packages.${installable} ];
    run =
      t:
      t.ciScript "with-cachix.sh" [
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
  };

  ciMinimalCheck = flag: t: {
    runtimeInputs = [ t.pkgs.gitMinimal ];
    text = "${lib.getExe t.ciMinimal} ${flag}";
  };
in
{
  ci.tasks = {
    # ── the D test suite, per package ──────────────────────────────

    # `ci` embeds its own compiler for examples; the suite honours `$DC`, so a
    # job's compiler dimension is real.
    test = {
      description = "dub test the packages whose closure is new";
      units = packages;
      granular = true;
      common = [ "harness" ];
      run =
        t:
        t.inShell "ci-test" ''
          # shellcheck disable=SC2086 # a word list, one package per word
          ci --test --fail-fast --packages $CI_UNITS
        '';
    };

    # AddressSanitizer + LDC's stack-overflow sanitizer.
    test-sanitize = {
      description = "Run the tests under ASan and stackovf";
      units = packages;
      granular = true;
      common = [ "harness" ];
      run =
        t:
        t.inShell "ci-test-sanitize" ''
          # shellcheck disable=SC2086
          ci --test-sanitize --fail-fast --packages $CI_UNITS
        '';
    };

    # `--test` runs a `@betterC` test as an ordinary unittest; only this mode
    # extracts it, compiles it without druntime and runs it (and likewise
    # cross-compiles `@wasm` tests).
    test-extracted = {
      description = "--better-c and --wasm for the packages that use them";
      units = packages;
      granular = true;
      common = [ "harness" ];
      run =
        t:
        t.inShell "ci-test-extracted" ''
          # shellcheck disable=SC2086
          ci --test-extracted --fail-fast --packages $CI_UNITS
        '';
    };

    # ── examples ──────────────────────────────────────────────────

    # The pinned third-party checkouts the event-horizon comparison snippets
    # build against, cloned and patched. Linux only: the snippets are.
    eh-comparisons = {
      description = "Prepare the event-horizon comparison checkouts";
      run =
        t:
        t.inShell "ci-eh-comparisons" ''
          if [ "$(uname -s)" = Linux ]; then
            dub run --single apps/ci/tools/prepare-event-horizon-comparisons.d --temp-build -b checked
          fi
        '';
    };

    # Single-file examples: each its own unit, depending on what its inline
    # recipe names.
    examples = {
      description = "Build and run the examples whose closure is new";
      units = map (f: "example/${f}") graph.exampleFiles;
      granular = true;
      common = [ "harness" ];
      after = [ "eh-comparisons" ];
      run =
        t:
        t.inShell "ci-examples" ''
          # shellcheck disable=SC2086
          ci --example-files --fail-fast --files $CI_UNITS
        '';
    };

    # Runnable markdown: each file is its own unit, depending on the packages
    # its fences' recipes name.
    md-examples = {
      description = "Verify the runnable markdown whose closure is new";
      units = map (f: "md/${f}") graph.runnableMarkdown;
      granular = true;
      common = [ "harness" ];
      after = [ "eh-comparisons" ];
      run =
        t:
        t.inShell "ci-md-examples" ''
          # shellcheck disable=SC2086
          ci --verify --fail-fast --files $CI_UNITS
        '';
    };

    # The OS-API windowing example and per-feature demos: multi-file ImportC
    # dub packages outside `--example-files`. X11 under Xvfb, Wayland under a
    # headless weston. They exit after a bounded run under WSI_AUTO_EXIT and
    # print `SKIP:` when a host capability is missing.
    wsi-demos = {
      description = "Build and run the X11 and Wayland examples and demos";
      units = [
        "os-api/x11"
        "os-api/wayland"
      ];
      run =
        t:
        t.inShell "ci-wsi-demos" ''
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
    };

    # ── the tree-wide checks: their honest input is the whole tree ──

    # Everything except the networked link check (which runs over the diff),
    # the markdown examples (their own task), the workflow drift hook (the
    # flake check covers it) and the don't-commit-to-main developer guard.
    lint = {
      description = "Every pre-commit hook over the whole tree";
      units = [ "repo" ];
      env.GITHUB_TOKEN = "\${{ github.token }}";
      run =
        t:
        t.preCommit "ci-lint" {
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
    };

    # A pull request can only add a dead URL in a file it touched; rot
    # elsewhere is `link-check.yml`'s nightly business.
    lint-diff-links = {
      description = "Check the links this pull request added or changed";
      units = [ "repo" ];
      "if" = "github.event_name == 'pull_request'";
      env = {
        GITHUB_TOKEN = "\${{ github.token }}";
        BASE_REF = "\${{ github.base_ref }}";
      };
      run =
        t:
        t.preCommit "ci-lint-diff-links" {
          only = [ "lychee" ];
          text = ''
            git fetch --no-tags --depth=1 origin "$BASE_REF"
            prek run --config "$PRE_COMMIT_CONFIG" lychee --from-ref "origin/$BASE_REF" --to-ref HEAD \
              --show-diff-on-failure --color always
          '';
        };
    };

    spec-evidence = {
      description = "Every cited symbol resolves";
      units = [ "repo" ];
      common = [ "harness" ];
      run = t: t.script "ci-spec-evidence" (ciMinimalCheck "--check-spec-evidence" t);
    };

    check-credits = {
      description = "Every shipped component is credited";
      units = [ "repo" ];
      common = [ "harness" ];
      run = t: t.script "ci-check-credits" (ciMinimalCheck "--check-credits" t);
    };

    # ── the documentation site ────────────────────────────────────

    # The generators under docs/scripts would `nix build` their tools from
    # the flake; here they are store paths in the program's closure, so a
    # change to any of them is a change to the task. Node and Yarn are all
    # it runs: no D toolchain.
    docs-build = {
      description = "Build the VitePress site";
      units = [ "repo" ];
      run =
        t:
        let
          p = t.packages;
        in
        t.script "ci-docs-build" {
          runtimeInputs = [
            t.pkgs.nodejs
            t.yarn
            t.pkgs.bash
            t.pkgs.findutils
            t.pkgs.gitMinimal
          ];
          text = ''
            export SPARKLES_HUE=${p.hue}/bin/hue
            export SPARKLES_TWOSLASH_EXTRACT=${p.twoslash-extract}/bin/twoslash-extract
            export SPARKLES_TS_GRAMMAR_PATH=${p.ts-grammars}
            export SPARKLES_TABLE_WASM=${p.table-wasm}
            export SPARKLES_CREDITS=${p.credits}

            yarn install --immutable
            # The build sits just under node's default ~4 GB heap.
            NODE_OPTIONS=--max-old-space-size=8192 yarn docs:build
          '';
        };
    };

    # Best-effort in its job: the badges are a nicety, never a reason not to
    # deploy.
    merge-badges = {
      description = "Refresh the merge badges";
      env.GITHUB_TOKEN = "\${{ github.token }}";
      run =
        t:
        t.script "ci-merge-badges" {
          runtimeInputs = [ t.pkgs.gitMinimal ];
          text = ''
            ${lib.getExe t.ciMinimal} --ci-stats --merges \
              --repo "$GITHUB_REPOSITORY" --limit 1000 --badge-dir docs/public/badges
          '';
        };
    };

    docs-deploy = {
      description = "Deploy to Cloudflare Pages & comment the preview URL";
      after = [ "docs-build" ];
      env = {
        CLOUDFLARE_API_TOKEN = "\${{ secrets.CLOUDFLARE_API_TOKEN }}";
        CLOUDFLARE_ACCOUNT_ID = "\${{ secrets.CLOUDFLARE_ACCOUNT_ID }}";
        GITHUB_TOKEN = "\${{ github.token }}";
      };
      # bash: the script execs `pr-comment.sh` through `env bash`.
      run =
        t:
        t.ciScript "deploy-cloudflare-pages.sh" [
          t.pkgs.bash
          t.pkgs.nodejs
          t.yarn
          t.pkgs.gh
          t.pkgs.gitMinimal
          t.pkgs.gnugrep
          t.pkgs.gnused
          t.pkgs.jq
        ];
    };

    # ── whole derivations ─────────────────────────────────────────

    build-all-desktop = nixBuild "all-desktop";
    build-all-android = nixBuild "all-android";

    run-all-examples = {
      description = "Run .#run-all-examples";
      drvs = t: [ t.packages.run-all-examples ];
      run =
        t:
        t.script "ci-run-all-examples" {
          runtimeInputs = [
            t.nix
            t.pkgs.gitMinimal
          ];
          text = "nix ${t.nixFlags} run .#run-all-examples";
        };
    };

    # Evaluates every output and builds this system's checks — the workflow
    # drift check among them.
    flake-check = {
      description = "nix flake check";
      units = [ "nix" ];
      drvs = t: builtins.attrValues t.checks;
      run =
        t:
        t.script "ci-flake-check" {
          runtimeInputs = [
            t.nix
            t.pkgs.gitMinimal
          ];
          text = "nix ${t.nixFlags} flake check -L";
        };
    };

    # The complete authenticated Unicode corpora, offline in the sandbox.
    text-conformance = {
      description = "Run the official corpora";
      drvs = t: [ t.checks.text-conformance ];
      run =
        t:
        t.script "ci-text-conformance" {
          runtimeInputs = [
            t.nix
            t.pkgs.gitMinimal
          ];
          text = "nix ${t.nixFlags} build -L .#checks.${t.system}.text-conformance";
        };
    };

    # ── the nightly link sweep ────────────────────────────────────

    link-sweep = {
      description = "Check every link";
      env.GITHUB_TOKEN = "\${{ github.token }}";
      run =
        t:
        t.preCommit "ci-link-sweep" {
          only = [ "lychee" ];
          text = ''
            prek run --config "$PRE_COMMIT_CONFIG" lychee --all-files --show-diff-on-failure --color never \
              | tee lychee-report.txt
          '';
        };
    };

    report-link-rot = {
      description = "Reconcile the standing link-rot issue";
      env.GITHUB_TOKEN = "\${{ github.token }}";
      run =
        t:
        t.script "ci-report-link-rot" {
          runtimeInputs = [ t.pkgs.gitMinimal ];
          text = ''
            # shellcheck disable=SC2086 # ROTTEN is one optional flag or empty
            ${lib.getExe t.ciMinimal} --report-link-rot \
              --repo "$GITHUB_REPOSITORY" \
              --report lychee-report.txt \
              --run-url "$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID" \
              $ROTTEN
          '';
        };
    };

    # ── the default branch ────────────────────────────────────────

    # `--skip-check deploy`: `Deploy Docs` files its own on this push.
    mirror-checks = {
      description = "Mirror, if the landed tree is the tree that was built";
      env.GITHUB_TOKEN = "\${{ github.token }}";
      run =
        t:
        t.script "ci-mirror-checks" {
          runtimeInputs = [ t.pkgs.gitMinimal ];
          text = ''
            # shellcheck disable=SC2086 # DRY_RUN is one optional flag or empty
            ${lib.getExe t.ciMinimal} --mirror-checks \
              --repo "$GITHUB_REPOSITORY" --sha "$SHA" --skip-check deploy $DRY_RUN
          '';
        };
    };

    # ── releases ──────────────────────────────────────────────────

    notify-dub-registry = {
      description = "Trigger the code.dlang.org update";
      env.DUB_REGISTRY_SECRET = "\${{ secrets.DUB_REGISTRY_SECRET }}";
      run = t: t.ciScript "notify-dub-registry.sh" [ t.pkgs.curl ];
    };

    release-pin = {
      description = "Push & pin the release closure";
      run =
        t:
        t.ciScript "release-pin.sh" [
          t.pkgs.cachix
          t.nix
          t.pkgs.gitMinimal
        ];
    };
  };
}
