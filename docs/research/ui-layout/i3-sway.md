# i3 and Sway (tiling window managers)

A pair of tree-based tiling window managers — i3 for X11 and Sway for Wayland — that
model the entire screen as a single hierarchical tree of split containers, where
each leaf is a window and each internal node has a split direction. They are
included in this UI-layout catalog because their tree-of-splits model is _the_
production-proven solution to the same problem TUI authors face: dividing a fixed
rectangle into nested resizable panes.

| Field          | i3                                     | Sway                                      |
| -------------- | -------------------------------------- | ----------------------------------------- |
| Author         | Michael Stapelberg                     | Drew DeVault                              |
| Started        | 2009                                   | 2015                                      |
| Language       | C                                      | C                                         |
| Display server | X11                                    | Wayland                                   |
| License        | BSD-3-Clause                           | MIT                                       |
| Repository     | <https://github.com/i3/i3>             | <https://github.com/swaywm/sway>          |
| Documentation  | <https://i3wm.org/docs/userguide.html> | <https://man.archlinux.org/man/sway.5.en> |
| Config syntax  | Declarative; same dialect as Sway      | Drop-in compatible with i3 config syntax  |
| IPC tool       | `i3-msg`                               | `swaymsg`                                 |

---

## Overview

**i3** is a tiling window manager built around an explicit, user-visible tree of
container nodes. Michael Stapelberg started it in 2009 in reaction to what he saw
as design flaws in earlier tiling WMs like wmii, xmonad, and dwm: those projects
hard-coded a single layout algorithm (dynamic master/stack, manual, or
flat tagged), which made certain arrangements awkward or impossible. i3's
contribution was to _expose_ the tiling tree as a first-class data structure that
the user manipulates directly — splitting a node, moving a leaf, swapping siblings,
or marking a node by name — rather than choosing from a fixed menu of layouts.

**Sway** is a Wayland compositor that reimplements i3's behaviour from scratch on
top of `wlroots` (the reference Wayland library co-developed by Drew DeVault and
others). Drew DeVault started Sway in 2015 with an explicit compatibility goal:
existing i3 config files should work unchanged. The bet paid off — Sway is today
the dominant Wayland tiling compositor and the _de facto_ migration path for i3
users moving off X11.

**Why discuss tiling WMs in a UI-layout catalog?** Because the tree-of-splits is
exactly the data structure a TUI library like [Ratatui](../tui-libraries/ratatui.md)
or [Textual](../tui-libraries/textual.md) builds to subdivide its terminal area
into resizable panes. Tiling WMs are the same idea operating one level higher: the
"terminal" is the monitor, the "widgets" are application windows, and the layout
is constructed _by direct user manipulation_ over a session of hours or days
rather than by a programmer in source code. The interaction patterns (split
horizontally, split vertically, change parent's orientation, resize within
siblings) translate one-for-one to programmatic TUI layout APIs.

**Comparison to other tiling WMs.** Several other tiling window managers exist,
each with a different layout abstraction:

| Project       | Layout model                                              |
| ------------- | --------------------------------------------------------- |
| **dwm**       | Master area + stack; one window is "master", rest stack.  |
| **xmonad**    | Layout algorithms as first-class typeclass; user picks.   |
| **bspwm**     | Binary tree similar to i3; layout via `bspc` IPC.         |
| **awesome**   | Lua-scripted layouts; multiple algorithms per tag.        |
| **i3 / Sway** | User-manipulated explicit tree; tabbed and stacked nodes. |
| **Hyprland**  | Dynamic tiling on Wayland; similar to Sway with effects.  |
| **river**     | Dynamic tiling on Wayland; layouts as external processes. |

The defining feature of i3/Sway compared to bspwm (which also uses a binary tree)
is that **internal nodes are themselves containers with their own layout mode** —
not just split directions. An internal node can be `splith`, `splitv`, `tabbed`,
or `stacking`, which transforms the visual representation of its children without
changing the tree structure.

---

## Layout Model

### The tree

The entire screen state is one tree, rooted at the display server (X11 root or
Wayland output set). The i3 user guide describes the levels:

