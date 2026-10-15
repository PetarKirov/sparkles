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
# The work itself is declared once, as tasks (`ci.tasks.<name>`, ./tasks.nix):
# a named program with the units it covers, the dev-shell features it needs
# and the tasks it runs after — devenv's task model, built to store paths. A
# job places tasks on a runner (`{ task = "test"; units = shard; }`), and a
# pass is remembered per (task, unit), whichever job ran it. `nix run
# .#ciTasks.<name> -- [units…]` runs a task locally exactly as a job does.
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
      task = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Run the task `ci.tasks.<name>` here: its program, preceded by its
          `after` tasks. The step's own name, id, `if`, env and args override
          or extend the task's.
        '';
      };
      units = mkOption {
        type = types.nullOr (types.listOf types.str);
        default = null;
        description = "The task's units this step covers (a shard). Default: all of them.";
      };
    };
  };

  taskModule =
    { name, ... }:
    {
      options = {
        description = mkOption {
          type = types.str;
          default = name;
          description = "One line; the step's name where a job runs it.";
        };
        units = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "The units the task covers; a pass is remembered per (task, unit).";
        };
        granular = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Track each unit separately: the task runs only its stale units,
            which it reads from `$CI_UNITS` (the units' `arg`s, space-separated).
            Otherwise it is one piece of work over all of them.
          '';
        };
        common = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Units every stamp of this task also depends on (the harness).";
        };
        drvs = mkOption {
          type = types.functionTo (types.listOf types.package);
          default = _: [ ];
          description = "From the tools, the derivations whose `drvPath`s join the key (a task that builds them).";
        };
        features = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = ''
            Dev-shell features (`ciFeatures` in nix/shells/default.nix) the
            task's `t.inShell` program needs beyond those its units' closures
            need (`graph.needsOf`).
          '';
        };
        after = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Tasks that run first, in the same job (each once).";
        };
        run = mkOption {
          type = types.functionTo types.package;
          description = ''
            From the tools (bound to this task's features), the program: one
            of the `nix/ci/tools.nix` factories.
          '';
        };
        args = mkOption {
          type = types.listOf types.str;
          default = [ ];
        };
        env = mkOption {
          type = types.attrsOf types.str;
          default = { };
          description = "Step environment (GitHub expressions allowed); not applied by a local run.";
        };
        "if" = mkOption {
          type = types.nullOr types.str;
          default = null;
        };
        id = mkOption {
          type = types.nullOr types.str;
          default = null;
        };
        continue-on-error = mkOption {
          type = types.nullOr (types.either types.bool types.str);
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
            type = types.nullOr types.bool;
            default = null;
            description = ''
              Skip this job when everything it covers already passed. `null`:
              when it covers anything — its own `lazy` units or derivations, or
              those of the tasks it runs. `false` for work that must happen
              every time (a release pins what it built).
            '';
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
          default = lib.any isLazy (builtins.attrValues config.jobs);
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
          lib.concatStringsSep " " ([ "$CI_BUNDLE/bin/${s.slot}" ] ++ s.args)
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

  # A job's store-path steps, each under a name that does not change when its
  # program does: the YAML runs `"$CI_BUNDLE"/bin/<slot>`, so it names no
  # store path that a library edit would change.
  slotted = lib.imap1 (
    i: s:
    s
    // {
      slot =
        if lib.isDerivation s.run then
          "${lib.fixedWidthNumber 2 i}-${baseNameOf (builtins.unsafeDiscardStringContext (lib.getExe s.run))}"
        else
          null;
    }
  );

  # Everything a Nix job runs, in one store path: realising it fetches (or
  # builds) the whole closure up front, and `bin/` holds the steps.
  bundleOf =
    tools: id: steps:
    tools.pkgs.linkFarm "ci-job-${id}" (
      [
        {
          name = "bash";
          path = "${tools.pkgs.bash}/bin/bash";
        }
      ]
      ++ map (s: {
        name = "bin/${s.slot}";
        path = lib.getExe s.run;
      }) (builtins.filter (s: s.slot != null) steps)
    );

  # The bundle is resolved when the job runs, from the commit it runs
  # (`source`): a job that needs the planner takes it from the plan, whose
  # stamps were keyed by the same evaluation; any other job evaluates it. So
  # what runs is what the flake says now, never what an older render
  # committed — and a library edit changes no workflow file.
  realiseStep = wfName: id: source: {
    name = "Realise the job's closure";
    # The one bootstrap seam: no store path can run before this step has
    # fetched them, so it uses the runner's bash and the installer's profile.
    shell = "bash";
    run = ''
      set -euo pipefail
      nix=/nix/var/nix/profiles/default/bin
      attr='.#ci.bundles.${wfName}.${id}'
      bundle=${
        if source == "plan" then
          "'${expr "fromJSON(needs.plan.outputs.bundles)['${id}']"}'"
        else if source == "eval" then
          ''$("$nix/nix" eval --raw "$attr.outPath")''
        else
          source
      }
      if "$nix/nix-store" --realise "$bundle" > /dev/null 2>&1; then
        echo "Substituted $bundle"
      else
        echo "::group::Building the job's closure (not in the binary cache yet)"
        built=$("$nix/nix" build --no-link --print-out-paths -L "$attr")
        echo "::endgroup::"
        if [ "$built" != "$bundle" ]; then
          echo "::error::the bundle resolved to $bundle, but the flake builds $built (an impure evaluation?)"
          exit 1
        fi
      fi
      echo "CI_BUNDLE=$bundle" >> "$GITHUB_ENV"
    '';
  };

  # Whether a job takes its bundle from the planner: it needs it, and is not
  # it.
  fromPlan =
    wf: id: job:
    wf.plan.enable && id != "plan" && (isLazy job || builtins.elem "plan" job.needs);

  staleOf = id: "fromJSON(needs.plan.outputs.stale)['${id}']";

  # ── tasks in jobs ───────────────────────────────────────────────────

  taskOf =
    name: cfg.tasks.${name} or (throw "ci: unknown task `${name}` (define it under `ci.tasks`)");

  # A task's units, its features and its tools: what one placement of it
  # (all its units, or a shard) needs, and nothing else.
  instanceFeatures = task: units: graph.needsOf (units ++ task.common) ++ task.features;
  instanceTools =
    variant: system: task: units:
    (toolsFor variant system).withFeatures (instanceFeatures task units);

  # `name` and the tasks it runs after, dependencies first, each once.
  taskOrder =
    names:
    let
      visit =
        acc: name:
        if builtins.elem name acc.seen then
          acc
        else
          let
            deps = lib.foldl' visit (acc // { seen = acc.seen ++ [ name ]; }) (taskOf name).after;
          in
          deps // { order = deps.order ++ [ name ]; };
    in
    (lib.foldl' visit {
      seen = [ ];
      order = [ ];
    } names).order;

  # A job's steps with each task step replaced by the steps of its `after`
  # tasks (once per job) and its own, and the placements (`instances`) that
  # carry the laziness: the task, its units, and its program.
  expandSteps =
    variant: job: steps:
    let
      pick =
        s: t: f:
        if s.${f} != null then s.${f} else t.${f};
      toolsOf = name: units: instanceTools variant job.system (taskOf name) units;
      programOf = name: units: (taskOf name).run (toolsOf name units);
      expand =
        acc: s:
        if s.task == null then
          acc // { steps = acc.steps ++ [ s ]; }
        else if job.system == null then
          throw "ci: task `${s.task}` is a store path; a job without Nix cannot run it"
        else
          let
            task = taskOf s.task;
            units = if s.units != null then s.units else task.units;
            deps = builtins.filter (n: n != s.task && !builtins.elem n acc.ran) (taskOrder [ s.task ]);
            depStep = name: {
              name = (taskOf name).description;
              run = programOf name (taskOf name).units;
              inherit (taskOf name)
                args
                env
                id
                continue-on-error
                ;
              "if" = (taskOf name)."if";
              uses = null;
              "with" = { };
              shell = null;
              timeout-minutes = null;
              task = name;
              units = null;
            };
            program = programOf s.task units;
            step = s // {
              name = if s.name != null then s.name else task.description;
              id = pick s task "id";
              "if" = pick s task "if";
              continue-on-error = pick s task "continue-on-error";
              env = task.env // s.env;
              args = task.args ++ s.args;
              run = program;
            };
          in
          acc
          // {
            steps = acc.steps ++ map depStep deps ++ [ step ];
            ran = acc.ran ++ deps ++ [ s.task ];
            instances = acc.instances ++ [
              rec {
                name = s.task;
                inherit task units program;
                inherit (step) env args;
                "if" = step."if";
                after = map (n: toString (programOf n (taskOf n).units)) deps;
                features = instanceFeatures task units;
                drvs = map (d: d.drvPath) (task.drvs (toolsOf s.task units));
                lazy = units != [ ] || drvs != [ ];
              }
            ];
          };
    in
    builtins.removeAttrs (lib.foldl' expand {
      steps = [ ];
      ran = [ ];
      instances = [ ];
    } steps) [ "ran" ];

  lazyInstances = builtins.filter (i: i.lazy);

  # Whether a job is skipped when everything it covers already passed: its
  # own `lazy`, or any task it runs that covers units or builds derivations.
  isLazy =
    job:
    if job.lazy.enable != null then
      job.lazy.enable
    else
      job.lazy.units != [ ]
      || job.lazy.drvs != [ ]
      || (
        job.system != null
        && builtins.any (
          s:
          s.task != null
          && (
            let
              t = taskOf s.task;
            in
            (if s.units != null then s.units else t.units) != [ ] || t.drvs (toolsFor "key" job.system) != [ ]
          )
        ) (job.steps (toolsFor "key" job.system))
      );

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
      expanded = expandSteps variant job (job.steps tools);
      inherit (expanded) instances;
      steps = slotted expanded.steps;
      lazy = wf.plan.enable && isLazy job;
      granularTasks = builtins.filter (i: i.task.granular) (lazyInstances instances);
      granular =
        if builtins.length granularTasks + (if job.lazy.granular then 1 else 0) > 1 then
          throw "ci: job `${id}` runs more than one granular piece of work; `$CI_UNITS` can name one"
        else
          job.lazy.granular || granularTasks != [ ];
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
          ++ [
            (realiseStep wfName id (
              if fromPlan wf id job then
                "plan"
              # The planner's own tools come from nixpkgs alone, so naming
              # them changes only with a nixpkgs bump, and spares the
              # critical path an evaluation.
              else if id == "plan" then
                bundle
              else
                "eval"
            ))
          ]
        );
    in
    {
      inherit bundle instances;
      features = lib.sort (a: b: a < b) (
        lib.unique (features ++ lib.concatMap (i: i.features) instances)
      );
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
            // lib.optionalAttrs (lazy && granular) {
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

  # A job's stamps: one per (task, unit) for the tasks it runs, keyed by what
  # the task's outcome depends on — so another job running the same task on
  # the same unit, with the same environment, shares the pass. A job without
  # tasks (one without Nix) keys its own `lazy` units by its rendered YAML.
  planOf =
    wfName: wf:
    lib.mapAttrs (
      id: job:
      let
        keyed = renderJob {
          inherit
            wfName
            wf
            id
            job
            ;
          variant = "key";
        };
        stampOf =
          {
            scope,
            unit,
            arg,
            material,
          }:
          let
            content = stamps.content {
              job = scope;
              inherit unit;
              key = stamps.key material;
            };
            name = stamps.name (lib.last (lib.splitString "/" scope));
          in
          {
            inherit arg name content;
            path = stamps.path name content;
          };
        per =
          granular: units: common: mk:
          if granular then
            map (u: mk u (graph.units.${u}.arg or u) (sourcesOf ([ u ] ++ common))) units
          else
            [ (mk "all" "all" (sourcesOf (units ++ common))) ];

        jobEntries = lib.optionals (job.lazy.units != [ ] || job.lazy.drvs != [ ]) (
          per job.lazy.granular job.lazy.units job.lazy.common (
            unit: arg: sources: {
              name = unit;
              value = stampOf {
                scope = "${wfName}/${id}";
                inherit unit arg;
                material = {
                  job = keyed.attrs;
                  drvs = map (d: d.drvPath) job.lazy.drvs;
                  inherit sources;
                };
              };
            }
          )
        );

        taskEntries = lib.concatMap (
          i:
          per i.task.granular i.units i.task.common (
            unit: arg: sources: {
              name = "${i.name}/${unit}";
              value = stampOf {
                scope = "task/${i.name}";
                inherit unit arg;
                material = {
                  inherit (job) system;
                  inherit (i)
                    args
                    env
                    after
                    drvs
                    ;
                  "if" = i."if";
                  program = toString i.program;
                  # Job-level settings a task's outcome can depend on.
                  jobEnv = job.env;
                  fetch-depth = job.checkout.fetch-depth;
                  inherit sources;
                };
              };
            }
          )
        ) (lazyInstances keyed.instances);
      in
      {
        granular = job.lazy.granular || builtins.any (i: i.task.granular) (lazyInstances keyed.instances);
        units = lib.listToAttrs (jobEntries ++ taskEntries);
      }
    ) (lib.filterAttrs (_: isLazy) wf.jobs);

  # ── the planner and the fan-in ─────────────────────────────────────

  planJob = wfName: {
    name = "plan";
    system = cfg.settings.planSystem;
    timeout-minutes = 20;
    cachix.push = false;
    outputs = {
      stale = expr "steps.plan.outputs.stale";
      bundles = expr "steps.plan.outputs.bundles";
    };
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
      plan = {
        jobs = planOf wfName wf;
        # What the jobs that need the planner will run, from this same
        # evaluation that keyed their stamps.
        bundles = lib.mapAttrs (_: j: toString j.bundle) (
          lib.filterAttrs (id: _: fromPlan wf id wf.jobs.${id}) nixJobs
        );
      };
    }
  ) cfg.workflows;

  files = lib.mapAttrs' (_: r: lib.nameValuePair r.file r.text) rendered;
