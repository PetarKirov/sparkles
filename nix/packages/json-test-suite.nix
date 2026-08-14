# The JSONTestSuite conformance corpus (nst/JSONTestSuite — "Parsing JSON
# is a Minefield") for the wired native JSON reader: test_parsing/ holds
# y_* files every RFC 8259 parser must accept, n_* files it must reject,
# and i_* files where either verdict is fine but crashing is not. Pinned
# by flake inputs (see flake.lock); the devshell exposes the checkout as
# $JSON_TEST_SUITE and wired's conformance tests skip (with a log line) when
# it is unset. The older nativejson-benchmark JSON_checker and roundtrip
# fixtures are pinned beside it as a second, independent robustness corpus.
{ inputs, ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      # Flake inputs are store paths; wrap them so `packages.*` stay
      # derivations (`nix build .#json-test-suite`, the devshell env).
      asPkg =
        name: src:
        pkgs.applyPatches {
          inherit name src;
        };
    in
    {
      packages.json-test-suite = asPkg "json-test-suite" inputs.json-test-suite;
      packages.nativejson-test-suite = asPkg "nativejson-test-suite" inputs.nativejson-benchmark;
    };
}
