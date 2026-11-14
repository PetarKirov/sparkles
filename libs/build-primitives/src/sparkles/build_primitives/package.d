/**
Build-system and VCS primitives. Filesets — values naming sets of files, and
their resolution against a file system — replace the `.gitignore` walkers this
package used to export; `sparkles.build_primitives.fileset.listing` is the
entry point for an application that wants a directory's files.
*/
module sparkles.build_primitives;

public import sparkles.build_primitives.fileset;
