module sparkles.text_conformance.layer12_sentence;

import sparkles.text_conformance.config : Config;
import sparkles.text_conformance.report : LayerResult;
import sparkles.text_conformance.boundary_corpus : runWordSentenceCorpus;

LayerResult runLayer12(in Config cfg)
{
    return runWordSentenceCorpus!true(cfg);
}
