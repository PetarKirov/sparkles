/**
FTS11's real-record check (testing.md § Shaping): the library's reading of
each `JSTF` table in the unfree corpus equals fontTools'. No free face
holds a `JSTF` table; Microsoft's core Arial and Times New Roman do, and
their licence keeps them out of every binary cache, so the corpus is
opt-in (`nix/packages/font-unfree-corpus.nix`) and this check skips
without it. fontTools' reading is recorded in `test/goldens/jstf.txt` by
`tools/gen_jstf_goldens.d`, with each face's SHA-256.
*/
module sparkles.font_oracle.jstf;

import std.conv : text, to;
import std.digest : LetterCase, toHexString;
import std.digest.sha : sha256Of;
import std.file : exists, read, readText;
import std.path : buildPath, dirName;
import std.process : environment;
import std.string : lineSplitter, split, startsWith;

import sparkles.font;
import sparkles.test_runner.skip : skipTest;

/**
Every script fontTools reads — its tag, its extender glyphs, whether it has
a default language system and how many tagged ones — is the library's, and
the library lists no script fontTools does not. The corpus's records hold
no priority records, which the default language system's absence shows.
*/
@("oracle.jstf.agreesWithFontTools")
@system
unittest
{
    const corpus = environment.get("SPARKLES_FONT_UNFREE_CORPUS");
    if (corpus is null)
        return skipTest("SPARKLES_FONT_UNFREE_CORPUS is unset: build .#sparkles-font-unfree-corpus");
    assert(corpus.exists, corpus);
    const golden = readText(buildPath(__FILE_FULL_PATH__.dirName.dirName.dirName, "goldens", "jstf.txt"));

    const(ubyte)[] bytes;
    string name;
    Face face;
    size_t faces, scriptsChecked;
    Tag[16] scripts;
    size_t scriptCount, scriptsSeen;
    void finishFace()
    {
        if (name is null)
            return;
        assert(scriptsSeen == scriptCount, text(name, ": the library lists ", scriptCount,
            " scripts, fontTools ", scriptsSeen));
    }
    foreach (line; golden.lineSplitter)
    {
        if (line.startsWith("#"))
            continue;
        const f = line.split(" ");
        if (f[0] == "face")
        {
            finishFace();
            name = f[1];
            const path = buildPath(corpus, name);
            assert(path.exists, path);
            bytes = cast(const(ubyte)[]) read(path);
            assert(toHexString!(LetterCase.lower)(sha256Of(bytes)) == f[3],
                name ~ " changed since the goldens were recorded: regenerate them");
            face = openFace(bytes).value;
            assert(hasJstf(face).value, name);
            const n = jstfScripts(face, scripts[]);
            assert(n.hasValue, name);
            scriptCount = n.value;
            scriptsSeen = 0;
            ++faces;
            continue;
        }
        // script TAG extenders G… default present|absent languages N
        assert(f[0] == "script" && f[2] == "extenders", line);
        const tag = Tag(f[1]);
        assert(scripts[scriptsSeen++] == tag, text(name, ": script ", scriptsSeen, " is ", scripts[scriptsSeen - 1]));
        const defaultAt = f.length - 4;
        assert(f[defaultAt] == "default" && f[defaultAt + 2] == "languages", line);
        uint[] expected;
        foreach (g; f[3 .. defaultAt])
            expected ~= g.to!uint;
        const info = jstfScript(face, tag).value;
        assert(info.present && info.hasExtenders == (expected.length > 0)
            && info.extenderCount == expected.length, text(name, " ", f[1]));
        auto extenders = new uint[expected.length];
        assert(jstfExtenderGlyphs(face, tag, extenders).value == expected.length, name);
        assert(extenders == expected, text(name, " ", f[1], " extenders ", extenders, " vs ", expected));
        assert(info.hasDefaultLanguage == (f[defaultAt + 1] == "present"), text(name, " ", f[1]));
        assert(info.languageCount == f[defaultAt + 3].to!size_t, text(name, " ", f[1]));
        if (!info.hasDefaultLanguage)
            assert(jstfPriorityCount(face, tag, Tag.init).value == 0
                && !jstfPriority(face, tag, Tag.init).value.present, name);
        ++scriptsChecked;
    }
    finishFace();
    assert(faces == 4 && scriptsChecked == 4, text(faces, " faces, ", scriptsChecked, " scripts"));
}
