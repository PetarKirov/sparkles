# SQLAlchemy (Python)

The Python SQL toolkit and Object Relational Mapper, built as **two layers**: a standalone **Core** (a Python-object SQL expression language plus an `Engine`/`Connection`/pool stack that compiles typed constructs to per-dialect SQL) and, on top of it, a full **data-mapper ORM** whose `Session` is a [unit of work][orm] over an [identity map][orm] with per-attribute change tracking.

| Field              | Value                                                                                                                                           |
| ------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| Language           | Python (`requires-python >=3.10`; `asyncio` extra needs `greenlet>=1`)                                                                          |
| License            | MIT (`LICENSE`, "Copyright 2005-2026 SQLAlchemy authors and contributors")                                                                      |
| Repository         | [sqlalchemy/sqlalchemy][repo]                                                                                                                   |
| Documentation      | [sqlalchemy.org/docs][docs] · [Unified Tutorial][tut]                                                                                           |
| Category           | [Full ORM (data-mapper)][ladder] **plus** a [typed SQL builder][ladder] (Core) — the ORM is optional and layered on Core                        |
| Abstraction level  | Spans two [ladder][ladder] rungs: Core is a [typed query builder][ladder] / expression language; the ORM adds the full [data-mapper][orm] rung  |
| Query model        | Core [SQL expression language][qcm] — a Python-object AST compiled per-dialect — plus ORM criteria/method chains over the same constructs       |
| Effect/async model | [Blocking][effects] by default; [asyncio][effects] via `AsyncSession` / `create_async_engine` (a `greenlet`-bridged proxy over the sync engine) |
| Backends           | PostgreSQL, MySQL/MariaDB, SQLite, Oracle, MS SQL Server (first-party dialects; more via external dialect packages)                             |
| First release      | `0.1` ≈ 2006 (project begun ~2005 by Michael Bayer; web-attested — `LICENSE` copyright starts 2005)                                             |
| Latest version     | `2.1.0b4` (the pinned tree's `__version__`; `2.0` is the current stable line)                                                                   |

> [!NOTE]
> SQLAlchemy is this survey's data point for the **maximal, "give me all of SQL"**
> full ORM — and, uniquely, for a codebase where the ORM is a strict superset of a
> production-grade Core that is fully usable on its own. Where `Django ORM` and
> `ActiveRecord` are batteries-included [active-record][orm] frameworks that hide the
> "R", SQLAlchemy is a [data-mapper][orm] that insists on exposing it. It is the
> Python peer of `Hibernate`/JPA and `EF Core`. Terms below link to [concepts][concepts].

---

## Overview

### What it solves

SQLAlchemy gives Python two independent tools that share a compiler. The lower tool,
**Core**, is a full database abstraction layer: you describe tables and columns as
Python objects, build SQL as a tree of Python expressions, and a per-dialect compiler
renders that tree to a parameterized statement executed over a pooled `Connection`. The
upper tool, the **ORM**, maps your own classes to those tables and adds the enterprise
persistence patterns — identity map, unit of work, change tracking, relationship loading
— so that a graph of mutated Python objects is synchronized to the database on `commit()`.
Crucially the two are separable: you can use Core as a typed SQL builder and never touch
the ORM. The `README.rst` opens with the positioning line ([`README.rst`][readme]):

> _"SQLAlchemy is the Python SQL toolkit and Object Relational Mapper
> that gives application developers the full power and
> flexibility of SQL."_

The Core/ORM duality is stated as an explicit design goal, not an accident of layering
([`README.rst`][readme]):

> _"A Core SQL construction system and DBAPI
> interaction layer. The SQLAlchemy Core is
> separate from the ORM and is a full database
> abstraction layer in its own right, and includes
> an extensible Python-based SQL expression
> language, schema metadata, connection pooling,
> type coercion, and custom types."_

And the ORM is described in exactly the Fowler vocabulary this survey's [concepts][orm]
page uses ([`README.rst`][readme]):

> _"An industrial strength ORM, built
> from the core on the identity map, unit of work,
> and data mapper patterns. These patterns
> allow transparent persistence of objects
> using a declarative configuration system."_

### Design philosophy

SQLAlchemy's `README.rst` carries an unusually explicit philosophy manifesto; three of its
tenets define the library's character.

**The ORM must not hide the relational model.** Unlike active-record frameworks that
present rows as objects and stop there, SQLAlchemy treats "expose all of SQL" as a virtue
([`README.rst`][readme]):

> _"An ORM doesn't need to hide the "R". A relational
> database provides rich, set-based functionality
> that should be fully exposed."_

The corollary is that the developer, not the framework, owns the SQL. There is no query
the framework silently rewrites ([`README.rst`][readme]):

> _"With SQLAlchemy, there's no such thing as
> "the ORM generated a bad query" - you
> retain full control over the structure of
> queries, including how joins are organized,
> how subqueries and correlation is used, what
> columns are requested."_

**Don't use an ORM if you don't need one.** The Core-first structure is deliberate; the
manifesto tells you to reach for the lower layer when the ORM buys nothing
([`README.rst`][readme]):

> _"Don't use an ORM if the problem doesn't need one.
> SQLAlchemy consists of a Core and separate ORM
> component. The Core offers a full SQL expression
> language that allows Pythonic construction
> of SQL constructs that render directly to SQL
> strings for a target database…"_

**Never interpolate a literal.** Injection safety is a stated non-negotiable, folded
together with the plan-caching benefit of bound parameters ([`README.rst`][readme]):

> _"Never render a literal value in a SQL statement.
> Bound parameters are used to the greatest degree
> possible, allowing query optimizers to cache
> query plans effectively and making SQL injection
> attacks a non-issue."_

That last tenet is the spine of [Query construction & injection safety](#query-construction--injection-safety).

---

## Connection, pooling & resource lifetime

The Core runtime is three cooperating objects. An `Engine` is the top-level factory and
home of configuration; its docstring states the composition literally
([`lib/sqlalchemy/engine/base.py`][enginebase]):

> _"Connects a :class:`~sqlalchemy.pool.Pool` and
> :class:`~sqlalchemy.engine.interfaces.Dialect` together to provide a
> source of database connectivity and behavior."_

You build one with `create_engine(url)`, whose URL selects the **dialect** and the
DBAPI driver ([`lib/sqlalchemy/engine/create.py`][create]) — e.g.
`create_engine("postgresql+psycopg://scott:tiger@localhost/test")`. A `Connection` is a
single leased DBAPI connection and is explicitly **not** thread-safe
([`lib/sqlalchemy/engine/base.py`][enginebase]):

> _"The Connection object represents a single DBAPI connection checked out
> from the connection pool.…
> For the connection pool to properly manage connections, connections
> should be returned to the connection pool (i.e. `connection.close()`)
> whenever the connection is not in use."_

Pooling is built in, not bolted on. The default pool is `QueuePool`
([`lib/sqlalchemy/pool/impl.py`][poolimpl]):

> _"A :class:`_pool.Pool`
> that imposes a limit on the number of open connections.
> …
> :class:`.QueuePool` is the default pooling implementation used for
> all :class:`_engine.Engine` objects other than SQLite with a `:memory:`
> database."_

Pool sizing and health are `create_engine` keyword parameters: `pool_size` (default `5`),
`max_overflow`, `pool_timeout`, `pool_recycle` (default `-1`, no recycling), and
`pool_pre_ping` ([`lib/sqlalchemy/engine/create.py`][create]):

> _"`pool_pre_ping`: boolean, if True will enable the connection pool
> "pre-ping" feature that tests connections for liveness upon
> each checkout."_

Resource lifetime is **lexical, via context managers**, not a scoped effect: `with
engine.connect() as conn:` returns the connection to the pool on block exit, and `with
engine.begin() as conn:` wraps the block in a transaction (commit on success, roll back on
exception). This is the sync-Python analogue of the [scoped acquire/release][pool] the
effect systems in this survey encode in a type — SQLAlchemy leans on `__exit__` where
`ZIO`/`Effect` lean on `Scope`.

## Query construction & injection safety

This is the heart of Core, and the mechanism the whole ORM is built on. A SQL statement is
a **tree of Python objects**, not a string. You declare a table's structure once as a
`Table` in a `MetaData` collection, then compose `select()` / `insert()` / `update()` /
`delete()` constructs against it; the `select()` docstring is terse because the object it
returns is the substance ([`lib/sqlalchemy/sql/_selectable_constructors.py`][selconstr]):

> _"Construct a new :class:`_expression.Select`."_

```python
from sqlalchemy import MetaData, Table, Column, Integer, String, select, create_engine

metadata = MetaData()
users = Table(
    "users",
    metadata,
    Column("id", Integer, primary_key=True),
    Column("name", String(50)),
)

engine = create_engine("postgresql+psycopg://scott:tiger@localhost/test")

stmt = select(users).where(users.c.id == 5)   # a Select object — no SQL emitted yet
with engine.connect() as conn:
    for row in conn.execute(stmt):
        print(row.name)
```

Nothing touches the database while `stmt` is built; `select(users).where(...)` is inert
data, a `Select` object the `SQLCompiler` will later render. The compiler is dialect-aware
([`lib/sqlalchemy/sql/compiler.py`][compiler]):

> _"Base SQL and DDL compiler implementations.…
> :class:`.compiler.SQLCompiler` - renders SQL
> strings"_

so the same `Select` compiles to PostgreSQL, MySQL, SQLite, Oracle, or MS SQL text with
that dialect's placeholder style, quoting, and `LIMIT`/`TOP`/`RETURNING` idiom.

**Injection safety is structural and automatic.** The key move is that comparing a column
to a Python value does **not** interpolate — the operator overload coerces the right-hand
value into a `BindParameter`. `users.c.id == 5` builds a binary expression whose right
side is produced by `expr._bind_param(...)`
([`lib/sqlalchemy/sql/coercions.py`][coercions],
[`lib/sqlalchemy/sql/default_comparator.py`][comparator]): the literal `5` becomes a bound
parameter node in the AST, never SQL text, so a hostile value can change the query's data
but never its structure. This realizes the manifesto's "never render a literal value"
tenet mechanically — the "value channel" and the "SQL channel" are different node types.
`IN (...)` clauses use a late-bound **"expanding parameter"** that renders the bind set at
execution time ([`lib/sqlalchemy/engine/create.py`][create], deprecation note), so even
`WHERE id IN :ids` stays parameterized.

**The escape hatch stays parameterized too.** For literal SQL you reach for `text()`,
which is a first-class construct, not a string — its advantage over a bare string is
precisely that it still supports named bind parameters
([`lib/sqlalchemy/sql/_elements_constructors.py`][elemconstr]):

> _"The advantages :func:`_expression.text`
> provides over a plain string are
> backend-neutral support for bind parameters, per-statement
> execution options, as well as
> bind parameter and result-column typing behavior…"_

```python
from sqlalchemy import text

t = text("SELECT * FROM users WHERE id=:user_id")
result = connection.execute(t, {"user_id": 12})   # :user_id bound, not interpolated
```

The genuinely unsafe path — f-string-building a SQL string and executing it — is available
(Python allows it), but every idiomatic surface, `text()` included, pushes you toward
`:name`-style binds. The `ext.compiler` extension lets you teach the compiler entirely new
constructs when even Core's vocabulary runs out.

The ORM does **not** introduce a second query language: since SQLAlchemy 2.0 you build ORM
queries with the _same_ `select()` construct, passing mapped classes instead of `Table`s
(`select(User).where(User.name == "spongebob")`). The legacy `Query` object still exists
but is explicitly deprecated in favor of this unification
([`lib/sqlalchemy/orm/query.py`][query]):

> \_"ORM-level SQL construction object.
>
> .. legacy:: The ORM :class:`.Query` object is a legacy construct
> as of SQLAlchemy 2.0."\_

## Schema, migrations & code generation

SQLAlchemy supports both **code-first** and **database-first** schema definition, but
ships **no migration runner** — a deliberate division of labor.

**Code-first.** A `MetaData` collection of `Table` objects (Core) _is_ a schema; the same
structures generate `CREATE TABLE` statements via `metadata.create_all(engine)`. In the
ORM, the 2.0 **Declarative** style declares tables through typed class attributes: a
`Mapped[...]` annotation plus `mapped_column(...)` derives the column's SQL type and
nullability from the Python type ([`lib/sqlalchemy/orm/_orm_constructors.py`][ormconstr]):

> _"…normally used with explicit typing along with
> the :class:`_orm.Mapped` annotation type, where it can derive the SQL
> type and nullability for the column based on what's present within the
> :class:`_orm.Mapped` annotation."_

```python
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship
from sqlalchemy import ForeignKey

class Base(DeclarativeBase):
    pass

class User(Base):
    __tablename__ = "user_account"
    id: Mapped[int] = mapped_column(primary_key=True)     # NOT NULL, PK
    name: Mapped[str]                                      # NOT NULL from `int`/`str`
    nickname: Mapped[str | None]                           # NULL from Optional
    addresses: Mapped[list["Address"]] = relationship(back_populates="user")

class Address(Base):
    __tablename__ = "address"
    id: Mapped[int] = mapped_column(primary_key=True)
    email: Mapped[str]
    user_id: Mapped[int] = mapped_column(ForeignKey("user_account.id"))
    user: Mapped["User"] = relationship(back_populates="addresses")
```

`DeclarativeBase` is the typed 2.0 base ([`lib/sqlalchemy/orm/decl_api.py`][declapi]):

> _"Base class used for declarative class definitions.…
> so that declarative
> base classes may be constructed in such a way that is also recognized
> by :pep:`484` type checkers."_

**Database-first (reflection).** Core can read an existing database and materialize
`Table` objects from it — `Table("users", metadata, autoload_with=engine)`, or
`metadata.reflect(engine)` for the whole schema. The `autoload_with` parameter drives it
([`lib/sqlalchemy/sql/schema.py`][schema]):

> _"`autoload_with`: An :class:`_engine.Engine` or
> :class:`_engine.Connection` object…
> against one, with which this :class:`_schema.Table`
> object will be reflected."_

The `README.rst` frames reflection as a headline Core feature — "_Database schemas can be
"reflected" in one step into Python structures representing database metadata; those same
structures can then generate CREATE statements right back out_" ([`README.rst`][readme]).

**Migrations are a separate project.** SQLAlchemy Core has no versioned-migration runner;
`metadata.create_all` is create-only. Schema _evolution_ is handled by **Alembic**, a
standalone tool written by the same author (Michael Bayer) that consumes SQLAlchemy's
`MetaData` and diffs it against the live database to autogenerate migration scripts.
Alembic appears in this tree only as backward-compatibility comments (e.g. in
`util/topological.py` and `exc.py`), never as a dependency — confirming that migration is
out of scope for the library itself, in contrast to `Django ORM`, `EF Core`, and `Prisma`,
which bundle their own migration engines.

## Type mapping & result decoding

Every SQL datatype descends from one root ([`lib/sqlalchemy/sql/type_api.py`][typeapi]):

> \_"The ultimate base class for all SQL datatypes.
>
> Common subclasses of :class:`.TypeEngine` include
> :class:`.String`, :class:`.Integer`, and :class:`.Boolean`."\_

A `TypeEngine` owns both directions of the [codec][typemap]: a **bind processor** encodes a
Python value into a driver parameter, and a **result processor** decodes a result cell back
into a Python value. Types are composable and extensible — you subclass `TypeDecorator` to
wrap an existing type (e.g. store an enum as a string), and dialects add engine-specific
types (`postgresql.JSONB`, `postgresql.ARRAY`, `UUID`). Because Core knows each column's
type, it can coerce parameters and typed result columns even for raw `text()` statements
via `.columns(...)`.

**Nullability rides the Python type.** In Declarative, `Mapped[int]` maps to a `NOT NULL`
column and `Mapped[str | None]` (i.e. `Optional[str]`) to a nullable one — the `Mapped`
annotation is read to set both SQL type and `nullable`. **Row hydration** differs by layer:
Core returns lightweight `Row` objects (enhanced named tuples, accessible by column
name/index), while the ORM hydrates whole **entity instances**, populating attributes and
wiring relationships, with the identity map guaranteeing one instance per primary key
(below).

## Effect model, transactions & error handling

This is the survey's most-weighted dimension, and where SQLAlchemy's full-ORM machinery —
and its trade-offs — live.

**Blocking by default; asyncio as a `greenlet`-bridged proxy.** Core and the ORM are
synchronous: `conn.execute(...)`, `session.commit()` block the calling thread. Async is an
extension (`sqlalchemy.ext.asyncio`): `create_async_engine` and `AsyncSession` expose
`await`-able methods over an asyncio DBAPI driver (`asyncpg`, `aiomysql`/`asyncmy`,
`aiosqlite`) ([`lib/sqlalchemy/ext/asyncio/engine.py`][asyncengine]):

> _"Create a new async engine instance.…
> The specified dialect must be an asyncio-compatible dialect
> such as :ref:`dialect-postgresql-asyncpg`."_

`AsyncSession` is explicitly a thin wrapper, not a reimplementation
([`lib/sqlalchemy/ext/asyncio/session.py`][asyncsession]):

> \_"Asyncio version of :class:`_orm.Session`.
>
> The :class:`_asyncio.AsyncSession` is a proxy for a traditional
> :class:`_orm.Session` instance."\_

The bridge is `greenlet`: async methods call `greenlet_spawn(...)` to run the underlying
synchronous engine code and yield to the event loop at the driver boundary
([`lib/sqlalchemy/ext/asyncio/engine.py`][asyncengine]) — which is why `asyncio` requires
`greenlet>=1`. This is a plain `async`/`await` future (an awaitable), **not** an effect
value in the [effect-system][effects] sense: there is no `IO`/`ZIO`/`Effect` describing the
work and its errors, and no typed error channel — failures are raised as exceptions.

**The `Session` is a unit of work over an identity map.** A `Session` accumulates the
objects you create, modify, and delete, and works out the SQL to persist them. Its own
docstring is spare — "_Manages persistence operations for ORM-mapped objects_" — and, like
`Connection`, it is single-threaded ([`lib/sqlalchemy/orm/session.py`][session]):

> _"The :class:`_orm.Session` is **not safe for use in concurrent threads.**"_

The **identity map** is a first-class attribute: one primary key ↦ one instance, per
session ([`lib/sqlalchemy/orm/session.py`][session]):

> \_"A mapping of object identities to objects themselves.
>
> Iterating through `Session.identity_map.values()` provides
> access to the full set of persistent objects (i.e., those
> that have row identity) currently in the session."\_

so loading the same row twice returns the _same_ Python object, and edits cannot diverge.
You stage work with `session.add(instance)` — "_Place an object into this
:class:`_orm.Session`_", moving it from transient to pending
([`lib/sqlalchemy/orm/session.py`][session]) — and persistence happens on **flush**, which
computes the ordered batch ([`lib/sqlalchemy/orm/session.py`][session]):

> _"Writes out all pending object creations, deletions and modifications
> to the database as INSERTs, DELETEs, UPDATEs, etc. Operations are
> automatically ordered by the Session's unit of work dependency
> solver."_

That dependency solver is the `unitofwork` module, which topologically sorts flush tasks so
that, e.g., a parent row is inserted before the child that references it
([`lib/sqlalchemy/orm/unitofwork.py`][uow]):

> _"The session's flush() process passes objects to a contextual object
> here, which assembles flush tasks based on mappers and their properties,
> organizes them in order of dependency, and executes."_

```python
from sqlalchemy.orm import Session

with Session(engine) as session:
    spongebob = User(name="spongebob")
    spongebob.addresses.append(Address(email="spongebob@sqlalchemy.org"))
    session.add(spongebob)         # pending — no SQL yet
    session.commit()               # flush: INSERT user, then INSERT address (dep-ordered), then COMMIT
```

**Change tracking is per-attribute snapshotting.** The mediator between a class and its
table is the `Mapper` — "_Defines an association between a Python class and a database
table…_" ([`lib/sqlalchemy/orm/mapper.py`][mapper]) — and per-instance bookkeeping lives in
`InstanceState`, "_Tracks state information at the instance level_"
([`lib/sqlalchemy/orm/state.py`][state]). Instrumented attributes record their loaded value
in `committed_state`; the set of dirty attributes is exactly those that diverge from that
snapshot ([`lib/sqlalchemy/orm/state.py`][state]):

> _"Return the set of keys which have no uncommitted changes"_

— computed as `set(self.manager).difference(self.committed_state)`. So a flush emits
`UPDATE` for **only** the columns that actually changed, without you enumerating them.

**Transactions and savepoints.** `commit()` is flush-then-commit, and it eagerly _expires_
loaded objects afterward — a documented implicit behavior that is a real foot-gun and is
toggleable ([`lib/sqlalchemy/orm/session.py`][session]):

> \_"Flush pending changes and commit the current transaction.
>
> When the COMMIT operation is complete, all objects are fully
> :term:`expired`, erasing their internal contents, which will be
> automatically re-loaded when the objects are next accessed.…
> this re-load operation is not supported when using asyncio-oriented
> APIs. The :paramref:`.Session.expire_on_commit` parameter may be used
> to disable this behavior."\_

Nesting uses [savepoints][effects] ([`lib/sqlalchemy/orm/session.py`][session]):

> \_"Begin a "nested" transaction on this Session, e.g. SAVEPOINT.
>
> The target database(s) and associated drivers must support SQL
> SAVEPOINT for this method to function correctly."\_

so `session.begin_nested()` opens a `SAVEPOINT` whose rollback discards only the inner work;
the outer transaction survives, and `commit()` "_automatically releasing any SAVEPOINTs in
effect_" ([`lib/sqlalchemy/orm/session.py`][session]).

**Errors are exceptions, not a typed channel.** SQLAlchemy raises from a hierarchy rooted at
`SQLAlchemyError` (`sqlalchemy.exc`): `IntegrityError`, `OperationalError`,
`ProgrammingError`, etc., wrapping the DBAPI's own exceptions (the Python DBAPI/PEP-249
exception classes). There is no `Result`/`Either` return type and no per-query error set —
the [typed-error-channel][effects] posture the functional mappers (`doobie`, `skunk`,
`Effect TS`) adopt is absent; SQLAlchemy is squarely in the exception-based mainstream
alongside JDBC and ADO.NET.

**Relationship loading strategies — the N+1 axis.** A `relationship()` is lazy by default,
which is the classic [N+1][nplusone] trap; the fix is to pick an eager strategy, per-mapping
via `lazy=` or per-query via loader options. The `lazy=` parameter enumerates the menu
([`lib/sqlalchemy/orm/_orm_constructors.py`][ormconstr]):

> _"`select` - items should be loaded lazily when the property is
> first accessed, using a separate SELECT statement, or identity map
> fetch for simple many-to-one references."_
>
> _"`joined` - items should be loaded "eagerly" in the same query as
> that of the parent, using a JOIN or LEFT OUTER JOIN."_
>
> _"`selectin` - items should be loaded "eagerly" as the parents
> are loaded, using one or more additional SQL statements, which
> issues a JOIN to the immediate parent object, specifying primary
> key identifiers using an IN clause."_

The same choices are available per query as loader options `joinedload()` and
`selectinload()` ([`lib/sqlalchemy/orm/strategy_options.py`][strategyopts]) — the latter is
the modern default recommendation for collections, since it batches all parents into a
single `WHERE id IN (...)` follow-up query rather than one query per parent:

```python
from sqlalchemy.orm import selectinload

# one SELECT for users, then ONE "IN (...)" SELECT for all their addresses — not N
stmt = select(User).options(selectinload(User.addresses))
users = session.scalars(stmt).all()
```

The strategy also includes hard guards for detached-object safety: `lazy="raise"` /
`lazy="raise_on_sql"` turn an accidental lazy load into an `InvalidRequestError` instead of
a silent extra query ([`lib/sqlalchemy/orm/_orm_constructors.py`][ormconstr]) — the standard
way to make the N+1 foot-gun _fail loudly_, which matters most under `AsyncSession`, where
an implicit lazy load cannot emit SQL at all.

## Ecosystem & maturity

SQLAlchemy is one of the oldest and most-depended-upon libraries in Python — begun ~2005 by
**Michael Bayer**, `0.1` shipped ≈ 2006 (web-attested; the `LICENSE` copyright runs from
2005), and it has been the de-facto Python ORM for two decades. It is **MIT**-licensed
([`LICENSE`][license]), targets `Python >=3.10`, and the pinned tree carries
`__version__ = "2.1.0b4"` — a beta on top of the stable `2.0` line whose signature change
was typed Declarative (`Mapped[...]`) and the unified `select()` API. First-party
**dialects** cover PostgreSQL (drivers `psycopg`, `psycopg2`, `asyncpg`, `pg8000`), MySQL /
MariaDB (`mysqldb`, `pymysql`, `aiomysql`, `asyncmy`), SQLite (`pysqlite`, `aiosqlite`),
Oracle (`cx_oracle`, `oracledb`), and MS SQL Server (`pyodbc`, `pymssql`); many more
databases are reachable through externally maintained dialect packages
([`lib/sqlalchemy/dialects/`][dialects]).

The surrounding ecosystem is large: **Alembic** (migrations, same author), **SQLModel**
(Pydantic + SQLAlchemy, by the FastAPI author) and the Flask-SQLAlchemy / GeoAlchemy
integrations sit on top; it is the storage layer under a very large fraction of Python web
services. Its own extensions (`ext.hybrid`, `ext.associationproxy`, `ext.mutable`,
`ext.automap`, `ext.compiler`) show the "open-ended set of patterns" philosophy in
practice.

## Strengths

- **Two tools, one compiler.** A production-grade Core SQL builder that is fully usable
  without the ORM, plus an ORM that reuses every Core construct — you choose the abstraction
  level per query ([`README.rst`][readme]).
- **Injection-safe by construction.** Column-vs-value comparisons coerce literals into
  `BindParameter` nodes; `text()` keeps `:name` binds; `IN` uses expanding parameters — the
  "never render a literal" tenet is mechanical ([`sql/coercions.py`][coercions]).
- **Full unit of work + identity map.** `session.commit()` computes a dependency-ordered
  INSERT/UPDATE/DELETE batch; one PK ↦ one instance; `UPDATE` touches only changed columns
  ([`orm/unitofwork.py`][uow], [`orm/state.py`][state]).
- **First-class loading strategies.** `joined`, `selectin`, `subquery`, plus `raise`/
  `raise_on_sql` guards, chosen per-mapping or per-query — a complete answer to N+1
  ([`orm/strategy_options.py`][strategyopts]).
- **Code-first _and_ db-first.** Declarative `Mapped[...]` mappings or one-step `reflect()`
  of a live schema ([`sql/schema.py`][schema]).
- **Broadest dialect coverage** among the surveyed ORMs, each with multiple sync/async
  drivers ([`dialects/`][dialects]).
- **Typed 2.0 API.** `Mapped[...]` + `mapped_column` are PEP-484-legible, so `mypy`/IDEs see
  attribute types ([`orm/decl_api.py`][declapi]).

## Weaknesses

- **Enormous surface.** Two full stacks (Core + ORM), a huge type system, and many
  extensions — the learning curve is the steepest in this survey.
- **Implicit flush / expire semantics.** Autoflush before queries and `expire_on_commit`
  re-loading objects after `commit()` are convenient but surprising, and the expire path is
  "_not supported when using asyncio-oriented APIs_" ([`orm/session.py`][session]).
- **Lazy-load N+1 is the default.** A `relationship()` is `lazy="select"` unless you opt
  into eager loading; the trap is real, and only `raise`/`raise_on_sql` make it loud
  ([`orm/_orm_constructors.py`][ormconstr]).
- **Async is a `greenlet` proxy, not native.** `AsyncSession` re-drives the synchronous
  engine under a greenlet; there is no effect value or typed error channel, and lazy loads
  are outright unavailable in async ([`ext/asyncio/`][asyncsession]).
- **Exception-based errors.** No `Result`/typed error set; failures are raised from
  `sqlalchemy.exc`, unlike the functional mappers this survey weights.
- **Mutable-object model.** The ORM's identity map + change tracking rely on shared mutable
  state that is deliberately single-threaded — the opposite of the immutable, value-oriented
  designs (`Ecto`, `doobie`) the survey studies.

## Key design decisions and trade-offs

| Decision                                                         | Rationale                                                                              | Trade-off                                                                                                     |
| ---------------------------------------------------------------- | -------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| Core and ORM as **separate, layered** components                 | Use raw SQL power when the ORM buys nothing; ORM reuses every Core construct           | Two large APIs to learn; where a behavior lives (Core vs ORM) is not always obvious                           |
| Query = a **Python-object AST**, compiled per dialect at runtime | Multi-backend from one query; inspectable; extensible via `ext.compiler`               | No compile-time SQL verification (unlike `Diesel`/`jOOQ` codegen); typos surface at execution                 |
| Literals coerce to `BindParameter`, never interpolated           | Injection impossible for values; plan caching; "never render a literal value"          | You must reach _deliberately_ for the unsafe path (f-string SQL); `text()` still needs explicit `:name` binds |
| `Session` = unit of work over an identity map + change tracking  | Transparent persistence: mutate objects, `commit()` computes the minimal ordered batch | Implicit autoflush/expire semantics; shared mutable state; strictly single-threaded                           |
| `relationship()` **lazy by default**, eager strategies opt-in    | Convenience; you load only what you touch                                              | Classic N+1 unless you add `selectinload`/`joinedload`; safety needs `raise`/`raise_on_sql`                   |
| Blocking core; asyncio via a **`greenlet`** proxy                | One implementation serves both; async added without forking the ORM                    | Not a native async/effect design; no typed error channel; lazy loads unavailable under `AsyncSession`         |
| **No migration runner** in-tree (delegated to Alembic)           | Keep the library focused on access + schema _description_; Alembic owns _evolution_    | Schema evolution is a second tool to adopt (though same author, tight integration)                            |
| Errors as **exceptions** from `sqlalchemy.exc`                   | Idiomatic Python; wraps DBAPI/PEP-249 exceptions directly                              | No `Result`/typed error set; failure handling is `try/except`, not encoded in the type                        |

---

## Sources

- [sqlalchemy/sqlalchemy — GitHub repository][repo] · [sqlalchemy.org/docs][docs] · [Unified Tutorial][tut]
- [`README.rst` — positioning ("Python SQL toolkit and Object Relational Mapper"), the Core/ORM duality, the philosophy manifesto (hide the "R", don't use an ORM if you don't need one, never render a literal value), reflection][readme]
- [`LICENSE` — MIT, "Copyright 2005-2026 SQLAlchemy authors and contributors"][license]
- [`lib/sqlalchemy/engine/base.py` — `Engine` ("connects a Pool and Dialect"), `Connection` (single DBAPI conn, not thread-safe)][enginebase]
- [`lib/sqlalchemy/engine/create.py` — `create_engine`; `pool_size`/`max_overflow`/`pool_recycle`/`pool_pre_ping`; expanding-parameter `IN`][create]
- [`lib/sqlalchemy/pool/impl.py` — `QueuePool` default pool][poolimpl] · [`lib/sqlalchemy/pool/base.py` — `Pool` base][poolbase]
- [`lib/sqlalchemy/sql/_selectable_constructors.py` — `select()` → `Select`][selconstr]
- [`lib/sqlalchemy/sql/compiler.py` — `SQLCompiler` renders per-dialect SQL][compiler]
- [`lib/sqlalchemy/sql/coercions.py` + `default_comparator.py` — literal → `BindParameter` coercion (injection safety)][coercions]
- [`lib/sqlalchemy/sql/_elements_constructors.py` — `text()` keeps `:name` binds][elemconstr]
- [`lib/sqlalchemy/sql/type_api.py` — `TypeEngine`, the root SQL datatype][typeapi]
- [`lib/sqlalchemy/sql/schema.py` — `Table`/`Column`/`MetaData`, `autoload_with` reflection][schema]
- [`lib/sqlalchemy/orm/session.py` — `Session` (unit of work), `identity_map`, `add`/`flush`/`commit`/`begin_nested` (SAVEPOINT), `expire_on_commit`][session]
- [`lib/sqlalchemy/orm/unitofwork.py` — dependency-sorted flush][uow]
- [`lib/sqlalchemy/orm/mapper.py` — `Mapper` (class ↔ table)][mapper] · [`lib/sqlalchemy/orm/state.py` — `InstanceState`, `committed_state`, `unmodified`][state]
- [`lib/sqlalchemy/orm/_orm_constructors.py` — `relationship(lazy=...)` strategies, `mapped_column`/`Mapped`][ormconstr]
- [`lib/sqlalchemy/orm/strategy_options.py` — `joinedload` / `selectinload` loader options][strategyopts]
- [`lib/sqlalchemy/orm/decl_api.py` — `DeclarativeBase` (typed 2.0 mapping)][declapi] · [`lib/sqlalchemy/orm/query.py` — legacy `Query`][query]
- [`lib/sqlalchemy/ext/asyncio/` — `create_async_engine`, `AsyncSession` (greenlet-bridged proxy)][asyncsession] · [engine][asyncengine]
- [`lib/sqlalchemy/dialects/` — PostgreSQL/MySQL/SQLite/Oracle/MSSQL dialects + drivers][dialects]
- Shared vocabulary: [SQL & ORM concepts][concepts] ([abstraction ladder][ladder] · [query models][qcm] · [injection][inject] · [schema/migrations][schemaconcept] · [ORM patterns][orm] · [type mapping][typemap] · [N+1][nplusone] · [effects & transactions][effects] · [pools][pool])
- Related deep-dives in this survey: `Django ORM` · `Hibernate` · `EF Core` · `Prisma` · `SeaORM` · `Ecto` · `doobie`

<!-- References -->

[repo]: https://github.com/sqlalchemy/sqlalchemy
[docs]: https://www.sqlalchemy.org/docs/
[tut]: https://docs.sqlalchemy.org/en/20/tutorial/index.html
[readme]: https://github.com/sqlalchemy/sqlalchemy/blob/main/README.rst
[license]: https://github.com/sqlalchemy/sqlalchemy/blob/main/LICENSE
[enginebase]: https://github.com/sqlalchemy/sqlalchemy/blob/main/lib/sqlalchemy/engine/base.py
[create]: https://github.com/sqlalchemy/sqlalchemy/blob/main/lib/sqlalchemy/engine/create.py
[poolimpl]: https://github.com/sqlalchemy/sqlalchemy/blob/main/lib/sqlalchemy/pool/impl.py
[poolbase]: https://github.com/sqlalchemy/sqlalchemy/blob/main/lib/sqlalchemy/pool/base.py
[selconstr]: https://github.com/sqlalchemy/sqlalchemy/blob/main/lib/sqlalchemy/sql/_selectable_constructors.py
[compiler]: https://github.com/sqlalchemy/sqlalchemy/blob/main/lib/sqlalchemy/sql/compiler.py
[coercions]: https://github.com/sqlalchemy/sqlalchemy/blob/main/lib/sqlalchemy/sql/coercions.py
[comparator]: https://github.com/sqlalchemy/sqlalchemy/blob/main/lib/sqlalchemy/sql/default_comparator.py
[elemconstr]: https://github.com/sqlalchemy/sqlalchemy/blob/main/lib/sqlalchemy/sql/_elements_constructors.py
[typeapi]: https://github.com/sqlalchemy/sqlalchemy/blob/main/lib/sqlalchemy/sql/type_api.py
[schema]: https://github.com/sqlalchemy/sqlalchemy/blob/main/lib/sqlalchemy/sql/schema.py
[session]: https://github.com/sqlalchemy/sqlalchemy/blob/main/lib/sqlalchemy/orm/session.py
[uow]: https://github.com/sqlalchemy/sqlalchemy/blob/main/lib/sqlalchemy/orm/unitofwork.py
[mapper]: https://github.com/sqlalchemy/sqlalchemy/blob/main/lib/sqlalchemy/orm/mapper.py
[state]: https://github.com/sqlalchemy/sqlalchemy/blob/main/lib/sqlalchemy/orm/state.py
[ormconstr]: https://github.com/sqlalchemy/sqlalchemy/blob/main/lib/sqlalchemy/orm/_orm_constructors.py
[strategyopts]: https://github.com/sqlalchemy/sqlalchemy/blob/main/lib/sqlalchemy/orm/strategy_options.py
[declapi]: https://github.com/sqlalchemy/sqlalchemy/blob/main/lib/sqlalchemy/orm/decl_api.py
[query]: https://github.com/sqlalchemy/sqlalchemy/blob/main/lib/sqlalchemy/orm/query.py
[asyncsession]: https://github.com/sqlalchemy/sqlalchemy/blob/main/lib/sqlalchemy/ext/asyncio/session.py
[asyncengine]: https://github.com/sqlalchemy/sqlalchemy/blob/main/lib/sqlalchemy/ext/asyncio/engine.py
[dialects]: https://github.com/sqlalchemy/sqlalchemy/tree/main/lib/sqlalchemy/dialects
[concepts]: ./concepts.md
[ladder]: ./concepts.md#the-abstraction-ladder
[qcm]: ./concepts.md#query-construction-models
[inject]: ./concepts.md#statements-parameters-and-sql-injection
[schemaconcept]: ./concepts.md#schema-migrations-code-generation
[orm]: ./concepts.md#orm-patterns
[typemap]: ./concepts.md#type-mapping-and-result-decoding
[nplusone]: ./concepts.md#loading-strategies-and-the-n1-problem
[effects]: ./concepts.md#effects-transactions-and-error-handling
[pool]: ./concepts.md#connections-pools-and-sessions
