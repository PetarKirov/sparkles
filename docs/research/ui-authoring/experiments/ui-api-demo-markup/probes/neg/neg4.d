module neg4; import app; import ui_sketch;
@emits!ExplorerMsg void f(ref Ui ui, in IdsView ids, in Stats s, int local) @safe pure nothrow @nogc
{
    mixin(markup!q{ mapMsg((ToggleHash t) => StatsMsg(t)) { label(text: "x"); } });
}
