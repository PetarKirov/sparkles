/**
JSON backend for `sparkles:wired` — public surface.

Re-exports the codec (`Json` marker, `toJSON` / `fromJSON`,
`readJSONFile` / `writeJSONFile`) and the native-engine modules
(SPEC §11) as they land.
*/
module sparkles.wired.json;

public import sparkles.wired.json.codec;
public import sparkles.wired.json.document;
