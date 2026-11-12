/**
The entry point: parse the command line and run its subcommand (`FXC1`).

Everything with behaviour lives in the other modules, inside the test build:
the command line itself is `cli.d`.
*/
module app;

import sparkles.core_cli.args : runCli;

import cli : Explorer;

int main(string[] args) => runCli!Explorer(args);
