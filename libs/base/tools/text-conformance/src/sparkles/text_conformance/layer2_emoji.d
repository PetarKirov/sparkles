module sparkles.text_conformance.layer2_emoji;

import sparkles.text_conformance.config : Config;
import sparkles.text_conformance.report : LayerResult;

LayerResult runLayer2(in Config cfg)
{
    LayerResult r;
    r.name = "2: emoji clusters";
    r.skipped = true;
    r.skipReason = "not implemented yet";
    return r;
}
