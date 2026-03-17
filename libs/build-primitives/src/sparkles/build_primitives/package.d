module sparkles.build_primitives;

public import sparkles.build_primitives.gitignore : GitIgnore, GitIgnoreRule;
public import sparkles.build_primitives.dir_walk :
    walkDir,
    dirEntriesFilter,
    walkGitRepository,
    readRepositoryGitIgnore,
    hasEnterDir,
    hasIncludeFile,
    hasOnFile,
    NoopWalkHook,
    DirWalkerRange,
    GitRepositoryFilter;
