# The Nix module's answers against the native oracle's (docs/specs/wired/wasm,
# WW2 and the W2 gate): every tracked `dub.sdl` and `dub.json`, and the
# failure fixtures, each decoded by `builtins.wasm` and compared with what the
# same conversion computes natively. Needs an evaluator with the builtin:
#
#   nix eval --impure --json --extra-experimental-features wasm-builtin \
#     --expr 'import ./libs/dub-manifest/nix-wasm/agreement.nix {
#       module = <dub-manifest-nix-wasm>/spk-dub-manifest.wasm;
#       answers = <dub-manifest-nix-answers>; }'
#
# The result lists every name whose answers differ; an empty `mismatches`
# with a nonzero `checked` is a pass.
{
  module,
  answers,
  root ? ../../..,
}:
let
  call = text: name: builtins.wasm { path = module; } { inherit text name; };
  expectedRecipes = builtins.fromJSON (builtins.readFile "${answers}/recipes.json");
  expectedFixtures = builtins.fromJSON (builtins.readFile "${answers}/fixtures.json");
  fixtures = builtins.fromJSON (builtins.readFile ./fixtures.json);

  recipeMismatches = builtins.filter (
    name: call (builtins.readFile (root + "/${name}")) name != expectedRecipes.${name}
  ) (builtins.attrNames expectedRecipes);
  fixtureMismatches = map (f: f.name) (
    builtins.filter (f: call f.text f.name != expectedFixtures.${f.name}) fixtures
  );
in
{
  checked = builtins.length (builtins.attrNames expectedRecipes) + builtins.length fixtures;
  mismatches = recipeMismatches ++ fixtureMismatches;
}
