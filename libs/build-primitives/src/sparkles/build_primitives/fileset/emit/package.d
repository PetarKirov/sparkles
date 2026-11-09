/**
Code generators (fileset explorer `FXE1`–`FXE10`): a fileset query written for
another system — Nix's `lib.fileset`, git pathspecs, a `.gitignore`, rsync
filters, a GNU tar command line, Cargo's `include`, a Bazel `glob` and dub's
`sourceFiles` — exactly, or refused with the construct the system cannot
express and its place in the query.

Specified in `docs/specs/fileset-explorer/SPEC.md` §5.
*/
module sparkles.build_primitives.fileset.emit;

public import sparkles.build_primitives.fileset.emit.result;

import sparkles.build_primitives.fileset.emit.lists : emitBazel, emitCargo, emitDub, emitGitignore,
    emitGitPathspec, emitRsync, emitTar;
import sparkles.build_primitives.fileset.emit.nix : emitNix;
import sparkles.build_primitives.fileset.query : Query;

/// `q`, written for `t` (`FXE1`). `q` must have parsed.
Emitted emit(Target t, const Query q, in EmitOptions o = EmitOptions.init) @safe
in (q.ok)
{
    final switch (t)
    {
        case Target.nix: return emitNix(q, o);
        case Target.gitPathspec: return emitGitPathspec(q, o);
        case Target.gitignore: return emitGitignore(q, o);
        case Target.rsync: return emitRsync(q, o);
        case Target.tar: return emitTar(q, o);
        case Target.cargo: return emitCargo(q, o);
        case Target.bazel: return emitBazel(q, o);
        case Target.dub: return emitDub(q, o);
    }
}
