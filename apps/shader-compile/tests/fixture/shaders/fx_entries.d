/// The fixture's device-only module: one minimal, valid entry point.
@compute(CompileFor.deviceOnly)
module fx_entries;

import sparkles.shaders;

@fragment vec4 tint(@input vec2 uv, Sampler2D texture0, @uniform float amount)
    => texture0.sample(uv) * amount;
