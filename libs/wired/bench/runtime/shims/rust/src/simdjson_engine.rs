//! simd-json — the Rust port of simdjson's two-stage pipeline.
//!
//! The library requires `&mut [u8]` input (it de-escapes strings in place so
//! borrowed values can point at decoded bytes), so the timed parse op copies
//! the input into a reused scratch buffer first — the honest immutable-input
//! contract — and builds a `BorrowedValue` with reused `Buffers`, which is
//! then dropped (it borrows the scratch buffer and cannot be stored). The
//! document consumed by fingerprint/serialize is re-parsed lazily as an
//! `OwnedValue` from a pristine copy, outside any timed op.

use std::ffi::{c_char, c_int};

use simd_json::{Buffers, OwnedValue};

use crate::{input_slice, ErrorSlot, JbFingerprint};

pub struct JbSimdjCtx {
    scratch: Vec<u8>,  // mutated by in-situ de-escaping during parse
    pristine: Vec<u8>, // untouched copy for the lazy owned re-parse
    buffers: Buffers,
    owned: Option<OwnedValue>,
    rendered: Vec<u8>,
    error: ErrorSlot,
}

fn accumulate(v: &OwnedValue, f: &mut JbFingerprint) {
    use simd_json::StaticNode;

    match v {
        OwnedValue::Static(StaticNode::Null) => f.nulls += 1,
        OwnedValue::Static(StaticNode::Bool(true)) => f.trues += 1,
        OwnedValue::Static(StaticNode::Bool(false)) => f.falses += 1,
        OwnedValue::Static(StaticNode::I64(n)) => {
            f.numbers += 1;
            f.number_sum += *n as f64;
        }
        OwnedValue::Static(StaticNode::U64(n)) => {
            f.numbers += 1;
            f.number_sum += *n as f64;
        }
        OwnedValue::Static(StaticNode::F64(n)) => {
            f.numbers += 1;
            f.number_sum += n;
        }
        OwnedValue::String(s) => {
            f.strings += 1;
            f.string_bytes += s.len() as u64;
        }
        OwnedValue::Array(a) => {
            f.arrays += 1;
            f.array_elems += a.len() as u64;
            for e in a.iter() {
                accumulate(e, f);
            }
        }
        OwnedValue::Object(o) => {
            f.objects += 1;
            f.object_members += o.len() as u64;
            for (k, e) in o.iter() {
                f.key_bytes += k.len() as u64;
                accumulate(e, f);
            }
        }
    }
}

impl JbSimdjCtx {
    /// The owned document, materialized on first use from the pristine copy.
    fn owned_doc(&mut self) -> Result<&OwnedValue, simd_json::Error> {
        if self.owned.is_none() {
            let mut copy = self.pristine.clone();
            self.owned = Some(simd_json::to_owned_value(&mut copy)?);
        }
        Ok(self.owned.as_ref().expect("just materialized"))
    }
}

#[no_mangle]
pub extern "C" fn jb_simdj_new() -> *mut JbSimdjCtx {
    Box::into_raw(Box::new(JbSimdjCtx {
        scratch: Vec::new(),
        pristine: Vec::new(),
        buffers: Buffers::default(),
        owned: None,
        rendered: Vec::new(),
        error: ErrorSlot::new(),
    }))
}

/// # Safety
/// `ctx` must be a pointer returned by `jb_simdj_new`, not yet freed.
#[no_mangle]
pub unsafe extern "C" fn jb_simdj_free(ctx: *mut JbSimdjCtx) {
    if !ctx.is_null() {
        drop(Box::from_raw(ctx));
    }
}

/// # Safety
/// `ctx` as above; `data`/`len` must describe a valid buffer.
#[no_mangle]
pub unsafe extern "C" fn jb_simdj_parse(
    ctx: *mut JbSimdjCtx,
    data: *const c_char,
    len: usize,
) -> c_int {
    let ctx = &mut *ctx;
    let input = input_slice(data, len);

    // Timed: the required mutable copy + tape + borrowed-value build.
    ctx.scratch.clear();
    ctx.scratch.extend_from_slice(input);
    match simd_json::to_borrowed_value_with_buffers(&mut ctx.scratch, &mut ctx.buffers) {
        Ok(borrowed) => {
            drop(borrowed);
            // Keep a pristine copy for the untimed owned re-parse.
            ctx.pristine.clear();
            ctx.pristine.extend_from_slice(input);
            ctx.owned = None;
            0
        }
        Err(e) => {
            ctx.owned = None;
            ctx.error.fail(e)
        }
    }
}

/// # Safety
/// `ctx` as above.
#[no_mangle]
pub unsafe extern "C" fn jb_simdj_doc_free(ctx: *mut JbSimdjCtx) {
    (*ctx).owned = None;
}

/// # Safety
/// `ctx` as above; `out` must point to a writable `jb_fingerprint`.
#[no_mangle]
pub unsafe extern "C" fn jb_simdj_fingerprint(
    ctx: *mut JbSimdjCtx,
    out: *mut JbFingerprint,
) -> c_int {
    let ctx = &mut *ctx;
    if ctx.pristine.is_empty() && ctx.owned.is_none() {
        return ctx.error.fail("fingerprint: no document");
    }
    match ctx.owned_doc() {
        Ok(doc) => {
            let mut f = JbFingerprint::default();
            accumulate(doc, &mut f);
            *out = f;
            0
        }
        Err(e) => ctx.error.fail(e),
    }
}

/// # Safety
/// `ctx` as above; `len` must point to a writable `size_t`.
#[no_mangle]
pub unsafe extern "C" fn jb_simdj_serialize(
    ctx: *mut JbSimdjCtx,
    len: *mut usize,
) -> *const c_char {
    use simd_json::prelude::Writable;

    let ctx = &mut *ctx;
    if ctx.pristine.is_empty() && ctx.owned.is_none() {
        ctx.error.fail("serialize: no document");
        return std::ptr::null();
    }
    match ctx.owned_doc() {
        Ok(doc) => {
            // simd-json's own writer (value-trait Writable), not serde's.
            let text = doc.encode();
            ctx.rendered.clear();
            ctx.rendered.extend_from_slice(text.as_bytes());
            *len = ctx.rendered.len();
            ctx.rendered.as_ptr() as *const c_char
        }
        Err(e) => {
            ctx.error.fail(e);
            std::ptr::null()
        }
    }
}

/// # Safety
/// `ctx` as above.
#[no_mangle]
pub unsafe extern "C" fn jb_simdj_error(ctx: *const JbSimdjCtx) -> *const c_char {
    (*ctx).error.as_ptr()
}
