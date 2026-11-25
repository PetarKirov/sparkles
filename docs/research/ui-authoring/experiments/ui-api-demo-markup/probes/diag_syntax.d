module diag_syntax;
import app;
import ui_sketch;

@emits!StatsMsg
void pane(ref Ui ui, in Stats s, in IdsView ids) @safe pure nothrow @nogc
{
    mixin(markup!q{
        column(gap: 1) {
            label(slot: Slot.heading, text: "Stats")
            toggle(on: s.hashOnEdit);
        }
    });
}
