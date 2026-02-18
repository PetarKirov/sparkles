/// Writes parsed documentation data as JSON files for VitePress consumption.
module sparkle_docs.output.generator;

import std.path : buildPath;
import std.string : replace;

import sparkle_docs.model : ModuleDoc, Output, SearchIndexEntry, TypeGraph;
import sparkles.core_cli.json : writeJsonFile;

/// Serializes an $(LREF Output) to a set of JSON files under a given directory.
struct OutputGenerator
{
    /// Destination directory for generated JSON files.
    string outputPath;
    /// When true, emit compact (single-line) JSON.
    bool compact;

    /** Write all JSON output files.
     *
     * Creates:
     * - `index.json` — combined output with all modules
     * - `<module_qualified>.json` — per-module files
     * - `search.json` — flat search index
     * - `types.json` — type relationship graph
     *
     * Params:
     *     data = the parsed documentation output to serialize
     */
    void generate(Output data)
    {
        writeJsonFile(data, buildPath(outputPath, "index.json"), compact);

        foreach (modName, mod; data.modules)
        {
            string fileName = modName.replace(".", "_") ~ ".json";
            ModuleOutput modOutput;
            modOutput.module_ = mod;
            writeJsonFile(modOutput, buildPath(outputPath, fileName), compact);
        }

        SearchOutput searchOutput;
        searchOutput.index = data.searchIndex;
        writeJsonFile(searchOutput, buildPath(outputPath, "search.json"), compact);

        TypeGraphOutput typeOutput;
        typeOutput.graph = data.typeGraph;
        writeJsonFile(typeOutput, buildPath(outputPath, "types.json"), compact);
    }
}

/// JSON envelope for a single module's documentation.
struct ModuleOutput
{
    ModuleDoc module_;
}

/// JSON envelope for the search index.
struct SearchOutput
{
    SearchIndexEntry[] index;
}

/// JSON envelope for the type graph.
struct TypeGraphOutput
{
    TypeGraph graph;
}
