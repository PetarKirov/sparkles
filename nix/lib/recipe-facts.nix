# The recipe table (docs/specs/wired/wasm, WW9): what the dub manifest walks of
# manifest-graph.nix need from each `dub.sdl`, read once per evaluation.
#
# A recipe's *facts* are its `subPackage` paths, its configuration names in
# declaration order, and, for its top level (`preamble`) and for each
# configuration (`scopes.<name>`), a *scope*:
#
#   deps              the in-tree dependencies, `sparkles:<name>` → `<name>`
#   subConfigurations `{ <name> = <configuration>; }` for in-tree packages
#   siblingRefs       `<name>` of each `../<name>/src` in importPaths/sourcePaths
#   libRefs           `<name>` of each `../../libs/<name>/src` there
#
# each list in declaration order. Two readers produce them: the dub recipe
# module under `builtins.wasm` (`module`, when the evaluator has the builtin),
# and regular expressions over the text otherwise (WW7). Comments are not
# edges in either. Builtins only, so the agreement check can import it with no
# nixpkgs at hand.
{
  root,
  # The module, a path to `spk-dub-manifest.wasm`, or null for the fallback.
  module ? null,
}:
let
  inherit (builtins)
    concatLists
    concatStringsSep
    elemAt
    filter
    head
    isList
    isString
    length
    listToAttrs
    match
    pathExists
    readFile
    split
    ;
  concatMap = f: l: concatLists (map f l);
  matchAll = re: s: map head (filter isList (split re s));
  matchAllPairs = re: s: filter isList (split re s);

  emptyScope = {
    deps = [ ];
    subConfigurations = { };
    siblingRefs = [ ];
    libRefs = [ ];
  };
  emptyFacts = {
    subPackages = [ ];
    configurations = [ ];
    preamble = emptyScope;
    scopes = { };
  };

  # --- The typed reader: the module's recipe (WW4's attribute set). ---

  inTree =
    name:
    let
      m = match "sparkles:([a-z-]+)" name;
    in
    if m == null then [ ] else m;

  typedScope =
    s:
    let
      paths = concatMap (e: e.values or [ ]) ((s.importPaths or [ ]) ++ (s.sourcePaths or [ ]));
    in
    {
      deps = concatMap (d: inTree d.name) (s.dependencies or [ ]);
      subConfigurations = listToAttrs (
        concatMap (
          c:
          map (n: {
            name = n;
            value = c.configuration;
          }) (inTree c.dependency)
        ) (s.subConfigurations or [ ])
      );
      siblingRefs = concatMap (matchAll ''\.\./([a-z-]+)/src'') paths;
      libRefs = concatMap (matchAll ''\.\./\.\./libs/([a-z-]+)/src'') paths;
    };

  typedFacts = recipe: {
    subPackages = map (s: s.path) (filter (s: s ? path) (recipe.subPackages or [ ]));
    configurations = map (c: c.name) (recipe.configurations or [ ]);
    preamble = typedScope recipe;
    scopes = listToAttrs (
      map (c: {
        inherit (c) name;
        value = typedScope c;
      }) (recipe.configurations or [ ])
    );
  };

  # The module's facts for `text`, named `name` in an error (WW5).
  wasmFactsOfText =
    text: name:
    let
      answer = builtins.wasm { path = module; } { inherit text name; };
      e = answer.error;
    in
    if answer ? error then
      throw "${e.name}:${toString e.line}:${toString e.column}: ${e.message}"
    else
      typedFacts answer.recipe;

  # --- The fallback: regular expressions over the text. ---

  # `//` comments end at the line's end. A recipe whose comment the reader
  # mistakes for a directive is caught by the agreement check (WW10).
  stripLineComments =
    text:
    concatStringsSep "\n" (map (line: head (split "//" line)) (filter isString (split "\n" text)));

  # The text at brace depth zero, and the body of each top-level block.
  topLevelOf =
    text:
    let
      step =
        depth: acc: rest:
        if rest == [ ] then
          acc
        else
          let
            h = head rest;
            t = builtins.tail rest;
          in
          if isList h then
            step (if head h == "{" then depth + 1 else depth - 1) acc t
          else
            step depth (if depth == 0 then acc + h else acc) t;
    in
    step 0 "" (split "([{}])" text);

  # The body inside `configuration "name" { ... }`, braces respected.
  configBody =
    text: name:
    let
      parts = split (''configuration "'' + name + ''" \{'') text;
      after = if length parts < 3 then "" else elemAt parts 2;
      step =
        depth: acc: rest:
        if rest == [ ] || depth == 0 then
          acc
        else
          let
            h = head rest;
            t = builtins.tail rest;
          in
          if isList h then
            let
              ch = head h;
            in
            if ch == "{" then
              step (depth + 1) (acc + ch) t
            else if ch == "}" && depth == 1 then
              acc
            else if ch == "}" then
              step (depth - 1) (acc + ch) t
            else
              step depth (acc + ch) t
          else
            step depth (acc + h) t;
    in
    step 1 "" (split "([{}])" after);

  textScope = t: {
    deps = matchAll ''dependency "sparkles:([a-z-]+)"'' t;
    subConfigurations = listToAttrs (
      map (p: {
        name = elemAt p 0;
        value = elemAt p 1;
      }) (matchAllPairs ''subConfiguration "sparkles:([a-z-]+)" "([A-Za-z0-9-]+)"'' t)
    );
    siblingRefs = matchAll ''\.\./([a-z-]+)/src'' t;
    libRefs = matchAll ''\.\./\.\./libs/([a-z-]+)/src'' t;
  };

  regexFactsOfText =
    raw:
    let
      text = stripLineComments raw;
      top = topLevelOf text;
      names = matchAll ''configuration "([A-Za-z0-9-]+)"'' top;
    in
    {
      subPackages = matchAll ''subPackage "([^"]+)"'' top;
      configurations = names;
      preamble = textScope top;
      scopes = listToAttrs (
        map (n: {
          name = n;
          value = textScope (configBody text n);
        }) names
      );
    };

  # --- The table. ---

  hasWasm = builtins ? wasm && module != null;
  recipeOf = dir: root + "/${dir}/dub.sdl";
  factsOf =
    dir:
    let
      f = recipeOf dir;
    in
    if !pathExists f then
      emptyFacts
    else if hasWasm then
      wasmFactsOfText (readFile f) "${dir}/dub.sdl"
    else
      regexFactsOfText (readFile f);

  rootFacts = factsOf ".";
  # Every recipe a walk reads is the root's or one the root declares; each
  # value is computed when first read, and only then.
  table = listToAttrs (
    map (d: {
      name = d;
      value = factsOf d;
    }) rootFacts.subPackages
  );
in
{
  inherit
    emptyScope
    hasWasm
    regexFactsOfText
    wasmFactsOfText
    rootFacts
    ;
  # The facts of the recipe in `dir`, repository-relative.
  facts = dir: if dir == "." then rootFacts else table.${dir} or (factsOf dir);
}
