/**
The test corpus's manifest, `test/goldens/manifest.txt` (testing.md §
Corpus): a gate accepts corpus evidence only from faces pinned there by
SHA-256, with their licence, upstream source and table inventory.
*/
module sparkles.font_oracle.manifest;

import std.algorithm : canFind, map, sort, startsWith;
import std.array : array, join, split;
import std.conv : text;
import std.digest : LetterCase, toHexString;
import std.digest.sha : sha256Of;
import std.file : exists, read, readText;
import std.path : baseName, buildPath, dirName;
import std.string : lineSplitter, strip, stripRight;

import sparkles.font_oracle.corpus : baseCorpus, mathCorpus, testFontsDir;
import sparkles.test_runner.skip : skipTest;

/// The tags of face 0's table directory, read apart from `openFace`, which refuses some of these faces.
private string[] tableTags(const(ubyte)[] b)
{
    static uint be32(const(ubyte)[] b, size_t at) => (uint(b[at]) << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3];
    size_t at = b[0 .. 4] == cast(const(ubyte)[]) "ttcf" ? be32(b, 12) : 0;
    const count = (b[at + 4] << 8) | b[at + 5];
    string[] tags;
    foreach (i; 0 .. count)
        tags ~= (cast(const(char)[]) b[at + 12 + 16 * i .. at + 16 + 16 * i]).stripRight.idup;
    return tags.sort.release;
}

@("oracle.corpus.manifest")
@system
unittest
{
    if (testFontsDir is null)
        skipTest("SPARKLES_FONT_TEST_CORPUS is unset");
    const manifest = readText(buildPath(__FILE_FULL_PATH__.dirName.dirName.dirName, "goldens", "manifest.txt"));
    string[] listed;
    foreach (line; manifest.lineSplitter)
    {
        if (line.startsWith("#") || line.strip.length == 0)
            continue;
        const f = line.split(" | ");
        assert(f.length == 6, line);
        const path = buildPath(testFontsDir, f[0]["test/".length .. $]);
        assert(path.exists, f[0] ~ " is listed but not in the corpus");
        const bytes = cast(const(ubyte)[]) read(path);
        assert(toHexString!(LetterCase.lower)(sha256Of(bytes)) == f[1], f[0] ~ ": the file is not the pinned one");
        assert(f[2] == "0" && f[3].length && f[4].length, line);
        assert(tableTags(bytes).join(" ") == f[5], text(f[0], ": tables ", tableTags(bytes).join(" ")));
        listed ~= f[0];
    }
    foreach (path; baseCorpus ~ mathCorpus)
    {
        const name = "test/" ~ path.dirName.baseName ~ "/" ~ path.baseName;
        assert(listed.canFind(name), name ~ " is in the corpus but not in the manifest");
    }
    assert(listed.length >= 40);
}
