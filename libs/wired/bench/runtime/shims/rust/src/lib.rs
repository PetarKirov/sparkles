//! Rust JSON engines behind the C ABI of the wired runtime bench
//! (`shims/include/wired_bench_shim.h`).
//!
//! Conventions shared by every engine: one boxed context per engine owning
//! the parsed document, the serialize buffer, and the last error message
//! (a `CString` valid until the next call); `int` returns are 0/nonzero;
//! no allocation crosses the FFI boundary. The crate builds with
//! `panic = "abort"` — fallible paths return error codes, so a panic is a
//! bug and may not unwind into D.

use std::ffi::CString;

mod serde_engine;
mod simdjson_engine;
mod sonic_engine;
mod versions;

/// Mirrors `jb_fingerprint` in the shim header (field-for-field).
#[repr(C)]
#[derive(Default, Clone, Copy)]
pub struct JbFingerprint {
    pub nulls: u64,
    pub trues: u64,
    pub falses: u64,
    pub numbers: u64,
    pub strings: u64,
    pub arrays: u64,
    pub objects: u64,
    pub array_elems: u64,
    pub object_members: u64,
    pub string_bytes: u64,
    pub key_bytes: u64,
    pub number_sum: f64,
}

/// Context-owned last-error storage.
pub(crate) struct ErrorSlot {
    msg: CString,
}

impl ErrorSlot {
    pub(crate) fn new() -> Self {
        Self {
            msg: CString::default(),
        }
    }

    /// Records `err`, returning the C failure code.
    pub(crate) fn fail(&mut self, err: impl std::fmt::Display) -> std::ffi::c_int {
        let text = err.to_string().replace('\0', "?");
        self.msg = CString::new(text).unwrap_or_default();
        1
    }

    pub(crate) fn as_ptr(&self) -> *const std::ffi::c_char {
        self.msg.as_ptr()
    }
}

/// The caller's input bytes. Safety: `data`/`len` must describe a valid,
/// initialized buffer for the duration of the call (the D harness passes a
/// slice of a GC-held string).
pub(crate) unsafe fn input_slice<'a>(data: *const std::ffi::c_char, len: usize) -> &'a [u8] {
    std::slice::from_raw_parts(data as *const u8, len)
}
