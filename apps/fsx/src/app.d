/**
The entry point: `fsx`, or `fscp`, `fsls` and `fsdiff` by name (`XA1`).

Everything with behaviour lives in the other modules, inside the test build.
*/
module app;

import cli : runFsx;

int main(string[] args) => runFsx(args);
