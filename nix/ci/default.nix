# GitHub Actions workflows, generated from Nix — in the style of
# nialov/actions.nix, with two properties that project does not have:
#
#   1. Every `run:` step of a job on a Nix runner is a store path. A step is a
#      derivation (a script whose PATH is exactly its declared inputs, or the
#      `ci` dev shell's environment captured at build time), rendered as its
#      `/nix/store/…/bin/<name>`. The type of `run` enforces it. Nothing a job
#      executes depends on what the runner image happens to have on PATH; the
#      only exceptions are the bootstrap that installs Nix and realises the
#      job's closure, and the jobs that deliberately run without Nix (the
#      native Windows leg, the cloud-environment bootstrap test).
#
#   2. The pipeline is lazy. The repository is partitioned into units
#      (`lib/graph.nix`), each job declares the units it covers, and a planner
#      job asks the binary cache which (job, unit) pairs already passed on
#      exactly these inputs (`lib/stamps.nix`). Only new work runs; a job with
#      none is skipped. After the run, the fan-in job records a stamp for
#      every pair that passed.
#
# Workflows are declared under `ci.workflows.<name>` (see ./workflows), rendered
# to `.github/workflows/<name>.yml` by `nix run .#render-workflows` (also a
# pre-commit hook), and checked for drift by `checks.<system>.ci-workflows`.
{
  lib,
  config,
  withSystem,
  ...
}:
let
  inherit (lib) mkOption types;
  cfg = config.ci;

  root = ../..;
  graph = import ./lib/graph.nix { inherit lib root; };
  yaml = import ./lib/yaml.nix { inherit lib; };
  stamps = import ./lib/stamps.nix { inherit lib; };
  fs = lib.fileset;

  toolsFor =
    variant: system: withSystem system ({ config, ... }: config.legacyPackages.ciTools.${variant});

  expr = e: "\${{ ${e} }}";

  # ── option types ────────────────────────────────────────────────────

  stepModule = {
    options = {
      name = mkOption {
        type = types.nullOr types.str;
        default = null;
      };
      id = mkOption {
        type = types.nullOr types.str;
        default = null;
      };
      "if" = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "A GitHub expression, without the `\${{ }}`.";
      };
      uses = mkOption {
        type = types.nullOr types.str;
        default = null;
      };
      "with" = mkOption {
        type = types.attrsOf (
          types.oneOf [
            types.str
            types.bool
            types.int
          ]
        );
        default = { };
      };
      run = mkOption {
        type = types.nullOr (types.either types.package types.str);
        default = null;
        description = ''
          The program to run. On a Nix runner this must be a package, rendered
          as its main program's store path; a string is accepted only on jobs
          without Nix (`system = null`).
        '';
      };
      args = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Arguments after the program (GitHub expressions allowed).";
      };
      env = mkOption {
        type = types.attrsOf types.str;
        default = { };
      };
      shell = mkOption {
        type = types.nullOr types.str;
        default = null;
      };
      continue-on-error = mkOption {
        type = types.nullOr (types.either types.bool types.str);
        default = null;
      };
      timeout-minutes = mkOption {
        type = types.nullOr types.int;
        default = null;
      };
    };
  };

  jobModule =
    { name, config, ... }:
    {
      options = {
        name = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "The check name GitHub shows. Defaults to the job id.";
        };
        system = mkOption {
          type = types.nullOr types.str;
          default = cfg.defaultValues.jobs.system;
          description = ''
            The Nix system of the runner. `null` for a job that runs without
            Nix — its steps may then be plain strings.
          '';
        };
        runs-on = mkOption {
          type = types.nullOr types.str;
          default = if config.system == null then null else cfg.settings.runners.${config.system};
          description = "Defaults from the system; a job calling a reusable workflow has none.";
        };
        timeout-minutes = mkOption {
          type = types.nullOr types.int;
          default = cfg.defaultValues.jobs.timeout-minutes;
        };
        needs = mkOption {
          type = types.listOf types.str;
          default = [ ];
        };
        "if" = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "A GitHub expression, without the `\${{ }}`.";
        };
        permissions = mkOption {
          type = types.nullOr (types.attrsOf types.str);
          default = null;
        };
        env = mkOption {
          type = types.attrsOf types.str;
          default = { };
        };
        outputs = mkOption {
          type = types.attrsOf types.str;
          default = { };
        };
        checkout = {
          enable = mkOption {
            type = types.bool;
            default = true;
          };
          fetch-depth = mkOption {
            type = types.int;
            default = 1;
          };
        };
        cachix.push = mkOption {
          type = types.bool;
          default = true;
          description = "Push what this job builds to the project cache (when the token is available).";
        };
        lazy = {
          enable = mkOption {
            type = types.bool;
            default = config.lazy.units != [ ] || config.lazy.drvs != [ ];
            description = "Skip this job when everything it covers already passed.";
          };
          units = mkOption {
            type = types.listOf types.str;
            default = [ ];
            description = "The units this job covers; each re-runs when its closure is new.";
          };
          granular = mkOption {
            type = types.bool;
            default = false;
            description = ''
              Track each unit separately: the job runs only its stale units,
              which it reads from `$CI_UNITS` (the units' `arg`s, space-separated).
              Otherwise the job is one piece of work over all of them.
            '';
          };
          common = mkOption {
            type = types.listOf types.str;
            default = [ ];
            description = "Units every stamp of this job also depends on (the harness).";
          };
          drvs = mkOption {
            type = types.listOf types.package;
            default = [ ];
            description = "Derivations whose `drvPath`s join the key (a job that builds them).";
          };
        };
        features = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = ''
            Dev-shell features (`ciFeatures` in nix/shells/default.nix) the
            job's `t.inShell` steps need beyond those its units' closures need
            (`graph.needsOf`). The shell holds exactly their union.
          '';
        };
        steps = mkOption {
          type = types.functionTo (types.listOf (types.submodule stepModule));
          default = _: [ ];
          description = ''
            A function from the runner's tools (`legacyPackages.ciTools`) to the
            job's steps. It is called twice: with the real tools to render the
            workflow, and with a stub `ci` harness to compute the laziness key —
            so rebuilding the helper, which links 23 libraries, does not
            invalidate every job.
          '';
        };
        extra = mkOption {
          type = types.attrsOf types.anything;
          default = { };
          description = "Rendered verbatim into the job (strategy, environment, `uses` of a called workflow, …).";
        };
      };
    };

  workflowModule =
    { name, config, ... }:
    {
      options = {
        file = mkOption {
          type = types.str;
          default = ".github/workflows/${name}.yml";
        };
        name = mkOption { type = types.str; };
        on = mkOption { type = types.attrsOf types.anything; };
        permissions = mkOption {
          type = types.nullOr (types.attrsOf types.str);
          default = null;
        };
        concurrency = mkOption {
          type = types.nullOr (types.attrsOf types.anything);
          default = null;
        };
        env = mkOption {
          type = types.attrsOf types.str;
          default = { };
        };
        jobs = mkOption {
          type = types.attrsOf (types.submodule jobModule);
          default = { };
        };
        fanIn = {
          enable = mkOption {
            type = types.bool;
            default = config.plan.enable;
            description = ''
              Add the single required check: a job named `CI` that needs every
              other job and fails if any failed or was cancelled. With a
              planner it also records the stamps of the jobs that passed.
            '';
          };
          name = mkOption {
            type = types.str;
            default = "CI";
          };
        };
        plan.enable = mkOption {
          type = types.bool;
          default = lib.any (j: j.lazy.enable) (builtins.attrValues config.jobs);
        };
      };
    };

  # ── rendering ───────────────────────────────────────────────────────

  dropEmpty = lib.filterAttrs (_: v: v != null && v != { } && v != [ ]);

  renderStep =
    s:
    dropEmpty {
      inherit (s)
        name
        id
        uses
        env
        shell
        continue-on-error
        timeout-minutes
        ;
      "if" = if s."if" == null then null else expr s."if";
      "with" = s."with";
      run =
        if s.run == null then
          null
        else if lib.isDerivation s.run then
          lib.concatStringsSep " " ([ (lib.getExe s.run) ] ++ s.args)
        else
          s.run;
    };

  nixConf =
    let
      nc = cfg.settings.nixConfig;
    in
    ''
      extra-substituters = ${lib.concatStringsSep " " nc.extra-substituters}
      extra-trusted-public-keys = ${lib.concatStringsSep " " nc.extra-trusted-public-keys}
      fallback = true
      connect-timeout = 5
      download-attempts = 2
      auto-optimise-store = false
    '';

  # Everything a Nix job runs, in one store path: realising it fetches (or
  # builds) the whole closure up front, and the path in the YAML pins it.
  bundleOf =
    tools: id: steps:
    tools.pkgs.writeText "ci-job-${id}" (
      lib.concatLines (
        map toString ([ tools.pkgs.bash ] ++ builtins.filter lib.isDerivation (map (s: s.run) steps))
      )
    );

  realiseStep = wfName: id: system: bundle: {
    name = "Realise the job's closure";
    # The one bootstrap seam: no store path can run before this step has
    # fetched them, so it uses the runner's bash and the installer's profile.
    shell = "bash";
    run = ''
      set -euo pipefail
      bundle=${bundle}
      nix=/nix/var/nix/profiles/default/bin
      if "$nix/nix-store" --realise "$bundle" > /dev/null 2>&1; then
        echo "Substituted $bundle"
        exit 0
      fi
      echo "::group::Building the job's closure (not in the binary cache yet)"
      built=$("$nix/nix" build --no-link --print-out-paths -L '.#ci.bundles.${wfName}.${id}')
      echo "::endgroup::"
      if [ "$built" != "$bundle" ]; then
        echo "::error::.github/workflows is stale: it names $bundle, the flake builds $built. Run: nix run .#render-workflows"
        exit 1
      fi
    '';
  };

  staleOf = id: "fromJSON(needs.plan.outputs.stale)['${id}']";

  renderJob =
    {
      wfName,
      wf,
      id,
      job,
      variant,
    }:
    let
      onNix = job.system != null;
      # The job's shell holds what its units need, and no more.
      features = graph.needsOf (job.lazy.units ++ job.lazy.common) ++ job.features;
      tools = if onNix then (toolsFor variant job.system).withFeatures features else null;
      steps = job.steps tools;
      lazy = wf.plan.enable && job.lazy.enable;
      bundle = bundleOf tools id steps;
      lazyIf = "${staleOf id}[0] != null";
      condition =
        if lazy && job."if" != null then
          "(${job."if"}) && ${lazyIf}"
        else if lazy then
          lazyIf
        else
          job."if";
      bootstrap =
        lib.optional job.checkout.enable {
          name = "Checkout";
          uses = cfg.settings.actions.checkout;
          "with".fetch-depth = job.checkout.fetch-depth;
        }
        ++ lib.optionals onNix (
          [
            {
              name = "Install Nix";
              uses = cfg.settings.actions.install-nix;
              "with" = {
                extra_nix_config = nixConf;
                github_access_token = expr "github.token";
              };
            }
          ]
          ++ lib.optional job.cachix.push {
            name = "Use the project cache";
            uses = cfg.settings.actions.cachix;
            "with" = {
              name = cfg.settings.cachix.name;
              authToken = expr "secrets.CACHIX_AUTH_TOKEN";
            };
          }
          ++ [ (realiseStep wfName id job.system bundle) ]
        );
    in
    {
      inherit bundle;
      features = lib.sort (a: b: a < b) (lib.unique features);
      attrs =
        dropEmpty {
          inherit (job)
            name
            runs-on
            timeout-minutes
            permissions
            outputs
            ;
          needs = lib.optional lazy "plan" ++ job.needs;
          "if" = if condition == null then null else expr condition;
          env =
            job.env
            // lib.optionalAttrs (lazy && job.lazy.granular) {
              CI_UNITS = expr "join(${staleOf id}, ' ')";
            };
          defaults =
            if onNix then
              { run.shell = "${tools.pkgs.bash}/bin/bash --noprofile --norc -eo pipefail {0}"; }
            else
              null;
          steps =
            # Already in their rendered shape: they are not options, and only
            # the realise step runs anything.
            bootstrap ++ map renderStep steps;
        }
        // job.extra;
    };

  # ── laziness: units → keys → stamps ────────────────────────────────

  # Each unit's own content, hashed once: the store path of its fileset.
  unitSources = lib.mapAttrs (
    _: u:
    if fs.toList u.files == [ ] then
      "empty"
    else
      "${fs.toSource {
        inherit root;
        fileset = u.files;
      }}"
  ) graph.units;

  sourcesOf =
    names: map (n: "${n}=${unitSources.${n}}") (lib.sort (a: b: a < b) (graph.closure names));

  planOf =
    wfName: wf:
    lib.mapAttrs (
      id: job:
      let
        keyJob =
          (renderJob {
            inherit
              wfName
              wf
              id
              job
              ;
            variant = "key";
          }).attrs;
        common = {
          job = keyJob;
          drvs = map (d: d.drvPath) job.lazy.drvs;
        };
        entries =
          if job.lazy.granular then
            map (u: {
              unit = u;
              arg = graph.units.${u}.arg or u;
              sources = sourcesOf ([ u ] ++ job.lazy.common);
            }) job.lazy.units
          else
            [
              {
                unit = "all";
                arg = "all";
                sources = sourcesOf (job.lazy.units ++ job.lazy.common);
              }
            ];
        stamp =
          e:
          let
            content = stamps.content {
              job = "${wfName}/${id}";
              inherit (e) unit;
              key = stamps.key (common // { inherit (e) sources; });
            };
            name = stamps.name id;
          in
          {
            inherit (e) arg;
            inherit name content;
            path = stamps.path name content;
          };
      in
      {
        inherit (job.lazy) granular;
        units = lib.listToAttrs (map (e: lib.nameValuePair e.unit (stamp e)) entries);
      }
    ) (lib.filterAttrs (_: j: j.lazy.enable) wf.jobs);

  # ── the planner and the fan-in ─────────────────────────────────────

  planJob = wfName: {
    name = "plan";
    system = cfg.settings.planSystem;
    timeout-minutes = 20;
    cachix.push = false;
    outputs.stale = expr "steps.plan.outputs.stale";
    steps = tools: [
      {
        name = "Find the work that is new";
        id = "plan";
        run = tools.plan;
        args = [ wfName ];
        env.CI_FORCE = expr "inputs.force && '1' || '0'";
      }
      {
        name = "Keep the plan for the fan-in";
        uses = cfg.settings.actions.upload-artifact;
        "with" = {
          name = "ci-plan";
          path = "plan.json";
          retention-days = 7;
        };
      }
    ];
  };

  fanInJob = wfName: wf: ids: {
    name = wf.fanIn.name;
    needs = ids;
    "if" = "always()";
    system = cfg.settings.planSystem;
    timeout-minutes = 15;
    cachix.push = false;
    steps =
      tools:
      lib.optionals wf.plan.enable [
        {
          name = "Fetch the plan";
          uses = cfg.settings.actions.download-artifact;
          "with".name = "ci-plan";
          continue-on-error = true;
        }
        {
          name = "Record the work that passed";
          "if" = "always()";
          run = tools.record;
          # Losing a stamp only costs a re-run; it is not a red build.
          continue-on-error = true;
          env = {
            RESULTS = builtins.toJSON (lib.genAttrs ids (id: expr "needs.${id}.result"));
            CACHIX_AUTH_TOKEN = expr "secrets.CACHIX_AUTH_TOKEN";
            CACHIX_CACHE = cfg.settings.cachix.name;
          };
        }
      ]
      ++ [
        {
          name = "Every job succeeded or was skipped";
          "if" = "always()";
          run = tools.verdict;
          env.RESULTS = builtins.toJSON (lib.genAttrs ids (id: expr "needs.${id}.result"));
        }
      ];
  };

  # The workflow with its generated jobs added, as option values.
  completed =
    wfName: wf:
    let
      userIds = builtins.attrNames wf.jobs;
      extraJobs =
        lib.optionalAttrs wf.plan.enable { plan = planJob wfName; }
        // lib.optionalAttrs wf.fanIn.enable {
          ci = fanInJob wfName wf (lib.optional wf.plan.enable "plan" ++ userIds);
        };
      evalJob =
        id: def:
        (lib.evalModules {
          specialArgs.name = id;
          modules = [
            jobModule
            def
          ];
        }).config;
    in
    wf // { jobs = wf.jobs // lib.mapAttrs evalJob extraJobs; };

  rendered = lib.mapAttrs (
    wfName: wf0:
    let
      wf = completed wfName wf0;
      jobs = lib.mapAttrs (
        id: job:
        renderJob {
          inherit
            wfName
            wf
            id
            job
            ;
          variant = "real";
        }
      ) wf.jobs;
      nixJobs = lib.filterAttrs (id: _: wf.jobs.${id}.system != null) jobs;
    in
    {
      inherit (wf) file;
      bundles = lib.mapAttrs (_: j: j.bundle) nixJobs;
      features = lib.mapAttrs (_: j: j.features) nixJobs;
      text =
        yaml.toYAML
          {
            header = ''
              # Generated from nix/ci/workflows/${wfName}.nix — do not edit by hand.
              # Regenerate with `nix run .#render-workflows` (also a pre-commit hook).
            '';
          }
          (dropEmpty {
            inherit (wf)
              name
              on
              permissions
              concurrency
              env
              ;
            jobs = lib.mapAttrs (_: j: j.attrs) jobs;
          });
      plan = planOf wfName wf;
    }
  ) cfg.workflows;

  files = lib.mapAttrs' (_: r: lib.nameValuePair r.file r.text) rendered;