> The root node is the X11 root window, followed by the X11 outputs, then dock
> areas and a content container, then workspaces and finally the windows
> themselves.

Simplified, the hierarchy is:

```
Root
├── Output 0  (monitor)
│   ├── Workspace 1
│   │   └── (root container of WS 1; layout = splith, splitv, tabbed, or stacking)
│   │       ├── Container (leaf: window)
│   │       └── Container (internal: another split)
│   │           ├── Window
│   │           └── Window
│   └── Workspace 2
│       └── ...
├── Output 1
│   └── Workspace 3
└── Output 2
    └── ...
```

Two invariants govern this tree:

1. **Each output displays exactly one workspace at a time.** Other workspaces
   on the same output exist but are not painted. Switching workspaces is O(1) —
   the compositor flips which subtree it renders.

2. **Every leaf is a window; every internal node is a container with a layout.**
   There is no separate notion of "window" and "non-window"; a leaf-window can be
   converted into an internal node by splitting it, and an internal node with a
   single child collapses.

### Container types and layout modes

A container's _layout mode_ dictates how its children are arranged visually:

| Layout     | Visual representation                                                           |
| ---------- | ------------------------------------------------------------------------------- |
| `splith`   | Children laid out left-to-right, each taking a share of horizontal space.       |
| `splitv`   | Children laid out top-to-bottom, each taking a share of vertical space.         |
| `tabbed`   | All children stacked in z-order; one tab bar at the top selects which is shown. |
| `stacking` | All children stacked in z-order; tab list along the top, each on its own line.  |

`tabbed` and `stacking` are the genius move of the i3 design: they let the _same_
tree expose a _different_ visual idiom. A `tabbed` internal node looks like a tab
container in a GUI; a `splitv` internal node containing two `tabbed` children
looks like a side-by-side pair of tab strips. The user reshapes the layout by
changing layout modes on internal nodes, without ever restructuring the tree.

The sway(5) man page describes the rule for `stacking`:

> When using the stacking layout, only the focused window in the container is
> displayed, with the opened windows' list on the top of the container.

The `tabbed` variant differs only in _how_ the title list is rendered (one
horizontal strip vs. one entry per row).

### Window-insertion rule

When the user opens a new application window, where in the tree does it land?
The rule is deceptively simple and is the core of how i3 feels:

**A new window opens as a sibling of the focused container.**

That is: if the focused container's parent has layout `splith`, the new window
joins the row to the right of the focus. If the parent is `splitv`, it stacks
below. If the parent is `tabbed` or `stacking`, the new window becomes a new tab.

When the user explicitly wants a _split_ (a nested orientation change), they run
`split horizontal` or `split vertical` on the focused window first. This wraps the
focused window in a new internal node with the chosen orientation, so the next
window opens as a sibling within that nested node.

In effect, the workflow is:

```text
+----------------+        +----------------+        +----------------+
|                |        |                |   ->   |        | new   |
|     focus      |  ->    |     focus      |        | focus  | win   |
|                |        |                |        |        |       |
+----------------+        +----------------+        +----------------+
   (splitv parent)         (after `split h`,         (next new window
                            focus is now in a         lands here)
                            splith child)
```

This is the same pattern a TUI layout API expresses with:

```rust
// Pseudocode: ratatui-style nested split
let [top, bottom] = Layout::vertical([..]).areas(area);
let [left, right] = Layout::horizontal([..]).areas(top);
```

— with the difference that i3 builds the tree _interactively_ via a long sequence
of keybindings, and persists it across the WM's runtime.

### Commands and keybindings

The i3/Sway command vocabulary is small but composable. Selected commands from
the user guide and sway(5):

```text
# Layout-mode changes on the focused container.
layout splith
layout splitv
layout tabbed
layout stacking
layout toggle split           # cycle splith <-> splitv
layout toggle all             # cycle through all four layouts

# Splits — wrap the focused window in a new internal node.
split horizontal
split vertical
split toggle                  # flip parent's orientation

# Focus.
focus left | right | up | down
focus parent | child
focus next | prev
focus output left | right | <name>

# Move containers within the tree.
move left | right | up | down [<px> px]
move container to workspace <name>
move container to output left | right | <name>
move workspace to output <direction|name>

# Mark and reference.
mark --add MyMark
[con_mark="MyMark"] focus
unmark MyMark
swap container with mark MyMark

# Resize.
resize grow   width  10 px or 10 ppt
resize shrink height 10 px or 10 ppt
resize set width 600 px

# Floating.
floating enable
floating disable
floating toggle
```

