/*
 * C ABI of the foreign-engine shims for the wired runtime JSON bench.
 *
 * One opaque context per engine, created once per engine run (untimed). The
 * context owns every reusable resource: parser state, the most recent
 * document, the most recent serialize buffer, and the last error message —
 * no allocation ever crosses the FFI boundary.
 *
 * Conventions:
 *   - int-returning calls: 0 = success, nonzero = failure; the message is
 *     available via jb_<engine>_error() until the next call on the context.
 *   - jb_<engine>_parse takes caller-owned, immutable, unpadded input; any
 *     copy or padding the engine needs happens inside (the bench times it).
 *   - jb_<engine>_serialize returns a context-owned minified UTF-8 buffer,
 *     valid until the next call on the context.
 *   - No C++ exception and no Rust panic may unwind across this boundary.
 *
 * The header is consumed by D via ImportC: plain C99, no includes beyond
 * <stddef.h>/<stdint.h>.
 */
#ifndef WIRED_BENCH_SHIM_H
#define WIRED_BENCH_SHIM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Mirrors the D-side Fingerprint (fingerprint.d); the adapters copy it
 * field by field, so only the field set — not the layout — must match. */
typedef struct jb_fingerprint {
    uint64_t nulls;
    uint64_t trues;
    uint64_t falses;
    uint64_t numbers;        /* ints + floats merged: engines classify differently */
    uint64_t strings;        /* value-position strings only */
    uint64_t arrays;
    uint64_t objects;
    uint64_t array_elems;
    uint64_t object_members;
    uint64_t string_bytes;   /* decoded (unescaped) bytes of value strings */
    uint64_t key_bytes;      /* decoded bytes of object keys */
    double   number_sum;     /* compared with relative tolerance */
} jb_fingerprint;

/* ---- simdjson, DOM front-end (dom::parser tape, reused across parses) --- */
typedef struct jb_sj_dom_ctx jb_sj_dom_ctx;
jb_sj_dom_ctx *jb_sj_dom_new(void);
void           jb_sj_dom_free(jb_sj_dom_ctx *ctx);
int            jb_sj_dom_parse(jb_sj_dom_ctx *ctx, const char *data, size_t len);
void           jb_sj_dom_doc_free(jb_sj_dom_ctx *ctx);
int            jb_sj_dom_fingerprint(jb_sj_dom_ctx *ctx, jb_fingerprint *out);
const char    *jb_sj_dom_serialize(jb_sj_dom_ctx *ctx, size_t *len);
const char    *jb_sj_dom_error(const jb_sj_dom_ctx *ctx);

/* ---- simdjson, On-Demand front-end -------------------------------------
 * A lazy forward-only cursor: a bare "parse" would only run stage 1, so the
 * timed op is parse + a full-document walk, and the walk *is* the
 * fingerprint computation (strings and numbers are materialized). */
typedef struct jb_sj_od_ctx jb_sj_od_ctx;
jb_sj_od_ctx  *jb_sj_od_new(void);
void           jb_sj_od_free(jb_sj_od_ctx *ctx);
int            jb_sj_od_parse_walk(jb_sj_od_ctx *ctx, const char *data,
    size_t len, jb_fingerprint *out);
const char    *jb_sj_od_error(const jb_sj_od_ctx *ctx);

/* ---- rapidjson (kParseFullPrecisionFlag always, for cross-engine number
 * comparability; SIMD level fixed at build time per ISA preset) ---------- */
typedef struct jb_rj_ctx jb_rj_ctx;
jb_rj_ctx     *jb_rj_new(void);
void           jb_rj_free(jb_rj_ctx *ctx);
int            jb_rj_parse(jb_rj_ctx *ctx, const char *data, size_t len);
/* Copies into a context scratch buffer (timed), then ParseInsitu. */
int            jb_rj_parse_insitu(jb_rj_ctx *ctx, const char *data, size_t len);
void           jb_rj_doc_free(jb_rj_ctx *ctx);
int            jb_rj_fingerprint(jb_rj_ctx *ctx, jb_fingerprint *out);
const char    *jb_rj_serialize(jb_rj_ctx *ctx, size_t *len);
const char    *jb_rj_error(const jb_rj_ctx *ctx);

/* Engine/version provenance for the report header, e.g.
 * "simdjson 4.2.2; rapidjson 1.1.0". Static storage. */
const char *jb_cpp_versions(void);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* WIRED_BENCH_SHIM_H */
