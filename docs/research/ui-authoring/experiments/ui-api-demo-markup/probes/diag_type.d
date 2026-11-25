module diag_type;
import app;
import ui_sketch;

@emits!StatsMsg
void pane(ref Ui ui, in Stats s, in IdsView ids) @safe pure nothrow @nogc
{
    mixin(markup!q{
        column(gap: 1) {
            label(slot: Slot.heading, text: "Stats");
            numberField(value: s.hashOnEdit ~ 1, unit: "ms",
                onChange: ui.on!((int v) => StatsMsg(SetDebounce(v))));
            foreach (r; ids.rows; key: r.name) {
                keyValue(name: r.nme, value: r.value);
            }
        }
    });
}
