/// What a generator returns, and what it is told (fileset explorer `FXE1`).
module sparkles.build_primitives.fileset.emit.result;

import sparkles.build_primitives.fileset.query : Span;

/// The systems a query can be written for.
enum Target : ubyte
{
    nix,         /// `lib.fileset` (`FXE3`)
    gitPathspec, /// `git ls-files` pathspecs (`FXE4`)
    gitignore,   /// a `.gitignore` (`FXE5`)
    rsync,       /// an rsync filter file (`FXE6`)
    tar,         /// a GNU tar command line (`FXE7`)
    cargo,       /// Cargo's `include` (`FXE8`)
    bazel,       /// a Bazel `glob` (`FXE9`)
    dub,         /// dub's `sourceFiles` (`FXE10`)
}

/// The target's name, as `--emit` takes it.
string targetName(Target t) @safe pure nothrow @nogc
{
    final switch (t)
    {
        case Target.nix: return "nix";
        case Target.gitPathspec: return "git-pathspec";
        case Target.gitignore: return "gitignore";
        case Target.rsync: return "rsync";
        case Target.tar: return "tar";
        case Target.cargo: return "cargo";
        case Target.bazel: return "bazel";
        case Target.dub: return "dub";
    }
}

/// How a glob reaches Nix, which has none (`FXE3`).
enum NixGlobs : ubyte
{
    shim,   /// a `glob` function the output defines, walking the root at evaluation
    expand, /// the paths the glob matches now: a snapshot
    refuse, /// only literal anchored paths
}

/// What a generator is told besides the query.
struct EmitOptions
{
    NixGlobs nixGlobs;  ///
    /// The paths a glob matches in the open directory now, for `NixGlobs.expand`.
    string[] delegate(string glob) @safe expand;
    /// The open directory is a git work tree with no untracked, unignored
    /// files and no ignored, tracked ones: `gitignored` is the root minus
    /// `gitTracked` (`FXE3`).
    bool gitignoredIsUntracked;
    /// The members, for a target that writes them out (`dub`, `FXE10`).
    const(string)[] members;
    /// The root's files Cargo packages whatever `include` says (`FXE8`):
    /// `Cargo.toml`, and a `README.md`, `README.txt` or `README` it finds.
    const(string)[] cargoAlways;
}

/// The code for a target, or why the target cannot express the query.
struct Emitted
{
    bool ok;       ///
    string code;   /// when `ok`
    string reason; /// when not
    Span span;     /// the refused construct's bytes in the query
}

/// A refusal: `reason`, about the bytes `span`.
Emitted refuse(string reason, Span span) @safe pure nothrow @nogc => Emitted(false, null, reason, span);
