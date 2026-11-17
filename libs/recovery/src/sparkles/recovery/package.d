/**
Crash-recovery storage over opaque payloads.

An application that must not lose unsaved work keeps a private archive
(`directory`): a leased directory of numbered, immutable generation files
(`archive`). A `CheckpointWriter` (`writer`) appends the latest observed
state in the background and acknowledges a revision only once it is durable;
maintenance tasks (`maintenance`) create the archive, prune it and find
abandoned archives to restore from. What a payload means is the caller's.
*/
module sparkles.recovery;

public import sparkles.recovery.archive;
public import sparkles.recovery.directory;
public import sparkles.recovery.maintenance;
public import sparkles.recovery.writer;
