/**
The members a fileset selects from a tree, their names, and copying them
(docs/specs/fsx): the engine `fsx` and the fileset explorer share.

`evaluate` resolves a query over a source and names its members; `copy`
writes them elsewhere through the capability VFS; `stats` is the report the
explorer's Stats tab and `fsx --stats` print.
*/
module sparkles.fileset_tools;

public import sparkles.fileset_tools.commands;
public import sparkles.fileset_tools.copy;
public import sparkles.fileset_tools.evaluate;
public import sparkles.fileset_tools.iroh_source;
public import sparkles.fileset_tools.source;
public import sparkles.fileset_tools.stats;
public import sparkles.fileset_tools.verify;
