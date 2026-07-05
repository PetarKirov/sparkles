// simdjson engines for the wired runtime JSON bench: the classic DOM
// front-end (tape) and the lazy On-Demand front-end (parse + full walk).
// Every entry point catches everything — no exception unwinds into D.

#include "wired_bench_shim.h"

#include <simdjson.h>

#include <cstring>
#include <string>
#include <vector>

using namespace simdjson;

namespace {

// Accumulates one DOM subtree into the fingerprint.
void accumulate_dom(const dom::element &v, jb_fingerprint &f)
{
    switch (v.type()) {
    case dom::element_type::NULL_VALUE:
        f.nulls++;
        break;
    case dom::element_type::BOOL:
        if (bool(v))
            f.trues++;
        else
            f.falses++;
        break;
    case dom::element_type::INT64:
        f.numbers++;
        f.number_sum += double(int64_t(v));
        break;
    case dom::element_type::UINT64:
        f.numbers++;
        f.number_sum += double(uint64_t(v));
        break;
    case dom::element_type::DOUBLE:
        f.numbers++;
        f.number_sum += double(v);
        break;
    case dom::element_type::STRING: {
        f.strings++;
        f.string_bytes += std::string_view(v).size();
        break;
    }
    case dom::element_type::ARRAY: {
        f.arrays++;
        dom::array arr(v);
        f.array_elems += arr.size();
        for (dom::element e : arr)
            accumulate_dom(e, f);
        break;
    }
    case dom::element_type::OBJECT: {
        f.objects++;
        dom::object obj(v);
        f.object_members += obj.size();
        for (dom::key_value_pair kv : obj) {
            f.key_bytes += kv.key.size();
            accumulate_dom(kv.value, f);
        }
        break;
    }
    }
}

} // namespace

struct jb_sj_dom_ctx {
    dom::parser parser;
    dom::element root;
    bool has_doc = false;
    std::string rendered;
    std::string error;
};

extern "C" {

jb_sj_dom_ctx *jb_sj_dom_new(void)
{
    try {
        return new jb_sj_dom_ctx();
    } catch (...) {
        return nullptr;
    }
}

void jb_sj_dom_free(jb_sj_dom_ctx *ctx)
{
    delete ctx;
}

int jb_sj_dom_parse(jb_sj_dom_ctx *ctx, const char *data, size_t len)
{
    try {
        // parse() copies into the parser's padded internal buffer (the
        // immutable-input contract: the copy is part of the timed op).
        auto result = ctx->parser.parse(data, len, /*realloc_if_needed=*/true);
        if (result.error() != SUCCESS) {
            ctx->error = error_message(result.error());
            ctx->has_doc = false;
            return 1;
        }
        ctx->root = result.value_unsafe();
        ctx->has_doc = true;
        return 0;
    } catch (...) {
        ctx->error = "unexpected exception in jb_sj_dom_parse";
        ctx->has_doc = false;
        return 1;
    }
}

void jb_sj_dom_doc_free(jb_sj_dom_ctx *ctx)
{
    // The document lives in the parser's reused tape; nothing to free.
    ctx->has_doc = false;
}

int jb_sj_dom_fingerprint(jb_sj_dom_ctx *ctx, jb_fingerprint *out)
{
    try {
        if (!ctx->has_doc) {
            ctx->error = "fingerprint: no document";
            return 1;
        }
        std::memset(out, 0, sizeof(*out));
        accumulate_dom(ctx->root, *out);
        return 0;
    } catch (const std::exception &e) {
        ctx->error = e.what();
        return 1;
    } catch (...) {
        ctx->error = "unexpected exception in jb_sj_dom_fingerprint";
        return 1;
    }
}

const char *jb_sj_dom_serialize(jb_sj_dom_ctx *ctx, size_t *len)
{
    try {
        if (!ctx->has_doc) {
            ctx->error = "serialize: no document";
            return nullptr;
        }
        ctx->rendered = simdjson::minify(ctx->root);
        *len = ctx->rendered.size();
        return ctx->rendered.data();
    } catch (const std::exception &e) {
        ctx->error = e.what();
        return nullptr;
    } catch (...) {
        ctx->error = "unexpected exception in jb_sj_dom_serialize";
        return nullptr;
    }
}

const char *jb_sj_dom_error(const jb_sj_dom_ctx *ctx)
{
    return ctx->error.c_str();
}

} // extern "C"

// ---- On-Demand ------------------------------------------------------------

namespace {

// Walks (and thereby materializes) one On-Demand subtree.
void walk_ondemand(ondemand::value v, jb_fingerprint &f)
{
    switch (v.type()) {
    case ondemand::json_type::null:
        if (!v.is_null())
            throw simdjson_error(INCORRECT_TYPE);
        f.nulls++;
        break;
    case ondemand::json_type::boolean:
        if (bool(v.get_bool()))
            f.trues++;
        else
            f.falses++;
        break;
    case ondemand::json_type::number:
        f.numbers++;
        f.number_sum += double(v.get_double());
        break;
    case ondemand::json_type::string: {
        f.strings++;
        f.string_bytes += std::string_view(v.get_string()).size();
        break;
    }
    case ondemand::json_type::array: {
        f.arrays++;
        for (ondemand::value e : v.get_array()) {
            f.array_elems++;
            walk_ondemand(e, f);
        }
        break;
    }
    case ondemand::json_type::object: {
        f.objects++;
        for (ondemand::field kv : v.get_object()) {
            f.object_members++;
            f.key_bytes += std::string_view(kv.unescaped_key()).size();
            walk_ondemand(kv.value(), f);
        }
        break;
    }
    }
}

} // namespace

struct jb_sj_od_ctx {
    ondemand::parser parser;
    std::vector<char> padded; // reused input copy with SIMDJSON_PADDING slack
    std::string error;
};

extern "C" {

jb_sj_od_ctx *jb_sj_od_new(void)
{
    try {
        return new jb_sj_od_ctx();
    } catch (...) {
        return nullptr;
    }
}

void jb_sj_od_free(jb_sj_od_ctx *ctx)
{
    delete ctx;
}

int jb_sj_od_parse_walk(jb_sj_od_ctx *ctx, const char *data, size_t len,
                        jb_fingerprint *out)
{
    try {
        // The copy into the reused padded buffer is part of the timed op
        // (On-Demand requires SIMDJSON_PADDING readable bytes past the end).
        if (ctx->padded.size() < len + SIMDJSON_PADDING)
            ctx->padded.resize(len + SIMDJSON_PADDING);
        std::memcpy(ctx->padded.data(), data, len);

        auto doc = ctx->parser.iterate(
            padded_string_view(ctx->padded.data(), len, ctx->padded.size()));

        std::memset(out, 0, sizeof(*out));
        ondemand::value root = doc.get_value();
        walk_ondemand(root, *out);
        return 0;
    } catch (const simdjson_error &e) {
        ctx->error = e.what();
        return 1;
    } catch (const std::exception &e) {
        ctx->error = e.what();
        return 1;
    } catch (...) {
        ctx->error = "unexpected exception in jb_sj_od_parse_walk";
        return 1;
    }
}

const char *jb_sj_od_error(const jb_sj_od_ctx *ctx)
{
    return ctx->error.c_str();
}

} // extern "C"
