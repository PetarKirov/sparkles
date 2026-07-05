/**
The engine registry.

Each foreign or compatibility-risky engine sits behind its own `version`
gate (set from `dub.sdl` configurations), so a broken engine is one line
away from off while the rest of the harness keeps building.
*/
module sparkles.wired_bench.engines;

import std.meta : AliasSeq;

public import sparkles.wired_bench.engines.std_json : StdJsonEngine;

/// Every engine compiled into this build, baseline first.
alias AllEngines = AliasSeq!(StdJsonEngine);
