/**
The document's paint loop, shared by every GPU host (`UIA14`): which of the
viewer model's display-list operations a viewport shows, and the hover/drag
animation of the active in-document scrollbar applied to them.

hue's window and the embeddable pane ($(MREF sparkles,doc_view,pane)) both
emit through this, so the two cannot drift on culling or on how a fence's bar
lights up. Backend-free: operations in, operations out.
*/
module sparkles.doc_view.view_ops;

import sparkles.ui.canvas : DrawOp, match, OpKind, RuleEdge, Scrollbar;

import sparkles.doc_view.viewer_model : ViewerModel;

/**
Calls `sink` with each operation of `vm` that is visible with `vm.top` at the
top of a `docRows`-row viewport — clip brackets always, so they balance — in
paint order, the active bar's animation written into its copy. The operations
are in document cells; the caller places them.
*/
void emitVisibleOps(ref ViewerModel vm, long docRows, scope void delegate(ref DrawOp op) sink)
{
    foreach (ref sourceOp; vm.ops)
    {
        const oy = sourceOp.rect.y;
        if (sourceOp.kind != OpKind.pushClip
            && sourceOp.kind != OpKind.popClip
            && (oy + sourceOp.rect.height <= vm.top
                || oy > vm.top + docRows))
            continue;
        auto op = sourceOp;
        const activeSv = vm.activeBar();
        if (activeSv !is null
            && (vm.activeFenceOwner != size_t.max
                || vm.activeTableOwner != size_t.max))
        {
            // The hover/drag animation is applied to the copy, on the one
            // arm that has somewhere to put it.
            op.payload.match!(
                (ref Scrollbar bar)
                {
                    const h = bar.edge == RuleEdge.centerY;
                    const isFence = vm.activeFenceOwner != size_t.max;
                    const want = isFence
                        ? (h ? vm.fenceHBarHitBase : vm.fenceVBarHitBase)
                            + vm.activeFenceOwner
                        : (h ? vm.tableHBarHitBase : vm.tableVBarHitBase)
                            + vm.activeTableOwner;
                    foreach (ref const t; vm.targets)
                    {
                        if (t.hitId != want || t.rect != bar.rect)
                            continue;
                        bar.expandPercent = barPercent(h
                            ? activeSv.hAnim.percent
                            : activeSv.vAnim.percent);
                        bar.trackLit = h
                            ? activeSv.h.hovered || activeSv.h.dragging
                            : activeSv.v.hovered || activeSv.v.dragging;
                        break;
                    }
                },
                (ref _) {},
            );
        }
        sink(op);
    }
}

/// A scrollbar's expansion, as the whole percent a `Scrollbar` carries.
ubyte barPercent(float value) @safe pure nothrow @nogc
    => value <= 0 ? 0 : value >= 100 ? 100 : cast(ubyte) value;

@("view_ops.barPercent.clamps")
@safe pure nothrow @nogc unittest
{
    assert(barPercent(-3) == 0);
    assert(barPercent(42.7) == 42);
    assert(barPercent(250) == 100);
}
