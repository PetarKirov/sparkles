/**
JSON backend for `sparkles:wired` — public surface.

Re-exports the codec (`Json` marker, `toJSON` / `fromJSON`,
`readJSONFile` / `writeJSONFile`); the native-engine modules (document,
reader, writer — SPEC §11) re-export here as they land.
*/
module sparkles.wired.json;

public import sparkles.wired.json.codec;
