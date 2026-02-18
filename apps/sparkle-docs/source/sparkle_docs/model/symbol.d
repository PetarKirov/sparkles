/** Data types representing D language symbols and their documentation.
 *
 * These types form the core model for the documentation generator,
 * capturing symbol identity, hierarchy, source location, and
 * extracted DDoc information.
 */
module sparkle_docs.model.symbol;

import sparkles.core_cli.string : StringRepresentation;

@safe:

/// Classification of a D language symbol as reported by DMD's JSON output.
enum SymbolKind : string
{
    @StringRepresentation("module")
    module_ = "module",
    @StringRepresentation("package")
    package_ = "package",
    @StringRepresentation("struct")
    struct_ = "struct",
    @StringRepresentation("class")
    class_ = "class",
    @StringRepresentation("interface")
    interface_ = "interface",
    @StringRepresentation("enum")
    enum_ = "enum",
    @StringRepresentation("function")
    function_ = "function",
    variable = "variable",
    @StringRepresentation("alias")
    alias_ = "alias",
    @StringRepresentation("template")
    template_ = "template",
    enumMember = "enumMember",
    @StringRepresentation("unittest")
    unittest_ = "unittest",
    constructor = "constructor",
    destructor = "destructor",
    staticDestructor = "staticDestructor",
    invariant_ = "invariant",
    postblit = "postblit",
    getter = "getter",
    setter = "setter",
}

/// Visibility level of a symbol.
enum Protection : string
{
    @StringRepresentation("private")
    private_ = "private",
    @StringRepresentation("protected")
    protected_ = "protected",
    @StringRepresentation("public")
    public_ = "public",
    @StringRepresentation("package")
    package_ = "package",
    @StringRepresentation("export")
    export_ = "export",
}

/// A documented D symbol with its identity, type information, source
/// location, and extracted documentation.
struct Symbol
{
    /// Dot-separated fully-qualified name (e.g. `std.algorithm.sort`).
    string qualifiedName;
    /// Simple unqualified name.
    string name;
    SymbolKind kind;
    Protection protection;

    /// First paragraph of the DDoc comment.
    string summary;
    /// Full DDoc comment body.
    string description;
    /// Compiler attributes applied to this symbol.
    string[] attributes;

    /// Function parameters, empty for non-callable symbols.
    Parameter[] parameters;
    /// Return type string for functions.
    string returnType;
    TemplateParam[] templateParams;
    /// Template constraints.
    string[] constraints;

    /// Base classes / implemented interfaces.
    string[] baseTypes;
    /// Nested declarations (e.g. struct members, enum values).
    Symbol[] members;

    /// Path to the source file containing this symbol.
    string sourceFile;
    size_t line;
    size_t column;

    /// Parsed `Params:` DDoc section entries.
    ParamDoc[] paramDocs;
    /// Parsed `Returns:` DDoc section.
    string returnsDoc;
    /// Parsed `Throws:` DDoc section entries.
    string[] throwsDoc;
    /// Parsed `See_Also:` DDoc section entries.
    string[] seeAlso;
    /// Code examples extracted from `Examples:` DDoc sections.
    string[] examples;
    /// Unittest source snippets associated with this symbol.
    string[] unittests;
    /// Parsed `Bugs:` DDoc section entries.
    string[] bugs;
    /// Deprecation message, if any.
    string deprecated_;

    string[] referencedBy;
    string[] references;
}

/// A function parameter with its type, name, and optional default value.
struct Parameter
{
    string name;
    string type;
    string defaultValue;
    bool isVariadic;
    StorageClass storageClass;
}

/// D parameter storage class qualifier.
enum StorageClass : string
{
    none = "none",
    @StringRepresentation("scope")
    scope_ = "scope",
    @StringRepresentation("ref")
    ref_ = "ref",
    @StringRepresentation("out")
    out_ = "out",
    @StringRepresentation("lazy")
    lazy_ = "lazy",
    @StringRepresentation("in")
    in_ = "in",
    @StringRepresentation("const")
    const_ = "const",
    @StringRepresentation("immutable")
    immutable_ = "immutable",
    @StringRepresentation("shared")
    shared_ = "shared",
    @StringRepresentation("return")
    return_ = "return",
}

/// A template parameter declaration.
struct TemplateParam
{
    string name;
    string type;
    string defaultValue;
    /// Template specialization (e.g. `T : int`).
    string spec;
    bool isVariadic;
}

/// A single entry from a `Params:` DDoc section.
struct ParamDoc
{
    string name;
    string description;
}

/// An entry in the generated search index.
struct SearchIndexEntry
{
    string qualifiedName;
    string name;
    string kind;
    string summary;
    string url;
}

/// A node in the type relationship graph.
struct TypeGraphNode
{
    string id;
    string label;
    string kind;
}

/// A directed edge in the type relationship graph.
struct TypeGraphEdge
{
    string from;
    string to;
    /// Relationship kind: `"extends"`, `"implements"`, `"aliases"`, `"has-part"`, or `"references"`.
    string type;
}

/// Directed graph of type relationships (inheritance, aliasing, composition).
struct TypeGraph
{
    TypeGraphNode[] nodes;
    TypeGraphEdge[] edges;
}
