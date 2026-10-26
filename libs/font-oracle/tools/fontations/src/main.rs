//! Prints fontations' reading of the faces named on the command line, for
//! `gen_fontations_goldens.d` to digest into `test/goldens/fontations.txt`
//! (docs/specs/font/testing.md, the fontations oracle).
//!
//! Each argument is a font file; a collection stands for its first face.
//! The output is line based, one face after another:
//!
//! ```text
//! face <path>
//! glyphs <count>
//! axis <tag> <min> <default> <max>          one per fvar axis, F16.16 bits
//! instance <label> <c0,c1,...>              normalized F2Dot14 bits
//! hadv <v0> <v1> ...                        HVAR advance deltas, per glyph
//! vadv ... / vorg ...                       VVAR advance and origin deltas
//! mvar <tag>=<v> ...                        MVAR deltas, per value record
//! base <H|V> <script>/<baseline>=<v> ...    BASE coordinates
//! math italics|accent <v0> ...              MATH glyph values, per glyph
//! math kern<corner> <k0> ...                MATH kern tables, per glyph
//! ```
//!
//! An instance is `default`, `min:<tag>` or `max:<tag>` (one axis at an
//! extreme), or `allmin`/`allmax` (every axis, when there are several). A
//! delta or coordinate is the bits of its `F48Dot16` (1/65,536 unit), `x`
//! where fontations answers `None`. A table the face lacks prints `none`.
//! `MATH` is read at the default only, and a kern table prints as
//! `h0:h1:...;k0:k1:...;q0:q1:...`: its heights, its values, and its kern
//! at each probe height (every height less one, the height, the height
//! plus one, then -2^30 and 2^30), or `x` where the corner has none.

use read_fonts::tables::base::{BaseAxis, BaseInstance};
use read_fonts::tables::math::MathKernCorner;
use read_fonts::types::{F2Dot14, GlyphId, Tag};
use read_fonts::{FontRef, TableProvider};
use skrifa::MetadataProvider;
use std::fmt::Write as _;

fn main() {
    let mut out = String::new();
    for path in std::env::args().skip(1) {
        let bytes = std::fs::read(&path).expect("readable font");
        let font = match FontRef::from_index(&bytes, 0) {
            Ok(font) => font,
            Err(_) => continue,
        };
        face(&mut out, &path, &font);
        print!("{out}");
        out.clear();
    }
}

fn face(out: &mut String, path: &str, font: &FontRef) {
    let glyphs = font.maxp().map(|m| m.num_glyphs()).unwrap_or(0);
    writeln!(out, "face {path}").unwrap();
    writeln!(out, "glyphs {glyphs}").unwrap();
    let axes: Vec<_> = font
        .fvar()
        .ok()
        .and_then(|f| f.axes().ok().map(|a| a.to_vec()))
        .unwrap_or_default();
    for a in &axes {
        writeln!(
            out,
            "axis {} {} {} {}",
            a.axis_tag(),
            a.min_value().to_bits(),
            a.default_value().to_bits(),
            a.max_value().to_bits()
        )
        .unwrap();
    }

    let mut instances: Vec<(String, Vec<(Tag, f32)>)> = vec![("default".into(), vec![])];
    for a in &axes {
        instances.push((format!("min:{}", a.axis_tag()), vec![(a.axis_tag(), a.min_value().to_f32())]));
        instances.push((format!("max:{}", a.axis_tag()), vec![(a.axis_tag(), a.max_value().to_f32())]));
    }
    if axes.len() > 1 {
        instances.push(("allmin".into(), axes.iter().map(|a| (a.axis_tag(), a.min_value().to_f32())).collect()));
        instances.push(("allmax".into(), axes.iter().map(|a| (a.axis_tag(), a.max_value().to_f32())).collect()));
    }

    for (label, settings) in &instances {
        let location = font.axes().location(settings.iter().copied());
        let coords: Vec<F2Dot14> = if settings.is_empty() { vec![] } else { location.coords().to_vec() };
        let joined: Vec<String> = coords.iter().map(|c| c.to_bits().to_string()).collect();
        writeln!(out, "instance {label} {}", joined.join(",")).unwrap();
        if !coords.is_empty() {
            deltas(out, font, glyphs, &coords);
        }
        base(out, font, &coords);
    }
    math(out, font, glyphs);
}

fn bits(v: Option<read_fonts::types::F48Dot16>) -> String {
    v.map_or_else(|| "x".into(), |d| d.to_bits().to_string())
}

