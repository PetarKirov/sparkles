module sparkles.build_primitives;

public import sparkles.build_primitives.gitignore :
    GitIgnore,
    GitIgnoreRule,
    GitIgnoreStack,
    IgnoreMatch;
public import sparkles.build_primitives.dir_walk :
    walkDir,
    dirEntriesFilter,
    walkGitRepository,
    readRepositoryGitIgnore,
    hasEnterDir,
    hasLeaveDir,
    hasIncludeFile,
    hasOnFile,
    NoopWalkHook,
    DirWalkerRange,
    GitRepositoryFilter;
