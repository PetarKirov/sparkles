/**
The one guard for DMD's process-wide state.

DMD's lexer adds every identifier it reads to a process-wide table
(`Identifier.stringtable`), and recognizes `__EOF__`, `__DATE__` and `#line`
by comparing against the `dmd.id.Id` globals, which are null until
`Id.initialize()` runs. Neither is safe to touch from two threads at once.
So every use of DMD's frontend in a process runs inside $(LREF withDmdGlobals):
it holds one lock, and initializes the identifiers the first time.

`sparkles:dmd-fmt` and `sparkles:dmd-lsp` keep locks of their own for now. A
process that links one of them and uses this package too must not lex on two
threads through the two locks at once.
*/
module sparkles.d_source.dmd_globals;

private __gshared Object lock;
private __gshared bool identifiersReady;

shared static this()
{
    lock = new Object;
}

/// Runs `work` holding the lock, with DMD's identifiers initialized.
void withDmdGlobals(scope void delegate() @system work) @system
{
    synchronized (lock)
    {
        if (!identifiersReady)
        {
            import dmd.id : Id;

            Id.initialize();
            identifiersReady = true;
        }
        work();
    }
}
