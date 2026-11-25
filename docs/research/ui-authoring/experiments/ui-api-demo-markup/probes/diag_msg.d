module diag_msg;
import app;
import ui_sketch;

@emits!StatsMsg
void pane(ref Ui ui, in Stats s, in IdsView ids) @safe pure nothrow @nogc
{
    mixin(markup!q{
        column(gap: 1) {
            toggle(on: s.hashOnEdit, label: "quit",
                onPress: ui.on(ExplorerMsg(Quit())));
        }
    });
}
