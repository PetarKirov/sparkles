module diag_key;
import app;
import ui_sketch;

@emits!StatsMsg
void pane(ref Ui ui, in Stats s, in IdsView ids) @safe pure nothrow @nogc
{
    mixin(markup!q{
        column(gap: 1) {
            foreach (r; ids.rows) {
                keyValue(name: r.name, value: r.value);
            }
        }
    });
}
