module doc_coverage.core.commands;

import doc_coverage.mixed.types : PlayerId;

/// Command categories used by both CLI and gameplay systems.
enum CommandKind
{
    none,
    move,
    render,
    quit,
}

/// Alias used by parser coverage tests.
alias CommandName = string;

/// Global command count exposed for documentation.
int publicCommandCount;
private int privateCommandCount;
package int packageCommandCount;
export int exportedCommandCount;

/// Interface for executable commands.
interface ICommand
{
    string name() const;
    int execute(ref CommandContext ctx) const;
}

/// Context passed to command execution.
///
/// Examples:
/// ---
/// CommandContext ctx = CommandContext(PlayerId(7), "ready");
/// assert(ctx.activePlayer.value == 7);
/// ---
struct CommandContext
{
    PlayerId activePlayer;
    string mode;

    this(PlayerId activePlayer, string mode)
    {
        this.activePlayer = activePlayer;
        this.mode = mode;
    }

    this(this)
    {
        mode = mode ~ " (copy)";
    }

    invariant()
    {
        assert(mode.length > 0);
    }

    ~this()
    {
    }
}

/// Base class with multiple protection levels for member docs.
class CommandBase : ICommand
{
    protected string prefix;
    private int localCounter;
    package int packageVisibleCounter;
    public string title;

    this(string title)
    {
        this.title = title;
        this.prefix = "cmd";
    }

    ~this()
    {
    }

    override string name() const
    {
        return prefix ~ ":" ~ title;
    }

    override int execute(ref CommandContext ctx) const
    {
        return cast(int) ctx.mode.length;
    }

    protected int bump(ref CommandContext ctx)
    {
        localCounter++;
        packageVisibleCounter += localCounter;
        return localCounter + cast(int) ctx.mode.length;
    }
}

/// Concrete command implementation.
///
/// Example:
/// ---
/// auto cmd = new MoveCommand("north");
/// CommandContext ctx = CommandContext(PlayerId(1), "play");
/// assert(cmd.execute(ctx) > 0);
/// ---
class MoveCommand : CommandBase
{
    this(string direction)
    {
        super(direction);
    }

    override int execute(ref CommandContext ctx) const
    {
        return cast(int) title.length + super.execute(ctx);
    }
}

/// Creates a command by kind.
ICommand createCommand(CommandKind kind)
{
    final switch (kind)
    {
        case CommandKind.none: return new MoveCommand("idle");
        case CommandKind.move: return new MoveCommand("north");
        case CommandKind.render: return new MoveCommand("render");
        case CommandKind.quit: return new MoveCommand("quit");
    }
}

/// Exported function used to test `export` protection serialization.
export int exportedApi(int value)
{
    return value + 1;
}

@("docCoverage.core.commands.createCommand")
@safe
unittest
{
    CommandContext ctx = CommandContext(PlayerId(4), "play");
    auto cmd = createCommand(CommandKind.move);
    assert(cmd.execute(ctx) > 0);
}
