#!/usr/bin/env dub
/+ dub.sdl:
    name "prompts"
    dependency "sparkles:core-cli" path="../../.."
    targetPath "build"
+/

// ci: build-only

// Line-based interactive prompts (`sparkles.core_cli.prompts`): a numbered
// `select` (default marked, re-prompt on invalid input), a y/N `confirm`, and
// a validated `textInput` — each carrying a `PromptPolicy` so `--auto` runs
// and piped stdin resolve uniformly (take the default / fail) instead of every
// app hand-rolling it. Interactive, so `ci` only builds this; run it yourself.

module prompts_example;

import std.stdio : writefln, writeln;

import sparkles.core_cli.prompts;
import sparkles.core_cli.term_caps : isTerminal, StdStream;
import sparkles.core_cli.ui.theme : makeTheme, Theme;
import sparkles.core_cli.term_caps : detectTermCaps;

void main()
{
    const theme = makeTheme(detectTermCaps());
    // Piped stdin? Resolve every prompt to its default instead of blocking.
    const policy = isTerminal(StdStream.stdin)
        ? PromptPolicy.interactive
        : PromptPolicy.takeDefault;
    auto io = stdioPromptIo();

    auto bump = select("Version bump:", [
        SelectOption("patch", "v0.5.0 → v0.5.1"),
        SelectOption("minor", "v0.5.0 → v0.6.0  (suggested: 4 feat)"),
        SelectOption("major", "v0.5.0 → v1.0.0"),
    ], 1, policy, io, theme);
    if (bump.hasError)
        return writeln(bump.error);
    writefln!"picked option %s"(bump.value + 1);

    auto go = confirm("Push to origin?", defaultYes: true, policy, io, theme);
    if (go.hasError)
        return writeln(go.error);
    writefln!"confirmed: %s"(go.value);

    auto name = textInput("Release codename", "sparkling",
        (string s) => s.length >= 3 ? null : "at least 3 characters, please",
        policy, io);
    if (name.hasError)
        return writeln(name.error);
    writefln!"codename: %s"(name.value);
}
