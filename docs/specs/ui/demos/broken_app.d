#!/usr/bin/env dub
/+ dub.sdl:
    name "broken_app"
    dependency "sparkles:ui-app" path="../../../.."
    subConfiguration "sparkles:ui-app" "tui"
    dflags "-preview=in" "-preview=dip1000"
+/
// A component with a mistake inside its generic `view`, checked with
// `enforceAppFor`.
//
// The build is SUPPOSED to fail. What the demo shows is how: the compiler's
// own error — "undefined identifier `titel`" at the line with the typo —
// followed by the instantiation trace back to the `static assert`. The typo is
// in a TEMPLATE on purpose: that is the case a gagged check hides, because
// nothing analyses a template's body until it is instantiated, and
// `__traits(compiles, …)` swallows what that instantiation finds. With `isAppFor` in its
// place, the same mistake reported only "BrokenApp is not an application" and
// the typo had to be found by deleting the guard.
import sparkles.input : Event;
import sparkles.ui.widget : Builder, Widget, WidgetKind, WidgetTree;
import sparkles.ui_app.record : RecordingHost;
import sparkles.ui_app.run_app : enforceAppFor;

struct BrokenApp
{
    string title = "hello";

    WidgetTree view(H)(ref H h)
    {
        auto b = Builder();
        // The mistake: a misspelt field.
        return b.finish(b.add(Widget(kind: WidgetKind.text, text: titel)));
    }

    void handle(H)(ref H h, in Event e) {}
}

static assert(enforceAppFor!(BrokenApp, RecordingHost),
    "BrokenApp is not an application");

void main() {}