The `or` keyword in resize commands is the canonical example of how i3 thinks
about sizes: try the `px` size first; if that hits a tree-level constraint (the
target container can't actually shrink/grow by that many pixels), fall back to
the `ppt` (percentage-points) size, which always succeeds because it operates on
proportional weights between siblings.

### Resize as proportions

Resizing inside a `splith` or `splitv` parent does _not_ mean "this window is 600
px wide". It means "this window's share of its parent's space is 0.45 vs. its
sibling's 0.55". When the parent itself shrinks (because the user resized the
parent, or the monitor changed resolution, or a sibling was added), the children
re-divide the new space proportionally.

This is structurally identical to Ratatui's `Constraint::Ratio(num, denom)` (or
Flexbox's `flex-grow`): the unit of layout is a fraction of an ancestor, not an
absolute pixel count. The resize command `resize grow width 10 ppt` adjusts the
proportion by 0.1, leaving the parent's total share alone.

### Floating: escape the tree

A floating window is one that is _not_ a leaf in the tiling tree of its workspace.
Instead, it lives in a per-workspace "floating layer" with an absolute position
and size, painted on top of the tiled area. The tree still tracks it (so it can
be marked, focused, moved), but layout commands like `resize grow width 10 ppt`
are interpreted as absolute pixel resizes when applied to a floating window.

Floating exists because some applications — file dialogs, password prompts,
ephemeral popovers — are conceptually modal and ill-served by tiling. Sway and i3
auto-detect many of these via window-type hints (`_NET_WM_WINDOW_TYPE_DIALOG`),
and `for_window` rules let the user opt others in.

### Workspaces and outputs

Each workspace owns its own tree. The compositor maintains an `outputs` array
(monitors), and at any moment each output is showing exactly one workspace.
Switching workspaces means re-pointing one output's "currently-shown" pointer at
a different workspace subtree. Moving a workspace to another output (`move
workspace to output right`) reassigns the parent edge in the global tree.

Workspaces are named or numbered:

```text
bindsym $mod+1 workspace 1: mail
bindsym $mod+2 workspace 2: www
bindsym $mod+3 workspace 3: code

# Move the focused window to workspace 2.
bindsym $mod+Shift+2 move container to workspace 2: www
```

This is a _very_ lightweight abstraction: a workspace is just a node in the tree
plus a name. There is no per-workspace "layout policy" or "tag" mechanism — the
tree's structure _is_ the layout.

### Example config — full layout

A minimal but complete i3 / Sway config that demonstrates the layout primitives:

