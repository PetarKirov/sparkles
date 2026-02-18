module doc_coverage.game.systems;

import doc_coverage.game.entities : IEntity, PlayerEntity;

/// Alias to exercise alias symbol generation.
alias EntityRef = IEntity;

/// Template mixin-style system runner.
///
/// Examples:
/// ---
/// auto out = runSystem!TickSystem(3);
/// assert(out == 6);
/// ---
int runSystem(SystemT)(int ticks)
if (is(SystemT == TickSystem))
{
    SystemT s;
    return s.step(ticks);
}

/// Stateless tick system.
struct TickSystem
{
    int step(int ticks) const
    {
        return ticks * 2;
    }
}

/// Creates a player entity as interface alias type.
EntityRef spawnEntity(int id)
{
    return new PlayerEntity(id);
}

@("docCoverage.game.systems.runSystem")
@safe
unittest
{
    assert(runSystem!TickSystem(5) == 10);
}
