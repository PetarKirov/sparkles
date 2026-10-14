# A YAML emitter for the GitHub Actions subset, in pure Nix.
#
# `pkgs.formats.yaml` would need a build (remarshal) to produce a file whose
# content is only data, and it sorts every map alphabetically — a workflow
# would read `env:` before `name:` and `run:` before `uses:`. Emitting here
# keeps rendering a pure evaluation (the drift check compares strings, no
# derivation involved) and orders keys the way people write workflows.
#
# Scalars that YAML could misread (`on`, `yes`, numbers, `${{ … }}`, anything
# with `:` or `#`) are written as JSON strings, which are valid YAML
# double-quoted scalars. Multi-line strings become `|` block literals.
{ lib }:
let
  # Keys in the order a reader expects them; the rest follow alphabetically.
  keyOrder = [
    "name"
    "id"
    "on"
    "needs"
    "if"
    "runs-on"
    "timeout-minutes"
    "continue-on-error"
    "permissions"
    "concurrency"
    "environment"
    "strategy"
    "outputs"
    "defaults"
    "uses"
    "with"
    "shell"
    "working-directory"
    "env"
    "run"
    "steps"
    "jobs"
  ];

  orderedKeys =
    attrs:
    let
      names = builtins.attrNames attrs;
    in
    builtins.filter (k: attrs ? ${k}) keyOrder ++ builtins.filter (k: !builtins.elem k keyOrder) names;

  # YAML 1.1 reads these as booleans or null; GitHub's parser is 1.1-ish.
  keywords = [
    "y"
    "n"
    "yes"
    "no"
    "on"
    "off"
    "true"
    "false"
    "null"
    "~"
  ];

  isPlain =
    s:
    builtins.match "[A-Za-z_./][A-Za-z0-9_./+=@-]*( [A-Za-z0-9_./+=@()-]+)*" s != null
    && !builtins.elem (lib.toLower s) keywords;

  scalar =
    v:
    if v == null then
      "null"
    else if builtins.isBool v then
      lib.boolToString v
    else if builtins.isInt v then
      toString v
    else if builtins.isString v then
      (if isPlain v then v else builtins.toJSON v)
    else if builtins.isPath v then
      scalar (toString v)
    else
      throw "yaml: cannot emit a ${builtins.typeOf v} as a scalar";

  isScalar = v: !(builtins.isAttrs v || builtins.isList v);

  # A string that can be a block literal: multi-line, no tabs, no trailing
  # spaces (editorconfig would strip them and change the value), not starting
  # with a space (that would need an indentation indicator), and ending in at
  # most one newline.
  blockLines =
    s:
    let
      body = lib.removeSuffix "\n" s;
      lines = lib.splitString "\n" body;
      ok =
        builtins.isString s
        && lib.hasInfix "\n" body
        && !lib.hasInfix "\t" s
        && !lib.hasSuffix "\n" body
        && !lib.hasPrefix " " body
        && lib.all (l: !lib.hasSuffix " " l) lines;
    in
    if ok then
      {
        header = if lib.hasSuffix "\n" s then "|" else "|-";
        inherit lines;
      }
    else
      null;

  indentLine = ind: l: if l == "" then "" else ind + l;

  emitMap =
    ind: attrs:
    lib.concatMap (
      k:
      let
        v = attrs.${k};
        key = scalar k;
        block = if builtins.isString v then blockLines v else null;
      in
      if block != null then
        [ "${ind}${key}: ${block.header}" ] ++ map (indentLine "${ind}  ") block.lines
      else if isScalar v then
        [ "${ind}${key}: ${scalar v}" ]
      else if v == { } then
        [ "${ind}${key}: {}" ]
      else if v == [ ] then
        [ "${ind}${key}: []" ]
      else
        [ "${ind}${key}:" ] ++ emit "${ind}  " v
    ) (orderedKeys attrs);

  emitList =
    ind:
    lib.concatMap (
      v:
      if isScalar v then
        [ "${ind}- ${scalar v}" ]
      else
        let
          lines = emit "${ind}  " v;
        in
        [ "${ind}- ${lib.removePrefix "${ind}  " (builtins.head lines)}" ] ++ builtins.tail lines
    );

  emit =
    ind: v:
    if builtins.isAttrs v then
      emitMap ind v
    else if builtins.isList v then
      emitList ind v
    else
      [ "${ind}${scalar v}" ];
in
{
  # `toYAML { header = "# …"; } value` → the document, newline-terminated.
  toYAML =
    {
      header ? "",
    }:
    value: header + lib.concatStringsSep "\n" (emit "" value) + "\n";
}
