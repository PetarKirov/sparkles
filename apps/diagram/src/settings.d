/**
The settings pane's subject (`SET4`): everything the board lets a reader
change, as one plain value.

$(B There is no schema here.) The grid half $(I is)
$(REF GridConfig, sparkles,ui,components,grid_backdrop) — the component's own
type, carrying the component's own $(MREF sparkles,ui,property_tree) metadata —
so a field added to the backdrop becomes a row in the pane with nothing to
update on this side. That is the whole reason the pane is a
$(REF PropertyTree, sparkles,ui,property_tree) and not a hand-written form; a
form would be the second declaration `GRD1` exists to avoid.

The board half is the preferences that are $(I also) runtime toggles, so an
experiment made with `m` and a value set in the pane are one setting rather
than two that drift.
*/
module settings;

import sparkles.ui.components.grid_backdrop : GridConfig, gridPreset,
    GridPreset;
import sparkles.ui.property_tree : Doc, Label;

/// How many named fixtures `1`–`3` cycle through (`SET4`).
enum size_t gridPresetCount = __traits(allMembers, GridPreset).length;

/// Board preferences that are also runtime toggles (`IXN4`).
struct BoardSettings
{
    @Label("Minimap") @Doc("Show the content minimap in the corner (`m`).")
    bool minimap = true;
}

/// The pane's subject. `.init` is the board's shipped configuration.
struct DiagramSettings
{
    @Label("Grid") @Doc("The backdrop lattice and stripe bands (`GRD`).")
    GridConfig grid;

    @Label("Board") @Doc("Board preferences the toolbar and keys also reach.")
    BoardSettings board;
}

/**
Applies a named fixture (`SET4`).

$(B This is a structural write, and the caller must treat it as one.) Replacing
the whole grid is exactly the collection/variant-shaped edit
$(MREF sparkles,ui,property_tree) deliberately does not model in v1 (`PRT22`),
so it cannot go through the generated dispatch and cannot produce an inverse.
The pane therefore clears its history around a preset rather than leaving
entries whose `before` value no longer exists anywhere — which `PRT18`'s
precondition would refuse on, silently and confusingly, at the next undo.
*/
void applyPreset(ref DiagramSettings s, GridPreset p) @safe pure nothrow @nogc
{
    s.grid = gridPreset(p);
}

@("diagram.settings.presetsAreReachableAndDistinct")
@safe pure nothrow @nogc
unittest
{
    import sparkles.ui.components.grid_backdrop : MarkKind;

    DiagramSettings s;
    applyPreset(s, GridPreset.dotPaper);
    assert(s.grid.minorStyle.markKind == MarkKind.dots);

    applyPreset(s, GridPreset.defaultLines);
    assert(s.grid == DiagramSettings.init.grid,
        "the default fixture is the shipped configuration");

    // The board half survives a preset: a fixture is a GRID fixture.
    s.board.minimap = false;
    applyPreset(s, GridPreset.stripeBands);
    assert(!s.board.minimap);
}

@("diagram.settings.everyPresetIsCounted")
@safe pure nothrow @nogc
unittest
{
    // The keys `1`–`3` are a ranged binding over this count; a fourth fixture
    // must widen the range rather than become unreachable.
    assert(gridPresetCount == GridPreset.max + 1);
}
