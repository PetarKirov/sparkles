module doc_coverage.game.entities;

/// Basic interface for game entities.
interface IEntity
{
    int id() const;
}

/// Public enum for state coverage.
enum EntityState
{
    idle,
    moving,
    disabled,
}

/// Entity base class with protected and private members.
class EntityBase : IEntity
{
    protected int _id;
    private EntityState _state;

    this(int id)
    {
        _id = id;
        _state = EntityState.idle;
    }

    override int id() const
    {
        return _id;
    }

    EntityState state() const
    {
        return _state;
    }

    void setState(EntityState next)
    {
        _state = next;
    }
}

/// Concrete entity class.
class PlayerEntity : EntityBase
{
    this(int id)
    {
        super(id);
    }

    void move()
    {
        setState(EntityState.moving);
    }
}

@("docCoverage.game.entities.playerMove")
@safe
unittest
{
    auto p = new PlayerEntity(42);
    p.move();
    assert(p.state() == EntityState.moving);
}
