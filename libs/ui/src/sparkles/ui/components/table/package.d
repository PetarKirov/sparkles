/++
The span-capable table: pure model resolution in
`sparkles.ui.components.table.grid`, the content-agnostic layout core
(configuration, width/height solving, junction glyphs, line ordering) in
`sparkles.ui.components.table.layout`, and the string view in
`sparkles.ui.components.table.render`, re-exported here under the historical
module name. Nothing else lives in this file — the test runner does not
discover unittests in `package.d` modules.

The $(B widget) view (`sparkles.ui.components.table.widgets`) is deliberately
$(B not) re-exported: it imports the whole toolkit — canvas, chrome, state,
widget, wrap — where the three modules above reach no further than
`sparkles:base`. Re-exporting it would put that closure on every consumer of
`drawTable`, including the wasm playground, which compiles a hand-listed set
of source directories and fails outright when the closure widens. Import it by
its own module path where the widget view is actually wanted.
+/
module sparkles.ui.components.table;

public import sparkles.ui.components.table.grid;
public import sparkles.ui.components.table.layout;
public import sparkles.ui.components.table.render;
