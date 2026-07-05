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

// Traverses containers without decoding scalars: the unread values are
// skipped by the iterator machinery — the cost profile of a lazy parser
// over untouched fields.
void skip_ondemand(ondemand::value v, uint64_t &containers)
{
    switch (v.type()) {
    case ondemand::json_type::array:
        containers++;
        for (ondemand::value e : v.get_array())
            skip_ondemand(e, containers);
        break;
    case ondemand::json_type::object:
        containers++;
        for (ondemand::field kv : v.get_object())
            skip_ondemand(kv.value(), containers);
        break;
    default:
        break; // scalars stay raw
    }
}

} // namespace

namespace {

// The partial Twitter mirror (canonical definition: the D-side twitter.d).
struct tw_user {
    int64_t id;
    std::string screen_name;
    int64_t followers_count;
};

struct tw_status {
    std::string created_at;
    int64_t id;
    std::string text;
    tw_user user;
    int64_t retweet_count;
    int64_t favorite_count;
};

} // namespace

struct jb_sj_od_ctx {
    ondemand::parser parser;
    std::vector<char> padded; // reused input copy with SIMDJSON_PADDING slack
    std::vector<tw_status> statuses;
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

int jb_sj_od_validate(jb_sj_od_ctx *ctx, const char *data, size_t len)
{
    try {
        if (ctx->padded.size() < len + SIMDJSON_PADDING)
            ctx->padded.resize(len + SIMDJSON_PADDING);
        std::memcpy(ctx->padded.data(), data, len);

        auto doc = ctx->parser.iterate(
            padded_string_view(ctx->padded.data(), len, ctx->padded.size()));
        uint64_t containers = 0;
        skip_ondemand(doc.get_value(), containers);
        return 0;
    } catch (const std::exception &e) {
        ctx->error = e.what();
        return 1;
    } catch (...) {
        ctx->error = "unexpected exception in jb_sj_od_validate";
        return 1;
    }
}

int jb_sj_od_decode(jb_sj_od_ctx *ctx, const char *data, size_t len)
{
    try {
        if (ctx->padded.size() < len + SIMDJSON_PADDING)
            ctx->padded.resize(len + SIMDJSON_PADDING);
        std::memcpy(ctx->padded.data(), data, len);

        auto doc = ctx->parser.iterate(
            padded_string_view(ctx->padded.data(), len, ctx->padded.size()));

        ctx->statuses.clear();
        for (ondemand::object st : doc["statuses"].get_array()) {
            tw_status s;
            s.created_at = std::string_view(st["created_at"]);
            s.id = int64_t(st["id"]);
            s.text = std::string_view(st["text"]);
            ondemand::object u = st["user"];
            s.user.id = int64_t(u["id"]);
            s.user.screen_name = std::string_view(u["screen_name"]);
            s.user.followers_count = int64_t(u["followers_count"]);
            s.retweet_count = int64_t(st["retweet_count"]);
            s.favorite_count = int64_t(st["favorite_count"]);
            ctx->statuses.push_back(std::move(s));
        }
        return 0;
    } catch (const std::exception &e) {
        ctx->error = e.what();
        return 1;
    } catch (...) {
        ctx->error = "unexpected exception in jb_sj_od_decode";
        return 1;
    }
}

int jb_sj_od_twitter_stats(jb_sj_od_ctx *ctx, jb_twitter_stats *out)
{
    std::memset(out, 0, sizeof(*out));
    out->status_count = ctx->statuses.size();
    for (const tw_status &s : ctx->statuses) {
        out->id_sum += uint64_t(s.id);
        out->user_id_sum += uint64_t(s.user.id);
        out->followers_sum += uint64_t(s.user.followers_count);
        out->retweet_sum += uint64_t(s.retweet_count);
        out->favorite_sum += uint64_t(s.favorite_count);
        out->text_bytes += s.text.size();
        out->screen_name_bytes += s.user.screen_name.size();
        out->created_at_bytes += s.created_at.size();
    }
    return 0;
}

const char *jb_sj_od_error(const jb_sj_od_ctx *ctx)
{
    return ctx->error.c_str();
}

} // extern "C"
