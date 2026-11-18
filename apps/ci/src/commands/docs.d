/// `ci docs`: the fence audit. `ci docs stage-wasm` is `docs_wasm.d`'s.
module commands.docs;

import cli : FileSelection;
import commands.files : selectedFiles;
import fence_audit : AuditScope, FenceAuditOptions, runFenceAudit;
import sparkles.core_cli.args : RunExpected;
import std.algorithm : filter;
import std.array : array;
import std.string : endsWith;

/// `ci docs fences-audit`. `--include-files` selectors override the default
/// `docs/**/*.md` + `README.md` set; globs resolve through `git ls-files` in
/// the current directory, so combine them with `--root` only when the two
/// agree.
RunExpected!void runAuditFencesCommand(in FileSelection files, string json, string root,
    AuditScope auditScope)
{
    return runFenceAudit(FenceAuditOptions(
        root: root,
        files: selectedFiles(files.include).filter!(path => path.endsWith(".md")).array,
        jsonPath: json,
        auditScope: auditScope,
    ));
}
