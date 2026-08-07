/**
`sparkles:terminal-view` — the terminal core as an embeddable component.

Extracted from `apps/terminal` so any application can embed a terminal pane
([spec](../../../../../docs/specs/ui-app/terminal-view.md), `TVW`). The first
slice carries the support modules — the key/mouse → pty encoding seam with its
byte oracle, the OSC color-query scanner, and the POSIX pty/process helpers;
the screen, the per-cell renderer and the `runApp` component follow.

Re-exports only — tests live in the feature modules (the runner does not
discover `package.d`).
*/
module sparkles.terminal_view;

public import sparkles.terminal_view.input;
public import sparkles.terminal_view.osc_query;
public import sparkles.terminal_view.posix_util;
