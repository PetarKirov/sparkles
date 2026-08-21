/**
The `@ShowIf` evaluation sandbox (`PRT10`).

A condition like `"kind == FillKind.gradient"` must resolve its names exactly
as they read $(B at the field) — in the subject's module. A mixin evaluated
inside `sparkles.ui.property_tree` cannot do that: a function-local import
ranks $(I below) the enclosing module's own declarations, so any name the
property-tree module also declares (its UDA vocabulary, its test fixtures)
would silently win over the subject's.

This module deliberately declares almost nothing, so the locally imported
subject module is the only meaningful scope the condition can resolve in.
Treat it as internal to `sparkles.ui.property_tree`.
*/
module sparkles.ui.property_tree_showif;

/// Evaluates `cond` as a typed predicate over `v`, with `v`'s module
/// imported locally so the condition's names resolve as written at the
/// field. A bad member or type name is a build error, never a callback.
bool showIfHolds(string mod, string cond, U)(ref const U v)
{
    mixin("import ", mod, ";");
    return mixin("v." ~ cond);
}
