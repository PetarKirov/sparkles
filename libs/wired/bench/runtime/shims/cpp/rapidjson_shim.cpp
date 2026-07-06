// rapidjson engine for the wired runtime JSON bench. Numbers always parse
// with kParseFullPrecisionFlag so its values are comparable with the other
// engines (the default parser has a 3-ULP error bound); the SIMD level
// (RAPIDJSON_SSE42 / RAPIDJSON_NEON) is fixed at build time per ISA preset.

#include "wired_bench_shim.h"

#include <rapidjson/document.h>
#include <rapidjson/error/en.h>
#include <rapidjson/memorystream.h>
#include <rapidjson/reader.h>
#include <rapidjson/stringbuffer.h>
#include <rapidjson/writer.h>

#include <cstring>
#include <string>
#include <vector>

namespace {

constexpr unsigned parseFlags =
    rapidjson::kParseFullPrecisionFlag | rapidjson::kParseDefaultFlags;

// Accumulates one DOM subtree into the fingerprint.
void accumulate_rj(const rapidjson::Value &v, jb_fingerprint &f)
{
    if (v.IsNull()) {
        f.nulls++;
    } else if (v.IsBool()) {
        if (v.IsTrue())
            f.trues++;
        else
            f.falses++;
    } else if (v.IsNumber()) {
        f.numbers++;
        f.number_sum += v.GetDouble();
    } else if (v.IsString()) {
        f.strings++;
        f.string_bytes += v.GetStringLength();
    } else if (v.IsArray()) {
        f.arrays++;
        f.array_elems += v.Size();
        for (const auto &e : v.GetArray())
            accumulate_rj(e, f);
    } else if (v.IsObject()) {
        f.objects++;
        f.object_members += v.MemberCount();
        for (const auto &m : v.GetObject()) {
            f.key_bytes += m.name.GetStringLength();
            accumulate_rj(m.value, f);
        }
    }
}

} // namespace

struct jb_rj_ctx {
    rapidjson::Document doc;
    std::vector<char> scratch; // reused insitu buffer
    rapidjson::StringBuffer rendered;
    std::string error;
    bool has_doc = false;

    int fail(const char *what)
    {
        error = what;
        has_doc = false;
        return 1;
    }

    int check_parse()
    {
        if (doc.HasParseError()) {
            error = rapidjson::GetParseError_En(doc.GetParseError());
            has_doc = false;
            return 1;
        }
        has_doc = true;
        return 0;
    }
};

extern "C" {

jb_rj_ctx *jb_rj_new(void)
{
    try {
        return new jb_rj_ctx();
    } catch (...) {
        return nullptr;
    }
}

void jb_rj_free(jb_rj_ctx *ctx)
{
    delete ctx;
}

int jb_rj_parse(jb_rj_ctx *ctx, const char *data, size_t len)
{
    try {
        ctx->doc.SetNull();
        ctx->doc.GetAllocator().Clear();
        ctx->doc.Parse<parseFlags>(data, len);
        return ctx->check_parse();
    } catch (...) {
        return ctx->fail("unexpected exception in jb_rj_parse");
    }
}

int jb_rj_parse_insitu(jb_rj_ctx *ctx, const char *data, size_t len)
{
    try {
        // The scratch copy is part of the timed op; ParseInsitu then decodes
        // strings destructively inside it (needs a NUL terminator).
        if (ctx->scratch.size() < len + 1)
            ctx->scratch.resize(len + 1);
        std::memcpy(ctx->scratch.data(), data, len);
        ctx->scratch[len] = '\0';

        ctx->doc.SetNull();
        ctx->doc.GetAllocator().Clear();
        ctx->doc.ParseInsitu<parseFlags | rapidjson::kParseInsituFlag>(
            ctx->scratch.data());
        return ctx->check_parse();
    } catch (...) {
        return ctx->fail("unexpected exception in jb_rj_parse_insitu");
    }
}

int jb_rj_validate(jb_rj_ctx *ctx, const char *data, size_t len)
{
    try {
        // SAX Reader over a length-bounded stream driving a null handler:
        // full validation (full-precision numbers included), nothing built.
        rapidjson::MemoryStream ms(data, len);
        rapidjson::EncodedInputStream<rapidjson::UTF8<>, rapidjson::MemoryStream>
            is(ms);
        rapidjson::Reader reader;
        rapidjson::BaseReaderHandler<> handler;
        rapidjson::ParseResult ok =
            reader.Parse<parseFlags>(is, handler);
        if (!ok) {
            ctx->error = rapidjson::GetParseError_En(ok.Code());
            return 1;
        }
        return 0;
    } catch (...) {
        return ctx->fail("unexpected exception in jb_rj_validate");
    }
}

void jb_rj_doc_free(jb_rj_ctx *ctx)
{
    ctx->doc.SetNull();
    ctx->doc.GetAllocator().Clear();
    ctx->has_doc = false;
}

int jb_rj_fingerprint(jb_rj_ctx *ctx, jb_fingerprint *out)
{
    try {
        if (!ctx->has_doc)
            return ctx->fail("fingerprint: no document");
        std::memset(out, 0, sizeof(*out));
        accumulate_rj(ctx->doc, *out);
        return 0;
    } catch (...) {
        return ctx->fail("unexpected exception in jb_rj_fingerprint");
    }
}

const char *jb_rj_serialize(jb_rj_ctx *ctx, size_t *len)
{
    try {
        if (!ctx->has_doc) {
            ctx->error = "serialize: no document";
            return nullptr;
        }
        ctx->rendered.Clear();
        rapidjson::Writer<rapidjson::StringBuffer> writer(ctx->rendered);
        ctx->doc.Accept(writer);
        *len = ctx->rendered.GetSize();
        return ctx->rendered.GetString();
    } catch (...) {
        ctx->error = "unexpected exception in jb_rj_serialize";
        return nullptr;
    }
}

const char *jb_rj_error(const jb_rj_ctx *ctx)
{
    return ctx->error.c_str();
}

} // extern "C"
