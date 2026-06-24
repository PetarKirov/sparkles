module sparkles.text_conformance.layer3_kitty;

import sparkles.text_conformance.config : Config;
import sparkles.text_conformance.report : LayerResult;

LayerResult runLayer3(in Config cfg)
{
    LayerResult r;
    r.name = "3: kitty wcswidth";
    r.skipped = true;
    r.skipReason = "not implemented yet";
    return r;
}
