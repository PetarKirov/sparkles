//! Extracts the locked engine versions from Cargo.lock into rustc env vars,
//! so `jb_rs_versions()` can report exact provenance without runtime lookups.

use std::fs;
use std::path::Path;

fn locked_version(lock: &str, name: &str) -> String {
    let mut in_package = false;
    let mut is_target = false;
    for line in lock.lines() {
        let line = line.trim();
        if line == "[[package]]" {
            in_package = true;
            is_target = false;
        } else if in_package && line.starts_with("name = ") {
            is_target = line == format!("name = \"{name}\"");
        } else if in_package && is_target && line.starts_with("version = ") {
            return line
                .trim_start_matches("version = ")
                .trim_matches('"')
                .to_string();
        }
    }
    "unknown".to_string()
}

fn main() {
    let manifest = std::env::var("CARGO_MANIFEST_DIR").expect("cargo sets this");
    let lock_path = Path::new(&manifest).join("Cargo.lock");
    let lock = fs::read_to_string(&lock_path).unwrap_or_default();
    for (var, name) in [
        ("JB_SERDE_JSON_VERSION", "serde_json"),
        ("JB_SIMD_JSON_VERSION", "simd-json"),
        ("JB_SONIC_RS_VERSION", "sonic-rs"),
    ] {
        println!("cargo:rustc-env={}={}", var, locked_version(&lock, name));
    }
    println!("cargo:rerun-if-changed=Cargo.lock");
}
