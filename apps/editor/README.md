# Sparkles Editor

A code-editor showcase built on the shared UI editor and command palette.
The initial shell supports independent tabs, multi-cursor editing and undo,
the Lantern key guide, fuzzy commands, clipboard and composition events, and
an optional inspector. Highlighting runs on a revision-aware event-horizon
worker; selections and preedit retain their editor decorations. The theme
picker previews live, restores on Escape and accepts on Enter. Editable code,
Unicode and protected-text examples need no filesystem access.
Native UTF-8 file operands load on a background worker and retain independent
tabs. Invalid operands produce CLI errors before the rendering host starts.
Save/close workflows, settings, recovery and
layout-aware Unicode navigation are tracked in the
[delivery plan](../../docs/specs/editor/PLAN.md).

```bash
dub run :editor -- --gui
dub run :editor -- --tui
dub run :editor -- --gui --commands --shot /tmp/editor.png
dub run :editor -- --gui --example code
dub run :editor -- --gui --themes
dub run :editor -- --gui path/to/file.d
dub test :editor
```

Press Ctrl+N for a new tab, Ctrl+Tab or Ctrl+Shift+Tab to switch tabs,
Ctrl+Shift+P for commands, F1 for the key guide, and F12 for diagnostics.
Ctrl+K then T opens themes; Ctrl+K then D toggles light/dark presentation.
The command palette also lists editing operations and their effective keys.
The app refuses to close dirty tabs while the save/close workflow is under
construction.

The default build contains Vulkan and TUI hosts. `-c no-gui` builds the
terminal host alone. `--help`, `--version`, `--log-level` and shared host/font
options come from `core-cli` and `ui-app`; the Nix package stamps build info.

The Linux storage fault checks use real syscall injection. Build the checked
probe, then run the driver with `strace` available:

```bash
dub run --single apps/editor/tools/storage-fault-probe.d -b checked --compiler=ldc2 -- baseline
dub run --single apps/editor/tools/storage-faults.d -b checked --compiler=ldc2
```
