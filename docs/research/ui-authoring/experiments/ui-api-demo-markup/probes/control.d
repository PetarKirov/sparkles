module control;
import app; import ui_sketch; import markup : markupSource;
@emits!ExplorerMsg
void ctl(ref Ui ui, in IdsView ids, in Stats s) @safe pure nothrow @nogc
{
    auto dg = { mixin(markup!q{
        foreach (r; ids.rows; key: r.name) { label(text: r.name); }
        mapMsg((StatsMsg sm) => ExplorerMsg(sm)) { statsPane(s: s, ids: ids); }
    }); };
}
pragma(msg, markupSource!q{
        foreach (r; ids.rows; key: r.name) { label(text: r.name); }
        mapMsg((StatsMsg sm) => ExplorerMsg(sm)) { statsPane(s: s, ids: ids); }
    });
