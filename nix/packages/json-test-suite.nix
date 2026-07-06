# The JSONTestSuite conformance corpus (nst/JSONTestSuite — "Parsing JSON
# is a Minefield") for the wired native JSON reader: test_parsing/ holds
# y_* files every RFC 8259 parser must accept, n_* files it must reject,
# and i_* files where either verdict is fine but crashing is not. Pinned
# by rev + hash; the devshell exposes the checkout as $JSON_TEST_SUITE and
# wired's conformance tests skip (with a log line) when it is unset.
{ ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      packages.json-test-suite = pkgs.fetchFromGitHub {
        owner = "nst";
        repo = "JSONTestSuite";
        rev = "1ef36fa01286573e846ac449e8683f8833c5b26a";
        hash = "sha256-s2yMgVWq2DwibAjOvLKhGDbEwXm4yke/g4mp7u565H4=";
      };
    };
}
