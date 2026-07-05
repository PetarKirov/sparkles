//! Engine/version provenance for the bench report header.

use std::ffi::{c_char, CStr};

/// "serde_json 1.0.x; simd-json 0.16.x; sonic-rs 0.5.x" — static storage.
#[no_mangle]
pub extern "C" fn jb_rs_versions() -> *const c_char {
    static VERSIONS: &str = concat!(
        "serde_json ",
        env!("JB_SERDE_JSON_VERSION"),
        "; simd-json ",
        env!("JB_SIMD_JSON_VERSION"),
        "; sonic-rs ",
        env!("JB_SONIC_RS_VERSION"),
        "\0"
    );
    CStr::from_bytes_with_nul(VERSIONS.as_bytes())
        .expect("static string has exactly one NUL")
        .as_ptr()
}