in
{
  imports = [
    ./tools.nix
    ./workflows/ci.nix
    ./workflows/main-checks.nix
    ./workflows/docs.nix
    ./workflows/link-check.nix
    ./workflows/release.nix
    ./workflows/fdroid.nix
  ];

  options.ci = {
    defaultValues.jobs = {
      system = mkOption {
        type = types.nullOr types.str;
        default = "x86_64-linux";
      };
      timeout-minutes = mkOption {
        type = types.int;
        default = 30;
      };
    };
    settings = {
      planSystem = mkOption {
        type = types.str;
        default = "x86_64-linux";
      };
      runners = mkOption {
        type = types.attrsOf types.str;
        default = {
          x86_64-linux = "ubuntu-latest";
          aarch64-linux = "ubuntu-24.04-arm";
          aarch64-darwin = "macos-latest";
        };
      };
      cachix.name = mkOption {
        type = types.str;
        default = "sparkles";
      };
      # The flake's own `nixConfig` — the one place the caches are named.
      nixConfig = mkOption {
        type = types.attrsOf types.anything;
        default = (import ../../flake.nix).nixConfig;
      };
      actions = mkOption {
        type = types.attrsOf types.str;
        default = {
          checkout = "actions/checkout@v7";
          install-nix = "cachix/install-nix-action@v31";
          cachix = "cachix/cachix-action@v17";
          cache = "actions/cache@v6";
          cache-restore = "actions/cache/restore@v6";
          cache-save = "actions/cache/save@v6";
          upload-artifact = "actions/upload-artifact@v7";
          download-artifact = "actions/download-artifact@v8";
          setup-dlang = "dlang-community/setup-dlang@v2";
        };
      };
    };
    workflows = mkOption {
      type = types.attrsOf (types.submodule workflowModule);
      default = { };
    };
    graph = mkOption {
      type = types.raw;
      readOnly = true;
      default = graph;
      description = "The repository's unit graph (`lib/graph.nix`), for workflow definitions.";
    };
  };

  config = {
    flake.ci = {
      inherit files;
      plan = lib.mapAttrs (_: r: r.plan) rendered;
      bundles = lib.mapAttrs (_: r: r.bundles) rendered;
      # The dev-shell features each job's `t.inShell` steps get.
      features = lib.mapAttrs (_: r: r.features) rendered;
      units = lib.mapAttrs (_: u: u.deps) graph.units;
    };

    perSystem =
      { pkgs, ... }:
      let
        committed =
          path: if builtins.pathExists (root + "/${path}") then builtins.readFile (root + "/${path}") else "";
        # Compared and written as text: the check must not build the steps of
        # every runner (a macOS script cannot be built on Linux).
        plain = builtins.unsafeDiscardStringContext;
        stale = lib.filterAttrs (path: text: committed path != text) files;
      in
      {
        # `nix run .#render-workflows`: write every workflow file, from the
        # flake as it is on disk now (not as it was when a shell was built).
        packages.render-workflows = pkgs.writeShellApplication {
          name = "render-workflows";
          runtimeInputs = [
            pkgs.nix
            pkgs.jq
            pkgs.gitMinimal
          ];
          text = ''
            cd "$(git rev-parse --show-toplevel)"
            nix eval --json '.#ci.files' \
              | jq -r 'to_entries[] | [.key, .value] | @json' \
              | while IFS= read -r row; do
                  path=$(jq -r '.[0]' <<< "$row")
                  mkdir -p "$(dirname "$path")"
                  jq -j '.[1]' <<< "$row" > "$path.tmp"
                  if cmp -s "$path.tmp" "$path"; then rm "$path.tmp"; else mv "$path.tmp" "$path"; echo "wrote $path"; fi
                done
          '';
        };

        # Drift: the committed workflows are exactly what the flake renders.
        # Then actionlint (with shellcheck) over the rendered files.
        checks.ci-workflows =
          pkgs.runCommand "ci-workflows"
            {
              nativeBuildInputs = [ pkgs.actionlint ];
            }
            ''
              ${lib.concatStrings (
                lib.mapAttrsToList (path: text: ''
                  echo "::error::${path} is stale; run: nix run .#render-workflows"
                  diff -u ${builtins.toFile "committed.yml" (committed path)} ${builtins.toFile "rendered.yml" (plain text)} || true
                '') stale
              )}
              ${lib.optionalString (stale != { }) "exit 1"}
              mkdir -p .github/workflows
              ${lib.concatStrings (
                lib.mapAttrsToList (path: text: ''
                  cp ${builtins.toFile "workflow.yml" (plain text)} ${lib.escapeShellArg path}
                '') files
              )}
              actionlint -shellcheck=${lib.getExe pkgs.shellcheck} .github/workflows/*.yml
              touch $out
            '';
      };
  };
}
