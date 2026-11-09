/**
Content addressing: names for a fileset's tree and its files, computed by
schemes on the fileset seam (FSS1–FSS8).

`MerkleFold` is the shell; `castore` is the default identity, and `git`
names trees as git does; `outboard` is iroh's supplied tree of a file.
Decided in
`docs/specs/build-primitives/filesets/decisions.md`, A19.
*/
module sparkles.build_primitives.content_addressing;

public import sparkles.build_primitives.content_addressing.castore;
public import sparkles.build_primitives.content_addressing.git;
public import sparkles.build_primitives.content_addressing.merkle;
public import sparkles.build_primitives.content_addressing.nar;
public import sparkles.build_primitives.content_addressing.outboard;
