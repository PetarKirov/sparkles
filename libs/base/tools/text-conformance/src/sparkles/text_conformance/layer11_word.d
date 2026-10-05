module sparkles.text_conformance.layer11_word;

import sparkles.text_conformance.config : Config;
import sparkles.text_conformance.report : LayerResult;
import sparkles.text_conformance.boundary_corpus : runWordSentenceCorpus;

LayerResult runLayer11(in Config cfg)
{
    return runWordSentenceCorpus!false(cfg);
}
