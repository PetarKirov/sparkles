//! Width oracle for the text-conformance harness, exposing the Rust
//! `unicode-width` crate (the de-facto width model in the Rust TUI ecosystem).
//!
//! Reads one hex token per stdin line and prints a width per line:
//!   - mode `cp`  — token is a hex code point; print `UnicodeWidthChar::width`
//!     (control/unassigned → 0).
//!   - mode `str` — token is hex UTF-8 bytes; print `UnicodeWidthStr::width`.
//!
//! Mirrors the kitty subprocess protocol used by the harness (hex in, int out).

use std::io::{self, BufRead, Write};
use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};

fn main() {
    let mode = std::env::args().nth(1).unwrap_or_default();
    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut out = io::BufWriter::new(stdout.lock());

    for line in stdin.lock().lines() {
        let line = line.unwrap();
        let tok = line.trim();
        if tok.is_empty() {
            continue;
        }
        let width: i64 = if mode == "cp" {
            let cp = u32::from_str_radix(tok, 16).expect("hex code point");
            char::from_u32(cp)
                .and_then(|c| c.width())
                .map(|w| w as i64)
                .unwrap_or(0)
        } else {
            // `str`: hex-encoded UTF-8 bytes.
            let bytes: Vec<u8> = (0..tok.len())
                .step_by(2)
                .map(|i| u8::from_str_radix(&tok[i..i + 2], 16).expect("hex byte"))
                .collect();
            String::from_utf8_lossy(&bytes).width() as i64
        };
        writeln!(out, "{}", width).unwrap();
    }
}