in
{
  imports = [
    ./tools.nix
    ./tasks.nix
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
    tasks = mkOption {
      type = types.attrsOf (types.submodule taskModule);
      default = { };
      description = "The work CI does, once each; jobs place it (`{ task = …; }` steps).";
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
      # What each task covers and needs, for a look before an edit.
      tasks = lib.mapAttrs (n: t: {
        inherit (t)
          description
          units
          granular
          common
          after
          ;
        features = lib.sort (a: b: a < b) (lib.unique (instanceFeatures t t.units));
      }) cfg.tasks;
    };

    perSystem =
      { pkgs, system, ... }:
      let
        committed =
          path: if builtins.pathExists (root + "/${path}") then builtins.readFile (root + "/${path}") else "";
        # Compared and written as text: the check must not build the steps of
        # every runner (a macOS script cannot be built on Linux).
        plain = builtins.unsafeDiscardStringContext;
        stale = lib.filterAttrs (path: text: committed path != text) files;
      in
      {
        # `nix run .#ciTasks.<name> -- [units…]`: a task as a job runs it — its
        # `after` tasks, then its program, over the given unit args (default:
        # all of its units). A job's env (`DC`, tokens) is the caller's to set.
        legacyPackages.ciTasks = lib.mapAttrs (
          name: task:
          let
            programOf = n: (taskOf n).run (instanceTools "real" system (taskOf n) (taskOf n).units);
            call = n: "${lib.getExe (programOf n)} ${lib.concatStringsSep " " (taskOf n).args}";
            allArgs = map (u: graph.units.${u}.arg or u) task.units;
          in
          pkgs.writeShellApplication {
            name = "ci-task-${name}";
            text = ''
              if [ "$#" -gt 0 ]; then CI_UNITS="$*"; else CI_UNITS="''${CI_UNITS:-${lib.concatStringsSep " " allArgs}}"; fi
              export CI_UNITS
              ${lib.concatMapStrings (n: call n + "\n") (lib.init (taskOrder [ name ]))}
              exec ${call name}
            '';
          }
        ) cfg.tasks;

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
