//! serde_json — the Rust ecosystem's standard JSON engine.

use std::ffi::{c_char, c_int};

use serde_json::Value;

use crate::twitter::{stats_of, JbTwitterStats, Twitter};
use crate::{input_slice, ErrorSlot, JbFingerprint};

pub struct JbSerdeCtx {
    doc: Option<Value>,
    twitter: Option<Twitter>,
    rendered: Vec<u8>,
    error: ErrorSlot,
}

fn accumulate(v: &Value, f: &mut JbFingerprint) {
    match v {
        Value::Null => f.nulls += 1,
        Value::Bool(true) => f.trues += 1,
        Value::Bool(false) => f.falses += 1,
        Value::Number(n) => {
            f.numbers += 1;
            f.number_sum += n.as_f64().unwrap_or(f64::NAN);
        }
        Value::String(s) => {
            f.strings += 1;
            f.string_bytes += s.len() as u64;
        }
        Value::Array(a) => {
            f.arrays += 1;
            f.array_elems += a.len() as u64;
            for e in a {
                accumulate(e, f);
            }
        }
        Value::Object(o) => {
            f.objects += 1;
            f.object_members += o.len() as u64;
            for (k, e) in o {
                f.key_bytes += k.len() as u64;
                accumulate(e, f);
            }
        }
    }
}

#[no_mangle]
pub extern "C" fn jb_serde_new() -> *mut JbSerdeCtx {
    Box::into_raw(Box::new(JbSerdeCtx {
        doc: None,
        twitter: None,
        rendered: Vec::new(),
        error: ErrorSlot::new(),
    }))
}

/// # Safety
/// `ctx` must be a pointer returned by `jb_serde_new`, not yet freed.
#[no_mangle]
pub unsafe extern "C" fn jb_serde_free(ctx: *mut JbSerdeCtx) {
    if !ctx.is_null() {
        drop(Box::from_raw(ctx));
    }
}

/// # Safety
/// `ctx` as above; `data`/`len` must describe a valid buffer.
#[no_mangle]
pub unsafe extern "C" fn jb_serde_parse(
    ctx: *mut JbSerdeCtx,
    data: *const c_char,
    len: usize,
) -> c_int {
    let ctx = &mut *ctx;
    match serde_json::from_slice::<Value>(input_slice(data, len)) {
        Ok(v) => {
            ctx.doc = Some(v);
            0
        }
        Err(e) => {
            ctx.doc = None;
            ctx.error.fail(e)
        }
    }
}

/// Full validation building nothing: `from_slice::<IgnoredAny>`.
///
/// # Safety
/// `ctx` as above; `data`/`len` must describe a valid buffer.
#[no_mangle]
pub unsafe extern "C" fn jb_serde_validate(
    ctx: *mut JbSerdeCtx,
    data: *const c_char,
    len: usize,
) -> c_int {
    let ctx = &mut *ctx;
    match serde_json::from_slice::<serde::de::IgnoredAny>(input_slice(data, len)) {
        Ok(_) => 0,
        Err(e) => ctx.error.fail(e),
    }
}

/// # Safety
/// `ctx` as above.
#[no_mangle]
pub unsafe extern "C" fn jb_serde_doc_free(ctx: *mut JbSerdeCtx) {
    (*ctx).doc = None;
}

/// # Safety
/// `ctx` as above; `out` must point to a writable `jb_fingerprint`.
#[no_mangle]
pub unsafe extern "C" fn jb_serde_fingerprint(
    ctx: *mut JbSerdeCtx,
    out: *mut JbFingerprint,
) -> c_int {
    let ctx = &mut *ctx;
    match &ctx.doc {
        Some(doc) => {
            let mut f = JbFingerprint::default();
            accumulate(doc, &mut f);
            *out = f;
            0
        }
        None => ctx.error.fail("fingerprint: no document"),
    }
}

/// # Safety
/// `ctx` as above; `len` must point to a writable `size_t`.
#[no_mangle]
pub unsafe extern "C" fn jb_serde_serialize(
    ctx: *mut JbSerdeCtx,
    len: *mut usize,
) -> *const c_char {
    let ctx = &mut *ctx;
    let Some(doc) = &ctx.doc else {
        ctx.error.fail("serialize: no document");
        return std::ptr::null();
    };
    ctx.rendered.clear();
    match serde_json::to_writer(&mut ctx.rendered, doc) {
        Ok(()) => {
            *len = ctx.rendered.len();
            ctx.rendered.as_ptr() as *const c_char
        }
        Err(e) => {
            ctx.error.fail(e);
            std::ptr::null()
        }
    }
}

/// Typed decode: `from_slice::<Twitter>`, held in the context.
///
/// # Safety
/// `ctx` as above; `data`/`len` must describe a valid buffer.
#[no_mangle]
pub unsafe extern "C" fn jb_serde_decode(
    ctx: *mut JbSerdeCtx,
    data: *const c_char,
    len: usize,
) -> c_int {
    let ctx = &mut *ctx;
    match serde_json::from_slice::<Twitter>(input_slice(data, len)) {
        Ok(t) => {
            ctx.twitter = Some(t);
            0
        }
        Err(e) => {
            ctx.twitter = None;
            ctx.error.fail(e)
        }
    }
}

/// # Safety
/// `ctx` as above; `out` must point to a writable `jb_twitter_stats`.
#[no_mangle]
pub unsafe extern "C" fn jb_serde_twitter_stats(
    ctx: *mut JbSerdeCtx,
    out: *mut JbTwitterStats,
) -> c_int {
    let ctx = &mut *ctx;
    match &ctx.twitter {
        Some(t) => {
            *out = stats_of(t);
            0
        }
        None => ctx.error.fail("twitter_stats: no decoded document"),
    }
}

/// # Safety
/// `ctx` as above.
#[no_mangle]
pub unsafe extern "C" fn jb_serde_error(ctx: *const JbSerdeCtx) -> *const c_char {
    (*ctx).error.as_ptr()
}