```text
# ~/.config/sway/config   (or ~/.config/i3/config — same syntax)

# Modifier key (Super / "Windows" key).
set $mod Mod4

# Terminal.
bindsym $mod+Return exec foot

# Kill focused window.
bindsym $mod+Shift+q kill

# --- Split orientation ----------------------------------------------
# Wrap focused window in a new horizontal split (next new window opens to
# the right of focus, inside a fresh splith parent).
bindsym $mod+h split h
# Wrap focused window in a new vertical split.
bindsym $mod+v split v

# --- Layout mode ----------------------------------------------------
# Change the focused container's layout.
bindsym $mod+s   layout stacking
bindsym $mod+w   layout tabbed
bindsym $mod+e   layout toggle split

# --- Focus movement (vim-style) -------------------------------------
bindsym $mod+j focus left
bindsym $mod+k focus down
bindsym $mod+l focus up
bindsym $mod+semicolon focus right
bindsym $mod+a focus parent
bindsym $mod+d focus child

# --- Container movement ---------------------------------------------
bindsym $mod+Shift+j move left
bindsym $mod+Shift+k move down
bindsym $mod+Shift+l move up
bindsym $mod+Shift+semicolon move right

# --- Workspaces -----------------------------------------------------
bindsym $mod+1 workspace 1
bindsym $mod+2 workspace 2
bindsym $mod+3 workspace 3
bindsym $mod+Shift+1 move container to workspace 1
bindsym $mod+Shift+2 move container to workspace 2
bindsym $mod+Shift+3 move container to workspace 3

# --- Resize mode ----------------------------------------------------
# Enter a sub-mode where jkl; resize, Escape exits.
mode "resize" {
    bindsym j resize grow   width  10 ppt or 10 px
    bindsym k resize grow   height 10 ppt or 10 px
    bindsym l resize shrink height 10 ppt or 10 px
    bindsym semicolon resize shrink width 10 ppt or 10 px

    bindsym Escape mode "default"
    bindsym Return mode "default"
}
bindsym $mod+r mode "resize"

# --- Floating -------------------------------------------------------
bindsym $mod+Shift+space floating toggle
floating_modifier $mod

# --- Multi-monitor outputs ------------------------------------------
# (sway-only — i3 reads xrandr instead.)
output HDMI-A-1 resolution 2560x1440 position 0,0
output DP-1      resolution 1920x1080 position 2560,360

# Pin workspace 1 to the primary monitor, 2 to the secondary.
workspace 1 output HDMI-A-1
workspace 2 output DP-1
```

This is the _entire_ layout policy for a usable system: no algorithms to pick, no
layout objects to instantiate, no z-order arithmetic. The user constructs the
layout interactively, and the config exists only to bind a vocabulary of
mutations to keys.

### Marks, scratchpad, and criteria

Two further mechanisms enrich the basic tree model:

**Marks** are user-assigned string labels on containers, modelled directly on
Vim's mark feature. A mark is attached with `mark --add MyMark` on the focused
container; subsequent commands can target it via the criteria syntax
`[con_mark="MyMark"]`. Marks are workspace-spanning — a command like:

```text
bindsym $mod+grave [con_mark="terminal"] focus
```

teleports focus to the marked terminal regardless of which workspace it lives on.
The `swap container with mark MyMark` command exchanges the focused container
with the marked one _in-place_, preserving each one's tree position. This is
remarkably useful when juggling layouts: mark a window, build a new layout
elsewhere, then swap the two with a single key.

**Scratchpad** is a special hidden workspace that holds windows on standby. A
container moved to the scratchpad (`move scratchpad`) disappears from view; the
keybinding `scratchpad show` toggles a floating-window display of one scratchpad
container at a time. This is the i3/Sway equivalent of "minimise to tray" — used
for chat clients, music players, and other always-running auxiliaries the user
wants to summon quickly.

**Criteria** are filter expressions that prefix a command, restricting it to
matching windows. The syntax is square-bracketed `[key=value, key=value]`:

```text
# Make all Firefox dialog windows float by default.
for_window [class="Firefox" window_type="dialog"] floating enable

# Move all VS Code windows to workspace 3.
for_window [class="Code"] move container to workspace 3

# Border style per application.
for_window [class="foot"] border pixel 1
for_window [app_id="firefox"] border none
```

Available criteria keys include `class`, `app_id` (Wayland), `instance`, `title`,
`window_role`, `window_type`, `con_mark`, `con_id`, `urgent`, and `tiling` /
`floating`. The criteria language is small but compositional, and it lets users
encode layout policies declaratively without scripting.

### Reading the tree at runtime

Both i3 and Sway expose the current tree over a JSON IPC. `i3-msg -t get_tree`
(or `swaymsg -t get_tree`) dumps the entire hierarchy. A truncated example:

```json
{
  "type": "root",
  "nodes": [
    {
      "type": "output",
      "name": "HDMI-A-1",
      "nodes": [
        {
          "type": "workspace",
          "name": "1",
          "layout": "splith",
          "nodes": [
            {
              "type": "con",
              "layout": "splitv",
              "nodes": [
                { "type": "con", "window_properties": { "class": "foot" } },
                { "type": "con", "window_properties": { "class": "Firefox" } }
              ]
            },
            { "type": "con", "window_properties": { "class": "code" } }
          ]
        }
      ]
    }
  ]
}
```

