module neg9; import app; import ui_sketch;
@emits!ExplorerMsg void f(ref Ui ui, in IdsView ids, in Stats s, int local) @safe pure nothrow @nogc
{
    mixin(markup!q{ auto g = { label(text: "x"); }; mapMsg((StatsMsg sm) => ExplorerMsg(sm)) { card(title: "t", body: g); } });
}
