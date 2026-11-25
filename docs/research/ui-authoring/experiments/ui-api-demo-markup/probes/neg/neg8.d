module neg8; import app; import ui_sketch;
@emits!ExplorerMsg void f(ref Ui ui, in IdsView ids, in Stats s, int local) @safe pure nothrow @nogc
{
    mixin(markup!q{ auto f = { toggle(onPress: ui.on(ExplorerMsg(Quit()))); }; mapMsg((StatsMsg sm) => ExplorerMsg(sm)) { embed(f); } });
}
