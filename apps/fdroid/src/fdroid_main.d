/**
Entry point for `fdroid-publish`.

Kept to `main` alone so `sparkles.fdroid.app` stays an ordinary module the
unittest build compiles — the same split `apps/ci` uses. A `mainSourceFile`
excluded from the test configuration would otherwise take every test in it
along.
*/
module fdroid_main;

import sparkles.fdroid.app : FdroidPublish;
import sparkles.core_cli.args : runCli;

int main(string[] args) => runCli!FdroidPublish(args);
