# `.github/workflows/fdroid.yml` — build the unsigned release APK that
# F-Droid's metadata points at, push it, and pin it, for a workstation to sign
# (`release publish --stage deploy` resolves the same store path).
{ ... }:
let
  tag = "\${{ github.event.release.tag_name || inputs.tag }}";

  inputs = t: [
    t.pkgs.cachix
    t.nix
    t.pkgs.gitMinimal
  ];
  release = t: "nix ${t.nixFlags} run .#release --";
in
{
  # The three steps, as tasks: `$TAG` comes from the job.
  ci.tasks = {
    fdroid-build = {
      description = "Build and push";
      run = t: t.ciScript "with-cachix.sh" (inputs t);
      args = [
        "nix"
        "run"
        ".#release"
        "--"
        "publish"
        "--tag"
        "\"$TAG\""
        "--stage"
        "build"
        "--no-require-cached"
        "--workdir"
        "\"$RUNNER_TEMP/fdroid-build\""
      ];
    };
    fdroid-pin = {
      description = "Pin the unsigned APK";
      run =
        t:
        t.script "ci-fdroid-pin" {
          runtimeInputs = inputs t;
          text = ''
            CI_TAG="$TAG" CI_PIN_NAME=hue-apk-unsigned CI_PIN_ANY_TAG=1 \
              CI_PIN_PATH=$(${release t} path --tag "$TAG") \
              bash ${t.ciScripts}/release-pin.sh
          '';
        };
    };
    fdroid-handoff = {
      description = "Report the handoff";
      run =
        t:
        t.script "ci-fdroid-handoff" {
          runtimeInputs = inputs t;
          text = ''
            path=$(${release t} path --tag "$TAG")
            {
              echo "## Ready to sign"
              echo
              echo '```console'
              echo "\$ nix run .#release-full -- publish --tag $TAG --stage deploy"
              echo '```'
              echo
              echo "Expected store path — the workstation must resolve the same one,"
              echo "or it is about to sign something other than what was built here:"
              echo
              echo "    $path"
            } >> "$GITHUB_STEP_SUMMARY"
          '';
        };
    };
  };

  ci.workflows.fdroid = {
    name = "F-Droid";
    on = {
      release.types = [ "published" ];
      workflow_dispatch.inputs.tag = {
        description = "Release tag to build (e.g. v0.4.0)";
        required = true;
        type = "string";
      };
    };
    concurrency = {
      group = "fdroid-build-${tag}";
      cancel-in-progress = false;
    };
    jobs.build = {
      name = "Build the unsigned release APK";
      "if" = "github.repository == 'PetarKirov/sparkles'";
      timeout-minutes = 90;
      env = {
        TAG = tag;
        CACHIX_CACHE = "sparkles";
        CACHIX_AUTH_TOKEN = "\${{ secrets.CACHIX_AUTH_TOKEN }}";
      };
      steps = _: [
        { task = "fdroid-build"; }
        { task = "fdroid-pin"; }
        { task = "fdroid-handoff"; }
      ];
    };
  };
}
