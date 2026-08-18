/++
The span-capable table: pure model resolution in
`sparkles.ui.components.table.grid`, the content-agnostic layout core
(configuration, width/height solving, junction glyphs, line ordering) in
`sparkles.ui.components.table.layout`, and the string view in
`sparkles.ui.components.table.render`, re-exported here under the historical
module name. Nothing else lives in this file — the test runner does not
discover unittests in `package.d` modules.
+/
module sparkles.ui.components.table;

public import sparkles.ui.components.table.grid;
public import sparkles.ui.components.table.layout;
public import sparkles.ui.components.table.render;
