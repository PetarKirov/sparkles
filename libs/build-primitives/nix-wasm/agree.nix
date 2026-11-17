# PROTOTYPE (#452): compare manifest-graph.nix's regex readers with the
# builtins.wasm recipe decoder over every recipe the root dub.sdl declares.
# nix eval --impure --json --extra-experimental-features wasm-builtin --expr 'import ./agree.nix {}'
{
  root ? ../../..,
  wasm ? ./build/opt.wasm,
}:
let
  parse = text: builtins.wasm { path = wasm; } text;

  # --- the regex readers, as manifest-graph.nix has them ---
  matchAll = re: s: map builtins.head (builtins.filter builtins.isList (builtins.split re s));
  readManifest =
    relDir:
    let
      f = root + "/${relDir}/dub.sdl";
    in
    if builtins.pathExists f then
      builtins.head (builtins.split ''configuration "unittest"'' (builtins.readFile f))
    else
      "";
  refsOf =
    text:
    matchAll ''dependency "sparkles:([a-z-]+)"'' text
    ++ matchAll ''\.\./([a-z-]+)/src'' text
    ++ matchAll ''\.\./\.\./libs/([a-z-]+)/src'' text;
  regexSubPackages = matchAll ''subPackage "([^"]+)"'' (builtins.readFile (root + "/dub.sdl"));

  # --- the same answers from the typed recipe ---
  rootRecipe = parse (builtins.readFile (root + "/dub.sdl"));
  wasmSubPackages = map (s: s.path) (builtins.filter (s: s ? path) (rootRecipe.subPackages or [ ]));

  concatMap = f: l: builtins.concatLists (map f l);
  unique = l: builtins.foldl' (acc: x: if builtins.elem x acc then acc else acc ++ [ x ]) [ ] l;
  sort = builtins.sort builtins.lessThan;
  minus = a: b: builtins.filter (x: !builtins.elem x b) a;

  pathRefsIn =
    values:
    concatMap (
      v:
      let
        m1 = builtins.match ''.*\.\./\.\./libs/([a-z-]+)/src.*'' v;
        m2 = builtins.match ''.*\.\./([a-z-]+)/src.*'' v;
      in
      if m1 != null then
        m1
      else if m2 != null then
        m2
      else
        [ ]
    ) values;
  refsOfSettings =
    s:
    concatMap (
      d:
      let
        m = builtins.match "sparkles:([a-z-]+)" d.name;
      in
      if m == null then [ ] else m
    ) (s.dependencies or [ ])
    ++ pathRefsIn (concatMap (e: e.values or [ ]) ((s.importPaths or [ ]) ++ (s.sourcePaths or [ ])));
  wasmRefsOf =
    recipe:
    refsOfSettings recipe
    ++ concatMap refsOfSettings (takeWhile (c: c.name != "unittest") (recipe.configurations or [ ]));
  takeWhile =
    p: l:
    if l == [ ] || !p (builtins.head l) then
      [ ]
    else
      [ (builtins.head l) ] ++ takeWhile p (builtins.tail l);

  compare =
    dir:
    let
      f = root + "/${dir}/dub.sdl";
      regex = sort (unique (refsOf (readManifest dir)));
      typed =
        if builtins.pathExists f then sort (unique (wasmRefsOf (parse (builtins.readFile f)))) else [ ];
    in
    {
      inherit dir;
      onlyRegex = minus regex typed;
      onlyWasm = minus typed regex;
    };
  results = map compare regexSubPackages;
in
{
  subPackagesAgree = regexSubPackages == wasmSubPackages;
  recipes = builtins.length results;
  differing = builtins.filter (r: r.onlyRegex != [ ] || r.onlyWasm != [ ]) results;
}
