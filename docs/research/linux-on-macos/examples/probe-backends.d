#!/usr/bin/env dub
/+ dub.sdl:
    name "probe_linux_host_backends"
    dependency "sparkles:core-cli" path="../../../.."
+/
/**
Print which Linux-on-macOS backends this process can see.

Backs `docs/research/linux-on-macos/` — a machine without Apple
`container` or Determinate Nix should still *run*, with SKIP lines,
so CI on Linux is green.

See: docs/research/linux-on-macos/sparkles-baseline.md
*/
module probe_backends;

import std.process : execute, environment;
import std.stdio : writeln;
import std.string : strip;

int main()
{
    version (OSX)
    {
        probe("determinate-nixd", ["determinate-nixd", "version"]);
        probe("container", ["container", "--version"]);
        probe("container-apiserver", ["container", "system", "status"]);
        probe("nix-extra-platforms", ["nix", "config", "show", "extra-platforms"]);
        probe("nix-external-builders", ["nix", "config", "show", "external-builders"]);
        return 0;
    }
    else
    {
        writeln("SKIP: Linux-on-macOS backends are a Darwin host concern");
        return 0;
    }
}

void probe(string name, string[] cmd)
{
    const r = execute(cmd);
    writeln("== ", name, " (exit ", r.status, ")");
    writeln(r.output.strip);
}
