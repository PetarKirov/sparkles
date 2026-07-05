//! sonic-rs — ByteDance's SIMD JSON library (compile-time SIMD dispatch, so
//! the ISA preset the crate is built with directly determines its kernels).

use std::ffi::{c_char, c_int};

use sonic_rs::{JsonContainerTrait, JsonValueTrait, Value};

use crate::{input_slice, ErrorSlot, JbFingerprint};

pub struct JbSonicCtx {
    doc: Option<Value>,
    rendered: Vec<u8>,
    error: ErrorSlot,
}

fn accumulate(v: &Value, f: &mut JbFingerprint) {
    use sonic_rs::JsonType;

    match v.get_type() {
        JsonType::Null => f.nulls += 1,
        JsonType::Boolean => {
            if v.is_true() {
                f.trues += 1;
            } else {
                f.falses += 1;
            }
        }
        JsonType::Number => {
            f.numbers += 1;
            f.number_sum += v.as_f64().unwrap_or(f64::NAN);
        }
        JsonType::String => {
            f.strings += 1;
            f.string_bytes += v.as_str().map_or(0, |s| s.len() as u64);
        }
        JsonType::Array => {
            f.arrays += 1;
            let a = v.as_array().expect("array type");
            f.array_elems += a.len() as u64;
            for e in a.iter() {
                accumulate(e, f);
            }
        }
        JsonType::Object => {
            f.objects += 1;
            let o = v.as_object().expect("object type");
            f.object_members += o.len() as u64;
            for (k, e) in o.iter() {
                f.key_bytes += k.len() as u64;
                accumulate(e, f);
            }
        }
    }
}

#[no_mangle]
pub extern "C" fn jb_sonic_new() -> *mut JbSonicCtx {
    Box::into_raw(Box::new(JbSonicCtx {
        doc: None,
        rendered: Vec::new(),
        error: ErrorSlot::new(),
    }))
}

/// # Safety
/// `ctx` must be a pointer returned by `jb_sonic_new`, not yet freed.
#[no_mangle]
pub unsafe extern "C" fn jb_sonic_free(ctx: *mut JbSonicCtx) {
    if !ctx.is_null() {
        drop(Box::from_raw(ctx));
    }
}

/// # Safety
/// `ctx` as above; `data`/`len` must describe a valid buffer.
#[no_mangle]
pub unsafe extern "C" fn jb_sonic_parse(
    ctx: *mut JbSonicCtx,
    data: *const c_char,
    len: usize,
) -> c_int {
    let ctx = &mut *ctx;
    match sonic_rs::from_slice::<Value>(input_slice(data, len)) {
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

/// # Safety
/// `ctx` as above.
#[no_mangle]
pub unsafe extern "C" fn jb_sonic_doc_free(ctx: *mut JbSonicCtx) {
    (*ctx).doc = None;
}

/// # Safety
/// `ctx` as above; `out` must point to a writable `jb_fingerprint`.
#[no_mangle]
pub unsafe extern "C" fn jb_sonic_fingerprint(
    ctx: *mut JbSonicCtx,
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
pub unsafe extern "C" fn jb_sonic_serialize(
    ctx: *mut JbSonicCtx,
    len: *mut usize,
) -> *const c_char {
    let ctx = &mut *ctx;
    let Some(doc) = &ctx.doc else {
        ctx.error.fail("serialize: no document");
        return std::ptr::null();
    };
    ctx.rendered.clear();
    match sonic_rs::to_writer(&mut ctx.rendered, doc) {
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

/// # Safety
/// `ctx` as above.
#[no_mangle]
pub unsafe extern "C" fn jb_sonic_error(ctx: *const JbSonicCtx) -> *const c_char {
    (*ctx).error.as_ptr()
}
