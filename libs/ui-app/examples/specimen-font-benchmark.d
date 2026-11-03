#!/usr/bin/env dub
/+ dub.sdl:
    name "specimen-font-benchmark"
    targetPath "build"
    dependency "sparkles:ui-app" path="../../.."
    subConfiguration "sparkles:ui-app" "gui-vulkan"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/

/// CPU preparation and first-use glyph rasterization over a deterministic sweep.
module specimen_font_benchmark;

import core.time : MonoTime;
import std.algorithm.sorting : sort;
import std.file : read;
import std.path : buildPath, dirName;
import std.process : environment;
import std.stdio : writefln;
import sparkles.font : Tag, UserCoordinate;
import sparkles.font : Ppem;
import sparkles.base.text.layout_units : I128, Rational, U128;
import sparkles.ui_app.gui_options : FontRequest;
import sparkles.ui_app.native_loop : CellFont, measureCellFont, NativeCanvas, remeasureCellFont;
import sparkles.ui_app.prepared_specimen : PreparedSpecimenFont;
import sparkles.ui_app.specimen_font : SpecimenFontRequest;
import sparkles.ui_vulkan.glyph_atlas : AtlasGlyph, GlyphAtlas;
import sparkles.ui_vulkan.canvas : FallbackFace;
import sparkles.ui_vulkan.painter : FaceStyle, TextMetrics;

private void bind(ref NativeCanvas canvas, in CellFont cell)
{
    auto em(ulong numerator, ulong denominator)
        => Ppem.fromRational(Rational(I128(U128(numerator, 0)), U128(denominator, 0))).value;
    const(ubyte)[][FaceStyle.max + 1] faces = [cell.bytes, cell.bold, cell.italic, cell.boldItalic];
    FallbackFace[] fallbacks;
    foreach (ref fb; cell.fallbacks)
        fallbacks ~= FallbackFace(fb.bytes, em(fb.emNumerator, fb.emDenominator));
    assert(canvas.cellFont(faces, em(cell.emNumerator, cell.emDenominator),
        TextMetrics(ascent: cell.ascent), fallbacks));
}

void main(string[] arguments)
{
    const fontPath = arguments.length > 1 ? arguments[1]
        : buildPath(environment.get("SPARKLES_FONTS_PATH"), "NotoSans.ttf");
    const bytes = cast(const(ubyte)[]) read(fontPath);
    CellFont cell;
    NativeCanvas canvas;
    const coldStarted = MonoTime.currTime;
    const faceRequest = FontRequest(family: fontPath, bold: fontPath,
        italic: fontPath, boldItalic: fontPath, searchDirs: [dirName(fontPath)]);
    assert(measureCellFont(faceRequest, null, 24, cell));
    bind(canvas, cell);
    const cold = (MonoTime.currTime - coldStarted).total!"nsecs" / 1_000_000.0;
    double[120] resized;
    foreach (i; 0 .. resized.length)
    {
        CellFont next;
        const start = MonoTime.currTime;
        assert(remeasureCellFont(cell, 16 + cast(int)(i % 17), next));
        bind(canvas, next);
        resized[i] = (MonoTime.currTime - start).total!"nsecs" / 1_000_000.0;
        cell = next;
    }
    sort(resized[]);
    writefln("legacy font loading/binding %.3fms; cached size-only metrics/binding p50 %.3f p95 %.3f p99 %.3f ms",
        cold, resized[60], resized[114], resized[118]);
    auto request = SpecimenFontRequest(path: fontPath, px: 24, bytes: bytes);
    PreparedSpecimenFont font;
    GlyphAtlas atlas;
    double[120] samples;
    double[120] preparation;
    foreach (i; 0 .. samples.length)
    {
        request.px = 16 + cast(int)(i % 17);
        request.coordinates = [UserCoordinate(Tag("wght"), (100 + cast(int)(i * 7) % 800) << 16)];
        const started = MonoTime.currTime;
        assert(font.prepare(request));
        assert(canvas.specimenFont(font.bytes, request.faceIndex, font.ppem,
            request.coordinates, font.metrics, 0, font.cellH));
        preparation[i] = (MonoTime.currTime - started).total!"nsecs" / 1_000_000.0;
        if (atlas.overflowed)
            atlas.reset();
        foreach (c; "The quick brown fox jumps over the lazy dog. 0123456789")
        {
            AtlasGlyph glyph;
            cast(void) atlas.get(font.inst, 1, font.map.glyph(c), font.ppem, glyph);
        }
        samples[i] = (MonoTime.currTime - started).total!"nsecs" / 1_000_000.0;
    }
    sort(preparation[]);
    sort(samples[]);
    writefln("%s; 120 unique size/axis frames; prepared CPU p50 %.3f p95 %.3f p99 %.3f ms",
        fontPath, preparation[60], preparation[114], preparation[118]);
    writefln("including CPU atlas misses: p50 %.3f p95 %.3f p99 %.3f worst %.3f ms; GPU/upload/presentation excluded",
        samples[60], samples[114], samples[118], samples[$ - 1]);
}
