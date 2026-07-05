/**
The jsoniopipe engine — D's streaming outlier: a pull tokenizer over an
iopipe chain with an optional zero-copy DOM. Benchmarked here through that
DOM (`iopipe.json.dom.parseJSON` over an in-memory chain).
*/
module sparkles.wired_bench.engines.jsoniopipe_json;

version (BenchJsoniopipe):

import iopipe.json.dom : JSONType, JSONValue, parseJSON;
import iopipe.json.parser : JSONToken, jsonTokenizer;
import iopipe.json.serialize : serialize;

import sparkles.wired_bench.fingerprint : Fingerprint;

/// The DOM node type produced by parsing a `const(char)[]` chain.
private alias JV = JSONValue!(const(char)[]);

/// Adapter over jsoniopipe's DOM front-end.
struct JsoniopipeEngine
{
    enum name = "jsoniopipe";
    enum notes = "DOM over the pull tokenizer; strings sliced zero-copy";

    private JV doc;
    private string rendered;

    /// Full DOM parse over an in-memory iopipe chain.
    void parse(const(char)[] text)
    {
        doc = parseJSON(text);
    }

    /// Drops the held document.
    void freeDoc()
    {
        doc = JV.init;
        rendered = null;
    }

    /// Tokenizer drain — the streaming parser's natural strength: every
    /// token is scanned and checked, no value is materialized.
    void validate(const(char)[] text)
    {
        import std.exception : enforce;

        auto tokenizer = text.jsonTokenizer;
        for (auto item = tokenizer.next; item.token != JSONToken.EOF;
            item = tokenizer.next)
            enforce(item.token != JSONToken.Error, "invalid JSON token");
    }

    /// The held document as minified JSON.
    const(char)[] serialize()
    {
        rendered = .serialize(doc);
        return rendered;
    }

    /// Structural fingerprint of the held document.
    Fingerprint fingerprint()
    {
        Fingerprint f;
        accumulateJiop(doc, f);
        return f;
    }
}

/// Accumulates one jsoniopipe DOM subtree into `f`.
private void accumulateJiop(in JV v, ref Fingerprint f)
{
    final switch (v.type)
    {
        case JSONType.Null:
            f.nulls++;
            break;
        case JSONType.Bool:
            if (v.boolean)
                f.trues++;
            else
                f.falses++;
            break;
        case JSONType.Integer:
            f.numbers++;
            f.numberSum += v.integer;
            break;
        case JSONType.Floating:
            f.numbers++;
            f.numberSum += v.floating;
            break;
        case JSONType.String:
            f.strings++;
            f.stringBytes += v.str.length;
            break;
        case JSONType.Array:
            f.arrays++;
            f.arrayElems += v.array.length;
            foreach (const ref e; v.array)
                accumulateJiop(e, f);
            break;
        case JSONType.Obj:
            f.objects++;
            f.objectMembers += v.object.length;
            foreach (key, const ref e; v.object)
            {
                f.keyBytes += key.length;
                accumulateJiop(e, f);
            }
            break;
    }
}

@("JsoniopipeEngine.parseSerializeRoundTrip")
unittest
{
    JsoniopipeEngine e;
    e.parse(`{"a": [1, true, "x", 2.5, null]}`);

    const f = e.fingerprint();
    assert(f.numbers == 2 && f.trues == 1 && f.strings == 1 && f.nulls == 1);
    assert(f.arrays == 1 && f.arrayElems == 5);
    assert(f.objects == 1 && f.objectMembers == 1 && f.keyBytes == 1);
    assert(f.numberSum == 3.5);

    assert(e.serialize == `{"a" : [1, true, "x", 2.5, null]}`
        || e.serialize == `{"a":[1,true,"x",2.5,null]}`);
    e.freeDoc();
}
