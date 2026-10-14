# Pass stamps: how CI remembers that a job already passed on these inputs.
#
# A stamp is a tiny flat file in the Nix store whose *content* is a hash of
# everything the job's outcome depends on. Its store path is that of a
# fixed-output (flat, sha256) path, so:
#
#   * evaluation computes it without building anything (`path`), and
#   * a runner that just passed creates the very same path with
#     `nix store add --mode flat --hash-algo sha256 --name <name> <file>`.
#
# The planner asks the binary cache whether the path exists — a narinfo
# lookup — and skips the work when it does. Nothing but the cache's own
# access control decides who may record a pass: forks can read stamps and
# skip, only runs holding the push token can write them.
{ lib }:
rec {
  # Store-name-safe: the job id is already `[a-z0-9-]`, prefixed for clarity.
  name = job: "ci-pass-${job}";

  # The stamp's file content. The job and unit are in it so two units whose
  # keys collide still have distinct, self-describing stamps.
  content =
    {
      job,
      unit,
      key,
    }:
    "${job}\n${unit}\n${key}\n";

  path =
    stampName: text:
    (derivation {
      name = stampName;
      system = "builtin";
      builder = "builtin:fetchurl";
      url = "ci-stamp:${stampName}";
      outputHashMode = "flat";
      outputHashAlgo = "sha256";
      outputHash = builtins.hashString "sha256" text;
    }).outPath;

  # The key: a hash over JSON. String context is dropped first — the key names
  # store paths, it does not depend on them existing.
  key =
    material:
    builtins.hashString "sha256" (builtins.unsafeDiscardStringContext (builtins.toJSON material));
}
