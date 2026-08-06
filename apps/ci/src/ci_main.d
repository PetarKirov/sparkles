/**
 * The executable entry point, and nothing else.
 *
 * `app.d` holds the tool's logic — and, being the package's `mainSourceFile`,
 * was excluded from every test build: `dub test :ci` announced
 * `Warning Excluding main source file src/app.d from test`, so none of its
 * `@("ci.*")` unittests had ever run. dub excludes that file because it defines
 * `main`, so the fix is to define `main` somewhere else: this file is the
 * `mainSourceFile` now, `app.d` is an ordinary module, and its tests run.
 */
module ci_main;

import app : ciMain;

int main(string[] args) => ciMain(args);
