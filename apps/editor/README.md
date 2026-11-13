# Sparkles Editor

A code-editor showcase built on the shared UI editor and command palette.
The initial shell supports independent tabs, multi-cursor editing and undo,
the Lantern key guide, fuzzy commands, clipboard and composition events, and
an optional inspector. Highlighting runs on a revision-aware event-horizon
worker; selections and preedit retain their editor decorations. The theme
picker previews live, restores on Escape and accepts on Enter. Editable code,
Unicode and protected-text examples need no filesystem access.
The language picker discovers installed highlighting grammars in the background
and offers a per-tab override, including Plain text, without changing file bytes.
Native UTF-8 file operands load on a background worker and retain independent
tabs. Invalid operands produce CLI errors before the rendering host starts.
Native saves acknowledge their captured revision and offer informed replacement
and Save/Discard/Cancel decisions. Linux session recovery checkpoints dirty
drafts in the background and offers explicit restoration after restart.
Settings, Android document access, complete recovery acceptance and
layout-aware Unicode navigation remain tracked in the
[delivery plan](../../docs/specs/editor/PLAN.md).

```bash
dub run :editor -- --gui
dub run :editor -- --tui
dub run :editor -- --gui --commands --shot /tmp/editor.png
dub run :editor -- --gui --example code
dub run :editor -- --gui --themes
dub run :editor -- --gui --languages
dub run :editor -- --gui path/to/file.d
dub run :editor -- --gui --state-dir /tmp/editor-session-demo
dub run :editor -- --gui --no-session
dub test :editor
```

Press Ctrl+N for a new tab, Ctrl+Tab or Ctrl+Shift+Tab to switch tabs,
Ctrl+Shift+P for commands, F1 for the key guide, and F12 for diagnostics.
F4 then T opens themes; F4 then D toggles light/dark presentation.
F4 then L opens languages. Enter accepts the override; Escape leaves it unchanged.
The command palette also lists editing operations and their effective keys.
Ctrl+O opens a file, Ctrl+S saves and Ctrl+Shift+S chooses a destination.
Ctrl+W closes a native tab; the TUI uses Ctrl+Shift+W to preserve kill-word.
Ctrl+Q requests exit. Dirty documents offer Save, Discard or Cancel.
Terminal Ctrl+C uses the same close policy; input loss attempts a final
recovery checkpoint and reports failure when an interactive decision is impossible.

Recovery archives default to `$XDG_STATE_HOME/sparkles/editor`, falling back
to `$HOME/.local/state/sparkles/editor`. `--state-dir` selects a registry and
`--no-session` disables it. Screenshot runs skip recovery unless an explicit
state directory is supplied. Recovery revisions distinguish the latest
observed state from the durable checkpoint; failures remain visible and
orderly exit waits or offers a failure decision. Actual device latency and
Android lifecycle acceptance remain open in the delivery plan.

A previous session appears as a touch control and as Restore previous session
in the command palette and F4 R guide path. Restore merges into current tabs;
a duplicate open path becomes an unsaved recovered copy. Original records
remain intact, and an old offer is retired only after its accepted state is
durable in the new archive. Cancel keeps the offer available.

The default build contains Vulkan and TUI hosts. `-c no-gui` builds the
terminal host alone. `--help`, `--version`, `--log-level` and shared host/font
options come from `core-cli` and `ui-app`; the Nix package stamps build info.

The Linux storage fault checks use real syscall injection. Build the checked
probe, then run the driver with `strace` available:

```bash
dub run --single apps/editor/tools/storage-fault-probe.d -b checked --compiler=ldc2 -- baseline
dub run --single apps/editor/tools/storage-faults.d -b checked --compiler=ldc2
```

The X11 probe uses a private Xvfb server and temporary state registry. It
types a draft, kills only its own editor process, restores the draft in a
new process, continues editing, and exercises native dirty-close decisions:

```bash
dub run --single apps/editor/tools/native-close-probe.d -b checked --compiler=ldc2
dub run --single apps/editor/tools/native-close-probe.d -b checked --compiler=ldc2 -- --clipboard
dub run --single apps/editor/tools/tui-close-probe.d -b checked --compiler=ldc2
```

The `--clipboard` scenario holds two native X11 reads and completes them in
reverse order, checking that each tab receives its own text.
