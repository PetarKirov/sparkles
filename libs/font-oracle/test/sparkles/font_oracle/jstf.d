/**
FTS11's real-record check (testing.md § Shaping): the library's reading of
each `JSTF` table in a font corpus equals fontTools'. The bundle holds no
`JSTF` table. SIL's Scheherazade New and Lateef do, under the OFL, so they
sit in the test corpus (`nix/packages/font-test-corpus.nix`) and are checked
by default. Microsoft's core Arial and Times New Roman do too, but their
licence keeps them out of every binary cache, so that corpus is opt-in
(`nix/packages/font-unfree-corpus.nix`) and its check skips without it.
fontTools' readings are recorded in `test/goldens/jstf.txt` and
`test/goldens/jstf-unfree.txt` by `tools/gen_jstf_goldens.d`, with each
face's SHA-256.
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
SIL's Scheherazade New (4 weights) and Lateef (7 weights): every script
fontTools reads is the library's. Their extender glyphs include
`absAutoKashida`, which no character maps to.
*/
@("oracle.jstf.agreesWithFontTools")
@system
unittest
{
    const corpus = environment.get("SPARKLES_FONT_TEST_CORPUS");
    if (corpus is null)
        return skipTest("SPARKLES_FONT_TEST_CORPUS is unset");
    checkGoldens(corpus, "jstf.txt", faces: 11);
}

/// Microsoft's core Arial and Times New Roman, regular and bold, when the opt-in corpus is built.
@("oracle.jstf.unfreeAgreesWithFontTools")
@system
unittest
{
    const corpus = environment.get("SPARKLES_FONT_UNFREE_CORPUS");
    if (corpus is null)
        return skipTest("SPARKLES_FONT_UNFREE_CORPUS is unset: build .#sparkles-font-unfree-corpus");
    checkGoldens(corpus, "jstf-unfree.txt", faces: 4);
}

/**
Every script fontTools reads in the faces `golden` lists — its tag, its
extender glyphs, whether it has a default language system and how many
tagged ones — is the library's, and the library lists no script fontTools
does not. No corpus's records hold priority records, which the default
language system's absence shows.
*/
private void checkGoldens(string corpus, string goldenName, size_t faces) @system
{
    assert(corpus.exists, corpus);
    const golden = readText(buildPath(__FILE_FULL_PATH__.dirName.dirName.dirName, "goldens", goldenName));

    const(ubyte)[] bytes;
    string name;
    Face face;
    size_t facesSeen, scriptsChecked;
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
            ++facesSeen;
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
    assert(facesSeen == faces && scriptsChecked == faces, text(facesSeen, " faces, ", scriptsChecked, " scripts"));
}
