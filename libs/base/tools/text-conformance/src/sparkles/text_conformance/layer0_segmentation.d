module sparkles.text_conformance.layer0_segmentation;

import sparkles.text_conformance.config : Config;
import sparkles.text_conformance.report : LayerResult;

LayerResult runLayer0(in Config cfg)
{
    LayerResult r;
    r.name = "0: segmentation";
    r.skipped = true;
    r.skipReason = "not implemented yet";
    return r;
}