This makes the tree _introspectable_ — you can write external tools that walk it,
script layouts, or build status bars that display the layout structure. The
sparkles equivalent for a TUI layout would be a serialisable layout-node type.

### Comparison to a Ratatui split layout

The same two-column-with-nested-rows layout, expressed in three idioms:

**i3/Sway (interactively):**

```text
$mod+v          # wrap focus in vertical split
$mod+Return     # spawn a terminal (lands below focus)
$mod+h          # wrap focus in horizontal split
$mod+Return     # spawn another terminal (lands to the right)
```

**Ratatui (programmatically):**

```rust
let [left, right] = Layout::horizontal([
    Constraint::Percentage(60),
    Constraint::Fill(1),
]).areas(area);

let [top_right, bottom_right] = Layout::vertical([
    Constraint::Ratio(1, 2),
    Constraint::Ratio(1, 2),
]).areas(right);
```

**Textual (declaratively):**

```python
with Horizontal():
    yield SidebarPanel()
    with Vertical():
        yield DetailPanel()
        yield LogPanel()
```

All three produce the same logical structure: a tree of split nodes whose leaves
are content regions. The difference is _who builds the tree_: a user with a
keyboard (i3/Sway), a programmer at compile time (Ratatui), or a framework via a
component graph (Textual).

---

## Strengths and Weaknesses

### Strengths

- **Predictable and inspectable.** The tree _is_ the layout. There is no hidden
  algorithm to reverse-engineer when something looks wrong. `swaymsg -t get_tree`
  shows exactly what the compositor will paint.

- **Fast.** Layout is a tree walk, O(n) in the number of nodes. There is no
  constraint solver, no flexbox-style two-pass measure/arrange. Resizing
  propagates by adjusting sibling weights at one level.

- **Composable layout modes.** `splith`, `splitv`, `tabbed`, and `stacking` cover
  almost every practical arrangement. Tabbed+stacked nested inside split
  containers yields layouts that retained-mode toolkits implement as separate
  widget classes (TabView, SplitView, AccordionView), here all unified into one
  primitive.

- **Sway's drop-in compatibility with i3.** A single config file works on both,
  which is rare and valuable when a community migrates display protocols.

- **Scripting via IPC.** `i3-msg` / `swaymsg` accept any command the keybinding
  system accepts. External tools can apply layouts, query state, react to events
  (workspace changes, window focus changes) over a Unix socket subscription
  channel.

- **No layout configuration burden.** Unlike dwm or xmonad, the user does not
  pick a layout algorithm; they construct the layout they want by direct
  manipulation. The cognitive model is small.

### Weaknesses

- **Unfamiliar mental model for new users.** Most computer users have learned
  the _floating_ window paradigm (overlapping, draggable rectangles). Tree-of-
  splits requires unlearning that and thinking about the focused-window's parent
  layout when opening a new window. Documentation helps, but the learning curve
  is real.

- **No persistent layout templates.** Once you close all windows in a workspace,
  the tree is empty. Re-creating the exact same layout next session requires
  external tools (`i3-save-tree` / `i3-resurrect`) and is not a first-class
  concept. (Contrast: tmux sessions can be saved and restored verbatim via
  `tmuxinator`-style configs.)

- **Floating windows are a second-class citizen.** They escape the tree, which
  is _correct_ for modal dialogs but awkward when an application's intended UX is
  many small floating panels (image editors, 3D modelling tools).

- **Multi-monitor layout is workspace-coarse.** Outputs always show entire
  workspaces; there is no concept of "this workspace's tree spans both monitors".
  Users who want one logical screen split across two physical monitors have to
  pretend each is a separate workspace.

- **No animation, by design.** Transitions are instantaneous. i3 considers this
  a feature; Hyprland (a newer Sway-compatible compositor) has made the opposite
  bet with animations as a headline feature. Personal preference.