fn deltas(out: &mut String, font: &FontRef, glyphs: u16, coords: &[F2Dot14]) {
    let row = |f: &dyn Fn(GlyphId) -> Option<read_fonts::types::F48Dot16>| -> String {
        (0..glyphs as u32).map(|g| bits(f(GlyphId::new(g)))).collect::<Vec<_>>().join(" ")
    };
    match font.hvar() {
        Ok(hvar) => writeln!(out, "hadv {}", row(&|g| hvar.advance_delta(g, coords))).unwrap(),
        Err(_) => writeln!(out, "hadv none").unwrap(),
    }
    match font.vvar() {
        Ok(vvar) => {
            writeln!(out, "vadv {}", row(&|g| vvar.advance_delta(g, coords))).unwrap();
            writeln!(out, "vorg {}", row(&|g| vvar.v_origin_y_delta(g, coords))).unwrap();
        }
        Err(_) => writeln!(out, "vadv none\nvorg none").unwrap(),
    }
    match font.mvar() {
        Ok(mvar) => {
            let instance = mvar.at(coords);
            let pairs: Vec<String> = mvar
                .value_records()
                .iter()
                .map(|r| {
                    let tag = r.value_tag();
                    format!("{tag}={}", bits(instance.as_ref().and_then(|i| i.get(tag))))
                })
                .collect();
            writeln!(out, "mvar {}", pairs.join(" ")).unwrap();
        }
        Err(_) => writeln!(out, "mvar none").unwrap(),
    }
}

fn base(out: &mut String, font: &FontRef, coords: &[F2Dot14]) {
    let Ok(table) = font.base() else {
        writeln!(out, "base none").unwrap();
        return;
    };
    let instance = BaseInstance::with_coords(table.clone(), coords);
    for (name, which) in [("H", BaseAxis::Horizontal), ("V", BaseAxis::Vertical)] {
        let Some(axis) = table.axis(which) else {
            continue;
        };
        let mut scripts: Vec<Tag> = axis
            .base_script_list()
            .map(|l| l.base_script_records().iter().map(|r| r.base_script_tag()).collect())
            .unwrap_or_default();
        let mut tags: Vec<Tag> = axis
            .base_tag_list()
            .and_then(|l| l.ok())
            .map(|l| l.baseline_tags().iter().map(|t| t.get()).collect())
            .unwrap_or_default();
        scripts.extend([Tag::new(b"DFLT"), Tag::new(b"arab"), Tag::new(b"zzzz")]);
        tags.extend([Tag::new(b"hang"), Tag::new(b"math"), Tag::new(b"zzzz")]);
        scripts.sort();
        scripts.dedup();
        tags.sort();
        tags.dedup();
        let mut pairs = Vec::new();
        for s in &scripts {
            for t in &tags {
                pairs.push(format!("{s}/{t}={}", bits(instance.baseline(*t, which, *s))));
            }
        }
        writeln!(out, "base {name} {}", pairs.join(" ")).unwrap();
    }
}

fn math(out: &mut String, font: &FontRef, glyphs: u16) {
    let Ok(table) = font.math() else {
        writeln!(out, "math none").unwrap();
        return;
    };
    let Ok(info) = table.math_glyph_info() else {
        writeln!(out, "math none").unwrap();
        return;
    };
    let gids = || (0..glyphs as u32).map(GlyphId::new);
    let opt = |v: Option<i32>| v.map_or_else(|| "x".to_string(), |v| v.to_string());
    let italics = info.math_italics_correction_info().and_then(|t| t.ok());
    let row: Vec<String> = gids().map(|g| opt(italics.as_ref().and_then(|t| t.correction(g)))).collect();
    writeln!(out, "math italics {}", row.join(" ")).unwrap();
    let accents = info.math_top_accent_attachment().and_then(|t| t.ok());
    let row: Vec<String> = gids().map(|g| opt(accents.as_ref().and_then(|t| t.attachment(g)))).collect();
    writeln!(out, "math accent {}", row.join(" ")).unwrap();

    let kerns = info.math_kern_info().and_then(|t| t.ok());
    let corners = [
        MathKernCorner::TopRight,
        MathKernCorner::TopLeft,
        MathKernCorner::BottomRight,
        MathKernCorner::BottomLeft,
    ];
    for (i, corner) in corners.into_iter().enumerate() {
        let row: Vec<String> = gids()
            .map(|g| {
                let Some(kern) = kerns.as_ref().and_then(|k| k.kern(g, corner)) else {
                    return "x".to_string();
                };
                let heights: Vec<i32> = kern.correction_height().iter().map(|h| h.value().to_i16() as i32).collect();
                let values: Vec<i32> = kern.kern_values().iter().map(|v| v.value().to_i16() as i32).collect();
                let mut probes: Vec<i32> = heights.iter().flat_map(|&h| [h - 1, h, h + 1]).collect();
                probes.extend([-(1 << 30), 1 << 30]);
                let colon = |v: &[i32]| v.iter().map(|x| x.to_string()).collect::<Vec<_>>().join(":");
                let answers: Vec<String> = probes.iter().map(|&h| opt(kern.kerning(h))).collect();
                format!("{};{};{}", colon(&heights), colon(&values), answers.join(":"))
            })
            .collect();
        writeln!(out, "math kern{i} {}", row.join(" ")).unwrap();
    }
}
