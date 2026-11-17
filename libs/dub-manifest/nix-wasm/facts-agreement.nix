# The recipe table's two readers held to the same facts (docs/specs/wired/wasm,
# WW10): for every recipe the root `dub.sdl` declares, and for seeded fixtures,
# the facts the dub recipe module yields (nix/lib/recipe-facts.nix) must equal
# the regular-expression reader's. Needs an evaluator with `builtins.wasm`:
#
#   nix eval --impure --json --extra-experimental-features wasm-builtin \
#     --expr 'import ./libs/dub-manifest/nix-wasm/facts-agreement.nix {
#       module = <dub-manifest-nix-wasm>/spk-dub-manifest.wasm; }'
#
# The seeded fixtures are recipes the readers manifest-graph.nix used before
# the table got wrong; `legacyCaught` lists the ones on which that older
# reader disagrees with the module, so the check is seen to catch what it is
# for. A pass: `mismatches` empty, `checked` nonzero, and `legacyCaught`
# naming every fixture.
{
  module,
  root ? ../../..,
}:
let
  facts = import ../../../nix/lib/recipe-facts.nix { inherit root module; };
  matchAll = re: s: map builtins.head (builtins.filter builtins.isList (builtins.split re s));

  # The fileset walk's edges, as recipe-facts' consumers read them.
  closureEdges =
    f:
    let
      before =
        l:
        if l == [ ] || builtins.head l == "unittest" then
          [ ]
        else
          [ (builtins.head l) ] ++ before (builtins.tail l);
      scopes = [ f.preamble ] ++ map (n: f.scopes.${n}) (before f.configurations);
      cat = sel: builtins.concatLists (map sel scopes);
    in
    cat (s: s.deps) ++ cat (s: s.siblingRefs) ++ cat (s: s.libRefs);

  # The fileset walk's edges as manifest-graph.nix read them before the table:
  # the raw text cut at `configuration "unittest"`, comments included.
  legacyClosureEdges =
    text:
    let
      t = builtins.head (builtins.split ''configuration "unittest"'' text);
    in
    matchAll ''dependency "sparkles:([a-z-]+)"'' t
    ++ matchAll ''\.\./([a-z-]+)/src'' t
    ++ matchAll ''\.\./\.\./libs/([a-z-]+)/src'' t;
  # The shipped walk's top level as it read it: the text before the first
  # `configuration "`, so a top-level directive after a configuration was lost.
  legacyPreambleDeps =
    text:
    matchAll ''dependency "sparkles:([a-z-]+)"'' (
      builtins.head (builtins.split ''configuration "'' text)
    );

  fixtures = [
    {
      name = "comment-quoted-dependency/dub.sdl";
      text = ''
        name "a"
        // dependency "sparkles:ghost" path="../.."
        dependency "sparkles:base" path="../.."
      '';
      legacyWrong = text: legacyClosureEdges text != closureEdges (facts.wasmFactsOfText text "a");
    }
    {
      name = "top-level-after-configurations/dub.sdl";
      text = ''
        name "b"
        configuration "library" {
            targetType "library"
        }
        dependency "sparkles:late" path="../.."
      '';
      legacyWrong = text: legacyPreambleDeps text != (facts.wasmFactsOfText text "b").preamble.deps;
    }
  ];

  dirs = [ "." ] ++ facts.rootFacts.subPackages;
  readable = dir: builtins.pathExists (root + "/${dir}/dub.sdl");
  recipeMismatches = builtins.filter (
    dir:
    let
      text = builtins.readFile (root + "/${dir}/dub.sdl");
    in
    facts.regexFactsOfText text != facts.wasmFactsOfText text "${dir}/dub.sdl"
  ) (builtins.filter readable dirs);
  fixtureMismatches = map (f: f.name) (
    builtins.filter (f: facts.regexFactsOfText f.text != facts.wasmFactsOfText f.text f.name) fixtures
  );
in
{
  checked = builtins.length (builtins.filter readable dirs) + builtins.length fixtures;
  mismatches = recipeMismatches ++ fixtureMismatches;
  legacyCaught = map (f: f.name) (builtins.filter (f: f.legacyWrong f.text) fixtures);
  fixtures = map (f: f.name) fixtures;
}
