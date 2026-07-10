/++
The span-capable table: pure model resolution in
`sparkles.core_cli.ui.table.grid`, rendering in
`sparkles.core_cli.ui.table.render`, re-exported here under the historical
module name. Nothing else lives in this file — the test runner does not
discover unittests in `package.d` modules.
+/
module sparkles.core_cli.ui.table;

public import sparkles.core_cli.ui.table.grid;
public import sparkles.core_cli.ui.table.render;
