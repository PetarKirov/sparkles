module neg7; import app; import ui_sketch;
@emits!ExplorerMsg void f(ref Ui ui, in IdsView ids, in Stats s, int local) @safe pure nothrow @nogc
{
    mixin(markup!q{ mapMsg((StatsMsg sm) => ExplorerMsg(sm)) { numberField(onChange: ui.on!((int v) => StatsMsg(SetDebounce(v + local)))); } });
}
