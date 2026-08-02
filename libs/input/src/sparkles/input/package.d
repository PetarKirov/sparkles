/**
`sparkles:input` — the abstract, capability-tiered input vocabulary shared by
every `sparkles:ui` target (`docs/specs/ui/input.md`).

Interaction is the other half of "one definition, three targets": events are
$(B values) in one vocabulary ($(MREF sparkles,input,events)), classified into
capability tiers ($(MREF sparkles,input,tier)), in a package both the toolkit
and the terminal library can depend on (`sparkles:base` only, plus
`sparkles:math` import-only for the position type). Producers adapt their
native input to it — the terminal decodes its wire formats straight into
$(REF Event, sparkles,input,events); a pixel backend synthesizes events from
polled state.
*/
module sparkles.input;

public import sparkles.input.events;
public import sparkles.input.gesture;
public import sparkles.input.tier;