- **Wayland-specific Sway quirks.** Sway inherits Wayland's restrictions: no
  global hotkeys for external apps, no screen-capture APIs in older versions, no
  arbitrary window positioning by applications. These are Wayland constraints,
  not Sway bugs, but they affect ports of X11 software.

### Lessons for `sparkles` and TUI layout design

- **Split-pane TUI layouts map directly onto the i3 tree model.** A `drawTable`
  primitive is admittedly a stretch — tables are 2-D arrays of cells, not
  hierarchical splits — but a _layout container_ for sparkles would benefit from
  exposing `splith`, `splitv`, `tabbed`, and `stacking` as first-class layout
  modes, with the same composition rules. Both [Ratatui](../tui-libraries/ratatui.md)
  and [Textual](../tui-libraries/textual.md) build similar split-pane layouts
  inside a single terminal; i3's model is the design they converge on.

- **Make the tree introspectable.** i3/Sway's IPC tree dump (`get_tree`) is
  invaluable for debugging. A D layout library that can serialise its current
  tree as JSON or pretty-printed text — using the existing
  `sparkles.core_cli.prettyprint` machinery — would make layout bugs orders of
  magnitude easier to diagnose.

- **Proportional sizing is the right default.** i3's `ppt` resize is the same
  abstraction as Ratatui's `Constraint::Ratio` and Flexbox's `flex-grow`. Pixel
  sizes are useful for chrome (status bar height, separator thickness), but the
  main content area almost always wants to be expressed as a fraction of
  available space.

- **The "wrap in a new split" operation is a useful API primitive.** Most TUI
  libraries make you specify the entire layout structure upfront, but the
  operation "take this region and split it into two" is sometimes more natural,
  particularly for dynamic UIs like log-viewer-with-detail-pane that should
  appear on demand.

- **Tabbed/stacking inside splith/splitv is a force multiplier.** This single
  feature would let a sparkles TUI layout collapse what would otherwise be three
  separate widget types (Split, TabView, Accordion) into one.

---

## References

### i3

- **User guide:** <https://i3wm.org/docs/userguide.html>
- **Project site:** <https://i3wm.org/>
- **IPC documentation:** <https://i3wm.org/docs/ipc.html>
- **Repository:** <https://github.com/i3/i3>
- **History:** <https://i3wm.org/downloads/> (release archive going back to 2009)

### Sway

- **Project site:** <https://swaywm.org/>
- **Repository:** <https://github.com/swaywm/sway>
- **`sway(5)` config man page:** <https://man.archlinux.org/man/sway.5.en>
- **`sway(1)` invocation man page:** <https://man.archlinux.org/man/sway.1.en>
- **`wlroots`:** <https://gitlab.freedesktop.org/wlroots/wlroots> — the Wayland
  compositor library Sway is built on.

### Related projects

- **bspwm:** <https://github.com/baskerville/bspwm> — another binary-tree tiling
  WM, with all state mutation via the `bspc` IPC tool.
- **Hyprland:** <https://hyprland.org/> — Wayland compositor with i3-style tiling
  and modern animations.
- **river:** <https://codeberg.org/river/river> — Wayland tiling with dynamic
  layouts implemented as external "layout generator" processes.
- **dwm:** <https://dwm.suckless.org/> — minimal master/stack X11 tiler.
- **xmonad:** <https://xmonad.org/> — Haskell-scripted tiling with first-class
  layout algorithms.

### Catalog cross-links

- [Ratatui](../tui-libraries/ratatui.md) — TUI library whose `Layout` with nested
  `horizontal` / `vertical` splits matches the i3 tree exactly, statically.
- [Textual](../tui-libraries/textual.md) — TUI framework whose `Horizontal` /
  `Vertical` containers and CSS grid build the same tree declaratively.
- [Brick](../tui-libraries/brick.md) — Haskell TUI library; `hBox` / `vBox`
  combinators are the functional analogue of i3 splits.
- [FTXUI](../tui-libraries/ftxui.md) — C++ TUI with `hbox` / `vbox` /
  `dbox` / `gridbox` decorators; another point on the same design axis.
- [tree-view case study](../tui-libraries/tree-view-case-study.md) — relevant
  background on rendering tree structures in a constrained 2-D area.
