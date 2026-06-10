# Getting started

## Try it without cloning

Assuming you have [Nix installed](https://nixos.org/download/) with
[flakes enabled](https://nix.dev/concepts/flakes.html), you can run the terminal
directly from GitHub:

```bash
nix run github:PetarKirov/sparkles#terminal
```

or install it into your profile:

```bash
nix profile add github:PetarKirov/sparkles#terminal
terminal --font "Fira Code" --font-size 14
```

Both commands fetch a prebuilt binary from the
[sparkles Cachix cache](https://sparkles.cachix.org) when available, and fall
back to building from source otherwise (the flake's `nixConfig` advertises
the cache; Nix will ask once whether to trust it).

The rest of this page covers building from a checkout.

## Prerequisites

Sparkles Terminal runs on Linux. Building it needs the D toolchain, raylib,
libghostty-vt, and fontconfig — all provided by the repository's Nix dev
shell:

```bash
nix develop   # or let direnv activate it
```

## Build and run

```bash
dub run :terminal
```

This opens a 100×30 window running your login shell (from `$SHELL`), with
`TERM` set to `xterm-256color`.

Arguments after the first `--` go to the terminal instead of dub:

```bash
dub run :terminal -- --font "JetBrainsMono Nerd Font" --font-size 14
dub run :terminal -- --window-width 120 --window-height 40
```

## Choosing a font

`--font` accepts either a file path or a fontconfig name:

```bash
dub run :terminal -- --font /path/to/font.ttf
dub run :terminal -- --font "Fira Code"
```

Names are resolved with `fc-match`. Bold and italic faces of the same family
are picked up automatically; if a face is missing, the style is approximated
(double-strike for bold, a slant offset for italic). Glyphs the chosen font
lacks fall back to a Nerd Font and a common monospace font, when installed.

## Running a command instead of a shell

Everything after a second `--` is a command, run via your shell's `-c` (so
aliases, builtins, and pipes work). The terminal follows its
[exit behavior](./reference/cli.md#exit-behavior) when the command finishes:

```bash
dub run :terminal -- -- htop
dub run :terminal -- --exit-behavior hold -- ls --color -l
dub run :terminal -- -- 'git log --oneline | head -20'
```

By default (`hold-on-failure`) the window closes on a clean exit but stays
open showing the output — plus an exit-status banner — when the command
fails, so errors don't vanish with the window.

## Next steps

- Skim the [key and mouse bindings](./reference/bindings.md) — selection,
  clipboard, scrollback, font zoom, clickable links.
- See the [CLI reference](./reference/cli.md) for all options, including
  routing icon codepoints to a specific font with `--font-codepoint-map`.
