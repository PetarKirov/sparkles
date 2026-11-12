//! `iroh-collection <dir>`: the name of the collection `sendme send <dir>`
//! would send, printed in lowercase hex, with no network. The oracle of
//! `sparkles:build-primitives`' collection (`CAI1`, `CAI2`).
//!
//! It walks `<dir>` as `sendme`'s `import` does: regular files only, links
//! left out, each named by its path from `<dir>`'s parent with `/` between
//! components; and it imports them into an in-memory iroh-blobs store and
//! stores their `Collection`, through the bridge's `collection_hash`.

use std::path::{Component, Path};

use anyhow::Context;
use walkdir::WalkDir;

fn main() -> anyhow::Result<()> {
    let dir = std::env::args().nth(1).context("usage: iroh-collection <dir>")?;
    let dir = Path::new(&dir).canonicalize()?;
    let root = dir.parent().context("the directory has no parent")?;
    let mut files = Vec::new();
    for entry in WalkDir::new(&dir) {
        let entry = entry?;
        if !entry.file_type().is_file() {
            continue;
        }
        let path = entry.into_path();
        let name = name_of(path.strip_prefix(root)?)?;
        files.push((name, path));
    }
    let hash = sparkles_iroh_send::collection_hash(files)?;
    println!("{}", data_encoding::HEXLOWER.encode(&hash));
    Ok(())
}

// `sendme`'s `canonicalized_path_to_string` for a relative path.
fn name_of(path: &Path) -> anyhow::Result<String> {
    let mut parts = Vec::new();
    for c in path.components() {
        match c {
            Component::Normal(x) => {
                let s = x.to_str().context("invalid character in path")?;
                anyhow::ensure!(!s.contains('/') && !s.contains('\\'), "invalid path component {s:?}");
                parts.push(s);
            }
            other => anyhow::bail!("invalid path component {other:?}"),
        }
    }
    Ok(parts.join("/"))
}
