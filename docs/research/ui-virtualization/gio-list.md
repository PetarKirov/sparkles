# Gio — `layout.List` (Go)

Immediate mode with a **builder callback**: the list is given a length and a
function from index to dimensions, and calls it only for the children it needs.
The one subject in the catalog that openly _estimates_ its scroll extent.

|                         |                                                                                                               |
| ----------------------- | ------------------------------------------------------------------------------------------------------------- |
| **Language**            | Go                                                                                                            |
| **License**             | MIT / Unlicense                                                                                               |
| **Repository**          | [gioui/gio][gio] (the GitHub mirror of [~eliasnaur/gio](https://gioui.org/)) (pinned at [`c035a61`][gio-pin]) |
| **Documentation**       | [gioui.org][gio-docs]                                                                                         |
| **Category**            | Immediate mode, GPU                                                                                           |
| **Rendering model**     | Rebuild every frame into an op list; scroll position retained by the caller                                   |
| **Virtualization unit** | Child index, with a sub-item pixel offset                                                                     |

## Overview

### What it solves

Gio's `List` is both the scroller and the virtualizer — there is no separate
"scroll area" that happens to have a clipping optimization. Its `Layout` takes
the child count and a builder, and the type of that builder is the whole design:

```go
// ListElement is a function that computes the dimensions of
// a list element.
type ListElement func(gtx Context, index int) Dimensions
```

— [`layout/list.go`][gio-listelement]

### Design philosophy

The scroll position is a public, serializable value, and the documentation is
explicit that owning it is the caller's job:

> `Position` is updated during `Layout`. To save the list scroll position,
> just save `Position` after `Layout` finishes. To scroll the list
> programmatically, update `Position` (e.g. restore it from a saved value)
> before calling `Layout`.
>
> — [`layout/list.go`][gio-list-struct]

That is the immediate-mode contract applied to scrolling: the framework holds no
authoritative state the application cannot see, and "restore the scroll" is
assignment rather than an API call.

## How it works

`Position` is not a pixel offset — it is an **anchor**: which child is first, and
how far into it the viewport starts.

```go
type Position struct {
    BeforeEnd bool
    // First is the index of the first visible child.
    First int
    // Offset is the distance in pixels from the leading edge to the child at index First.
    Offset int
    // OffsetLast is the signed distance in pixels from the trailing edge to the
    // bottom edge of the child at index First+Count.
    OffsetLast int
    // Count is the number of visible children.
    Count int
    // Length is the estimated total size of all children, measured in pixels.
    Length int
```

— [`layout/list.go`][gio-position]

An index-plus-offset anchor is what makes variable-height children tractable: the
list never needs to know where child `N` starts in absolute pixels, only how to
walk outward from the anchor. `Layout` is that walk:

```go
func (l *List) Layout(gtx Context, len int, w ListElement) Dimensions {
	l.init(gtx, len)
	crossMin, crossMax := l.Axis.crossConstraint(gtx.Constraints)
	gtx.Constraints = l.Axis.constraints(0, inf, crossMin, crossMax)
	macro := op.Record(gtx.Ops)
	laidOutTotalLength := 0
	numLaidOut := 0

	for l.next(); l.more(); l.next() {
		child := op.Record(gtx.Ops)
		dims := w(gtx, l.index())
		call := child.Stop()
		l.end(dims, call)
		laidOutTotalLength += l.Axis.Convert(dims.Size).X
		numLaidOut++
	}

	if numLaidOut > 0 {
		l.Position.Length = laidOutTotalLength*len/numLaidOut + l.Gap*(len-1)
	} else {
		l.Position.Length = 0
	}
	return l.layout(gtx.Ops, macro)
}
```

— [`layout/list.go`][gio-layout]

The loop `for l.next(); l.more(); l.next()` is the walk; the children are laid
out with an unbounded main-axis constraint (`l.Axis.constraints(0, inf, …)`) so
each reports its natural size, and `l.more()` stops once the viewport (plus the
list's own slack) is covered.

### The estimated extent

The two lines after the loop are the notable ones:

```go
l.Position.Length = laidOutTotalLength*len/numLaidOut + l.Gap*(len-1)
```

The total scrollable length is the **mean measured child size × the child
count**, plus the gaps. Gio does not know how big the list is, and by design
never will — measuring `N` children to find out is the cost virtualization
exists to avoid. So the scrollbar is proportioned against an estimate that
refines itself as the user scrolls through regions with different content sizes.

This is the honest cost of supporting variable heights without an index:
[egui](./egui-show-rows.md) gets an exact extent because it assumes uniform
rows; Gio gets arbitrary rows and pays with a thumb that can shift slightly
under a scroll.

The scroll bounds are similarly derived from the _edges_ rather than from an
absolute extent — `update` only clamps when the anchor is already at index 0 or
at the last child ([`layout/list.go`][gio-update]), so the list cannot be
dragged past either end even though it never knew the middle's size.

## Analysis

### 1. What the window bounds

Build, layout, paint, and — through the builder — the caller's data access. Like
[Dear ImGui](./dear-imgui-clipper.md) and [egui](./egui-show-rows.md), there is
no model protocol; the closure is the protocol.

### 2. How the range is computed

A **walk** from the `Position.First` anchor, in both directions, measuring each
child as it goes. No division, no prefix sums, no assumption of uniformity.

### 3. What survives between frames

`Position` (the anchor) and nothing else — no child views, no measured sizes.
Because the anchor is an index, not a pixel offset, it stays meaningful even
when the content above it changes size.

### 4. How the extent is known

**Estimated** from the mean of the measured children. Refined every frame.

### 5. What breaks

- **Scrollbar stability.** The thumb size and position derive from an estimate,
  so a list whose children vary a lot in size has a thumb that adjusts as you
  travel. This is the standard, accepted trade of anchor-based virtualization.
- **Jump-to-index in pixels.** Cheap by _index_ (set `Position.First`),
  impossible in absolute pixels without measuring.
- **Anything wanting a stable absolute coordinate** — an overlay pinned to
  "50% down the content", for instance.

## Strengths

- Variable child sizes are free; nothing in the design assumes uniformity.
- The anchor is index-based, so content changes above the viewport do not
  displace the reader.
- Scroll position is plain data the caller owns, saves and restores by
  assignment.
- One type (`ListElement`) is the entire virtualization contract.

## Weaknesses

- The scroll extent is an estimate, and visibly so with heterogeneous content.
- Every visible child is measured every frame — no memo of sizes, so a costly
  child is costly per frame.
- No random access by pixel offset.

## Key design decisions and trade-offs

| Decision                                       | Rationale                                                                        | Trade-off                                               |
| ---------------------------------------------- | -------------------------------------------------------------------------------- | ------------------------------------------------------- |
| Anchor = `(First, Offset)`, not a pixel scroll | Variable sizes work; content growth above the viewport does not shift the reader | No absolute coordinate space; pixel seek is unavailable |
| Builder callback `(gtx, index) -> Dimensions`  | The caller's data cost is bounded by construction                                | Gio can never help with data caching                    |
| Estimate `Length` from the mean measured child | Avoids the `O(N)` measurement virtualization exists to prevent                   | Scrollbar geometry drifts as the estimate refines       |
| `Position` is public and caller-owned          | Save/restore is assignment; no hidden state                                      | The caller can put the list in an inconsistent state    |

## Sources

- [`layout/list.go`, `List` and `Position`][gio-list-struct]
- [`layout/list.go`, `ListElement`][gio-listelement]
- [`layout/list.go`, `List.Layout`][gio-layout]
- [Gio documentation][gio-docs]

<!-- References -->

[gio]: https://github.com/gioui/gio
[gio-pin]: https://github.com/gioui/gio/tree/c035a6190b0bcb4c8f90e5830d7410307f7c58e8
[gio-list-struct]: https://github.com/gioui/gio/blob/c035a6190b0bcb4c8f90e5830d7410307f7c58e8/layout/list.go#L23
[gio-listelement]: https://github.com/gioui/gio/blob/c035a6190b0bcb4c8f90e5830d7410307f7c58e8/layout/list.go#L55
[gio-position]: https://github.com/gioui/gio/blob/c035a6190b0bcb4c8f90e5830d7410307f7c58e8/layout/list.go#L63
[gio-layout]: https://github.com/gioui/gio/blob/c035a6190b0bcb4c8f90e5830d7410307f7c58e8/layout/list.go#L117
[gio-update]: https://github.com/gioui/gio/blob/c035a6190b0bcb4c8f90e5830d7410307f7c58e8/layout/list.go#L151
[gio-docs]: https://gioui.org/
