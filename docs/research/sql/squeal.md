# Squeal (Haskell / PostgreSQL)

A deeply-typed PostgreSQL EDSL for Haskell in which the **database schema is a type**: tables, columns, nullability, and constraints are encoded at the type level, queries and DML are type-checked against that schema, and the session monad is _indexed by the schema before and after_ — so a migration literally changes the type.

| Field              | Value                                                                                                                                       |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------- |
| Language           | Haskell (GHC; leans hard on `DataKinds`, `TypeFamilies`, `GADTs`, `PolyKinds`, `OverloadedLabels`)                                          |
| License            | BSD-3-Clause — [`squeal-postgresql/LICENSE`][license] (© 2017 Morphism, LLC), `license: BSD-3-Clause` in [`squeal-postgresql.cabal`][cabal] |
| Repository         | [morphismtech/squeal][repo]                                                                                                                 |
| Documentation      | [Hackage haddocks][hackage] · [Stackage][stackage] · in-repo [Core Concepts Handbook][handbook]                                             |
| Category           | [Typed query builder][ladder] with a **type-level Postgres schema** (shading into a [functional data mapper][ladder])                       |
| Abstraction level  | Typed query builder / functional data mapper — above a driver, below a full ORM ([ladder][ladder])                                          |
| Query model        | [Typed relational algebra][qmodels] over a [type-level schema / phantom types][qmodels] (`Query`/`Expression`/`Manipulation`)               |
| Effect/async model | The `PQ` **indexed monad transformer** over `IO` — an Atkey indexed monad whose two schema indices track schema change ([effects][effects]) |
| Backends           | **PostgreSQL only** — built directly on `postgresql-libpq` + `postgresql-binary` (not `hasql`)                                              |
| First release      | ≈2017 (web-soft; LICENSE © 2017)                                                                                                            |
| Latest version     | `0.9.2.0` ([`squeal-postgresql.cabal`][cabal]); date web-soft                                                                               |

> [!NOTE]
> Squeal is this survey's data point for the **deep-static extreme** of the [typed-query-builder][ladder]
> rung. Where `jOOQ`/`Kysely`/`Diesel` type-check column and result shapes, Squeal reifies the _whole_
> Postgres schema — every table, column, nullability flag, and constraint — as a
> [type-level value][qmodels], and threads that schema through an **indexed monad** so a `CREATE`/`ALTER`/`DROP`
> is a change of type. It is the closest Haskell sibling to `Opaleye` and `Beam` on the construction axis,
> and it parallels `hasql`'s `Statement` profunctor for encode/decode while building _on_ `libpq`
> rather than on `hasql`.

---

## Overview

### What it solves

Squeal is a full embedding of PostgreSQL's SQL surface — not just `SELECT`, but the data-manipulation
and data-definition languages too. Its README enumerates the scope
([`README.md`][readme]): _"Squeal embeds not just the structured query language of SQL but also the
data manipulation language and the data definition language; that's `SELECT`, `INSERT`, `UPDATE`,
`DELETE`, `WITH`, `CREATE`, `DROP`, and `ALTER` commands."_ Every one of those commands is a Haskell
value whose _type_ records exactly which schema it targets and what it produces.

The point of that machinery is a query that cannot lie about the database. A `SELECT` that names a
column the table does not have, compares two incompatible Postgres types, or forgets to `GROUP BY`
before aggregating is a **compile error**, not a runtime `SQLException`. The
[Core Concepts Handbook][handbook] frames the whole library as a handful of familiar SQL-shaped types
carrying unfamiliar type parameters ([`squeal-core-concepts-handbook.md`][handbook]):

> _"At its core, you can view Squeal as a small group of easy-to-understand types (`Query`,
> `Manipulation`, `Statement`, `Expression`, `FromClause`, and `TableExpression`) that have
> hard-to-understand type parameters (`Expression grouping lat with db params from ty`). The former map
> to your existing understanding of SQL in a fairly obvious way; the latter make sure that your queries
> are actually valid."_

### Design philosophy

Squeal's defining commitment, in its author's own words, is a **deep embedding** at both levels of the
language ([`README.md`][readme]):

> _"Squeal is a deep embedding of SQL into Haskell. By \"deep embedding\", I am abusing the term
> somewhat. What I mean is that Squeal embeds both SQL terms and SQL types into Haskell at the term and
> type levels respectively. This leads to a very high level of type-safety in Squeal."_

The second commitment is **predictable SQL**. Squeal is not an optimizer or a query planner; a
combinator renders to the SQL you would expect, and nothing rewrites it ([`README.md`][readme]):
_"Squeal expressions closely match their corresponding SQL expressions so that the SQL they actually
generate is completely predictable. They are also highly composable and cover a large portion of SQL."_
The README demonstrates this by round-tripping a `createTable` through `printSQL` and observing the
output is _"unsurprising looking"_ ([`README.md`][readme]). This is a real architectural choice: unlike
`Slick`'s multi-phase query compiler, Squeal has **no reified AST and no rendering pipeline** — each
`Query`/`Expression`/`Manipulation` is a phantom-typed wrapper around an already-rendered
`ByteString`, and all the safety lives in the type parameters (see [Query construction](#query-construction-injection-safety)).

The trade-off Squeal accepts for this is verbosity and type complexity, and it says so. A community
presentation puts the bargain bluntly ([`squeal-presentation-raveline.md`][raveline]): _"you need
verbosity to get type safety."_ The handbook agrees the type parameters are _"the most complicated part
of learning to use Squeal"_ ([`squeal-core-concepts-handbook.md`][handbook]).

---

## Connection, pooling & resource lifetime

A Squeal application runs inside `PQ` over a single `libpq` connection. The lowest-level runner is
`withConnection`, a `bracket` around `connectdb`/`finish` ([`Session.hs`][session]):

```haskell
-- squeal-postgresql/src/Squeal/PostgreSQL/Session.hs
withConnection
  :: forall db0 db1 io x. (MonadIO io, MonadMask io)
  => ByteString
  -> PQ db0 db1 io x
  -> io x
withConnection connString action =
  unK <$> bracket (connectdb connString) finish (unPQ action)
```

Because the acquire/release is a `bracket`, a leaked connection is prevented structurally rather than by
a `finally` a caller might forget. For concurrent workloads, `Squeal.PostgreSQL.Session.Pool` wraps the
`resource-pool` library. `createConnectionPool` builds a striped pool keyed on the schema
(`Pool (K Connection db)`), and `usingConnectionPool` leases one connection for a `PQ db db io x` session,
masking exceptions so a broken connection is destroyed rather than returned
([`Session/Pool.hs`][pool]):

```haskell
-- squeal-postgresql/src/Squeal/PostgreSQL/Session/Pool.hs
usingConnectionPool
  :: (MonadIO io, MonadMask io)
  => Pool (K Connection db) -- ^ pool
  -> PQ db db io x -- ^ session
  -> io x
usingConnectionPool pool (PQ session) = mask $ \restore -> do
  (conn, local) <- liftIO $ takeResource pool
  ret <- restore (session conn) `onException`
            liftIO (destroyResource pool local conn)
  liftIO $ putResource local conn
  return $ unK ret
```

The pool parameters are explicit — stripe count, idle timeout (`NominalDiffTime`), and max connections
per stripe — and the docstring recommends an explicit `destroyConnectionPool` rather than relying on the
GC to reap idle connections ([`Session/Pool.hs`][pool]). This maps onto the survey's
[scoped acquire/release][pools] discipline, though — unlike `Effect TS`'s `Scope` or `Slick`'s CE3
`Resource` — Squeal's lifetime story is `bracket`/`mask` over `MonadMask`, not a first-class scoped
resource value.

---

## Query construction & injection safety

### The schema is a type

Everything in Squeal is checked against a **type-level Postgres schema**. The encoding is a tower of
[promoted datakinds][qmodels] defined in `Squeal.PostgreSQL.Type.Schema`. At the bottom is `PGType`, the
_"promoted datakind of PostgreSQL types"_ ([`Type/Schema.hs`][schema]) — `PGbool`, `PGint4`, `PGtext`,
`PGtimestamptz`, `PGvararray`, `PGcomposite`, and so on. A `NullType` wraps a `PGType` with its
nullability, which the docstring explains _"encodes the potential presence or definite absence of a
`NULL` allowing operations which are sensitive to such to be well typed"_ ([`Type/Schema.hs`][schema]):

```haskell
-- squeal-postgresql/src/Squeal/PostgreSQL/Type/Schema.hs
data NullType
  = Null    PGType -- ^ NULL may be present
  | NotNull PGType -- ^ NULL is absent

type ColumnType   = (Optionality, NullType)          -- DEFAULT-ness + null-ness + base type
type ColumnsType  = [(Symbol, ColumnType)]           -- a row of named columns
type TableType    = (TableConstraints, ColumnsType)  -- constraints + columns
data SchemumType  = Table TableType | View RowType | Typedef PGType | Index IndexType | …
type SchemaType   = [(Symbol, SchemumType)]          -- a named schema's objects
type SchemasType  = [(Symbol, SchemaType)]           -- the whole database
```

These are glued together by two type operators. `:::` pairs an alias `Symbol` with a type (_"intended to
connote Haskell's `::`"_) and `:=>` pairs a constraint with a type (_"intended to connote Haskell's
`=>`"_) ([`README.md`][readme]). A complete database schema is therefore an ordinary — if verbose —
Haskell type, written with `DataKinds` promotion ([`README.md`][readme]):

```haskell
-- squeal-postgresql/README.md
type UsersColumns =
  '[ "id"   :::   'Def :=> 'NotNull 'PGint4
   , "name" ::: 'NoDef :=> 'NotNull 'PGtext ]
type UsersConstraints = '[ "pk_users" ::: 'PrimaryKey '["id"] ]
type EmailsColumns =
  '[ "id" ::: 'Def :=> 'NotNull 'PGint4
   , "user_id" ::: 'NoDef :=> 'NotNull 'PGint4
   , "email" ::: 'NoDef :=> 'Null 'PGtext ]
type EmailsConstraints =
  '[ "pk_emails"  ::: 'PrimaryKey '["id"]
   , "fk_user_id" ::: 'ForeignKey '["user_id"] "public" "users" '["id"] ]
type Schema =
  '[ "users"  ::: 'Table (UsersConstraints  :=> UsersColumns)
   , "emails" ::: 'Table (EmailsConstraints :=> EmailsColumns) ]
type DB = Public Schema
```

The type family `Public` lifts a single schema into the one-schema `"public"` database, and Squeal
supports multi-schema databases directly. Type families over these kinds do the schema arithmetic:
`Create`, `Drop`, `Alter`, and `Rename` add, remove, and change entries (raising a custom
`TypeError` on a duplicate or missing alias), while `TableToRow`, `NullifyRow`, and friends compute
result-row shapes and outer-join nullification ([`Type/Schema.hs`][schema]).

### Queries are phantom-typed, not reified

The query DSL is a family of `newtype`s over a rendered `ByteString`, each carrying the schema in its
type parameters. `Query` has five ([`Query.hs`][query]):

```haskell
-- squeal-postgresql/src/Squeal/PostgreSQL/Query.hs
newtype Query
  (lat    :: FromType)     -- lateral scope for correlated subqueries
  (with   :: FromType)     -- common-table-expression scope
  (db     :: SchemasType)  -- the database this query is checked against
  (params :: [NullType])   -- out-of-line parameter types
  (row    :: RowType)      -- the result row
    = UnsafeQuery { renderQuery :: ByteString }
```

`Expression` carries seven parameters (adding a `Grouping` phantom and the current `from`-clause scope),
`Manipulation` four, and `Definition` two schema indices ([`Expression.hs`][expr], [`Manipulation.hs`][manip],
[`Definition.hs`][defn]). Crucially, the payload is _already-rendered SQL_ — there is no intermediate AST
type that a compiler walks. Correctness is entirely a property of the phantom parameters: when you write
`#users ! #id`, the type checker consults the `from`/`db` scope to prove the column exists, and the
handbook notes _"it's this scope inside the `from` type variable that Squeal checks to ensure that the
reference is valid"_ ([`squeal-core-concepts-handbook.md`][handbook]). A reference to a missing column,
or an aggregate used without `groupBy`, simply fails to type-check (the handbook walks through both
errors verbatim).

The combinators mirror SQL clause-for-clause. `select`/`select_`, `from`, `where_`, `innerJoin`,
`groupBy`, `having`, `orderBy`, `limit`, `offset`, `union`/`intersect`/`except`, `with` (CTEs), window
functions, and correlated subqueries are all present. Overloaded labels (`#users`, `#id`) name tables
and columns, `.==`/`.>`/`.&&` build typed conditions, and `` `as` `` aliases. From the README, a typed
inner join and the SQL it renders to ([`README.md`][readme]):

```haskell
-- squeal-postgresql/README.md
getUsers :: Statement DB () User
getUsers = query $ select_
  (#u ! #name `as` #userName :* #e ! #email `as` #userEmail)
  ( from (table (#users `as` #u)
    & innerJoin (table (#emails `as` #e))
      (#u ! #id .== #e ! #user_id)) )
-- SELECT "u"."name" AS "userName", "e"."email" AS "userEmail"
--   FROM "users" AS "u" INNER JOIN "emails" AS "e" ON ("u"."id" = "e"."user_id")
```

### Injection safety: parameters bind out-of-line

User data never enters the query text. Values are supplied as **out-of-line parameters** through
`param @n`, which renders a positional placeholder (with a type annotation) and leaves the actual value
to be sent on a separate channel ([`Query.hs`][query]):

```haskell
-- a parameterized query renders a placeholder, not the value
select Star (from (table #tab) & where_ (#col1 .> param @1))
-- SELECT * FROM "tab" AS "tab" WHERE ("col1" > ($1 :: int4))
```

At execution, the parameter is encoded by an `EncodeParams` and handed to `LibPQ.execParams` in **binary
format**, entirely out of band from the SQL string ([`Session.hs`][session]):

```haskell
-- squeal-postgresql/src/Squeal/PostgreSQL/Session.hs (executeParams, abridged)
encodedParams  <- runReaderT (runEncodeParams encode x) kconn
formattedParams <- … -- [(Oid, ByteString, Format)] carrying oid + binary bytes
resultMaybe    <- LibPQ.execParams conn (q <> ";") formattedParams LibPQ.Binary
```

Because the query text and the data travel on different channels — exactly the
[prepared-statement safety mechanism][injection] — SQL injection is structurally impossible in the typed
API; there is no place to concatenate a value into SQL. The **escape hatches** are the `Unsafe*`
constructors (`UnsafeQuery`, `UnsafeExpression`, `UnsafeManipulation`, `UnsafeDefinition`, `UnsafePGType`)
and helpers like `unsafeFunction`/`unsafeBinaryOp`, which splice raw `ByteString` text — the one place a
user can reintroduce injection risk, and used internally for constructs Squeal does not model (e.g.
`UnsafeManipulation "SET client_min_messages TO WARNING"`). They are named `Unsafe` precisely so their
use is visible in review.

---

## Schema, migrations & code generation

### Definitions change the schema type

DDL is a `Definition db0 db1` — a value witnessing a change from schema `db0` to schema `db1`. It is a
`Category`, so definitions compose with `>>>`, and the README fixes the mental model
([`README.md`][readme]): _"a `Definition` like `createTable`, `alterTable` or `dropTable` has two type
parameters, corresponding to the schema before being run and the schema after. We can compose
definitions using `>>>`."_ A `createTable` therefore has a type that _proves_ it produces exactly the
new schema ([`Definition.hs`][defn], [`README.md`][readme]):

```haskell
-- squeal-postgresql/README.md
setup :: Definition (Public '[]) DB
setup =
  createTable #users
    ( serial `as` #id :* (text & notNullable) `as` #name )
    ( primaryKey #id `as` #pk_users ) >>>
  createTable #emails
    ( serial `as` #id :* (int & notNullable) `as` #user_id :* (text & nullable) `as` #email )
    ( primaryKey #id `as` #pk_emails :*
      foreignKey #user_id #users #id (OnDelete Cascade) (OnUpdate Cascade) `as` #fk_user_id )
```

`setup` starts from the empty public schema `Public '[]` and ends at `DB`; `teardown :: Definition DB
(Public '[])` runs it in reverse. Getting the target type wrong is a compile error, so a migration and
its rollback are checked to be genuine inverses at the type level.

### Migrations are schema-changing and type-tracked

`Squeal.PostgreSQL.Session.Migration` exists _"to safely change the schema of your database over time"_
([`Session/Migration.hs`][migration]). A `Migration def db0 db1` bundles a unique name with a definition,
and a `Path` of migrations chains them so each migration's output schema is the next one's input. The
`Migratory` class comes in four flavours captured by the module's own docstring
([`Session/Migration.hs`][migration]):

> _"`Migration`s are parameterized giving the option of a ... pure one-way `Migration` `Definition` ...
> impure one-way `Migration` `(Indexed PQ IO)` ... pure reversible `Migration` `(IsoQ Definition)` ...
> impure reversible `Migration` `(IsoQ (Indexed PQ IO))`."_

The "reversible" (`IsoQ`) flavour pairs an `up` and a `down` definition, giving `migrateUp` and
`migrateDown`; the "impure" flavours run arbitrary `IO` (data backfills) inside the indexed monad rather
than pure SQL. A bookkeeping table records what has run — `MigrationsTable` has a unique `name` and a
`DEFAULT`-ed `executed_at` timestamp, created with `createTableIfNotExists`, and `runMigrations` runs
the whole path `transactionally_`, inserting a row per applied migration and skipping any already present
([`Session/Migration.hs`][migration]). `mainMigrate`/`mainMigrateIso` wrap this into a CLI executable with
`migrate`/`rollback`/`status` subcommands.

### No code generation: schema is hand-written, code-first

Squeal is emphatically **code-first**: the schema is a Haskell type you write by hand, and there is **no
introspection/codegen path** in the surveyed tree — nothing analogous to `jOOQ`, `sqlc`, or `Slick`'s
`slick-codegen` that reads a live database and emits typed schema code. This is a real trade-off (an
absence worth naming): the type-level schema and the actual database can drift, and keeping a large
schema type in sync with production DDL is manual labour. Squeal's answer is the opposite direction —
its `Definition`s _are_ the DDL, so `printSQL setup` emits the `CREATE TABLE` statements, and the
migration runner applies them — but the type is still the source of truth a human must author. (The
result-side of decoding _is_ generic: Haskell record types map to rows via `generics-sop`, below.)

---

## Type mapping & result decoding

The bridge between Haskell types and Postgres types is the `IsPG` class with an associated `PG` type
family ([`Type/PG.hs`][pg]): `instance IsPG Bool where type PG Bool = 'PGbool`, `PG Int32 = 'PGint4`,
`PG Text = 'PGtext`, and so on — an open relationship a user extends for their own newtypes. Encoding and
decoding are a matched pair of first-class, composable values, and the `Statement` type bundles them with
the query ([`Session/Statement.hs`][statement]): _"A top-level `Statement` type wraps a
`Squeal.PostgreSQL.Query.Query` or `Squeal.PostgreSQL.Manipulation.Manipulation` together with an
`EncodeParams` and a `DecodeRow`."_

- **`EncodeParams db tys x`** turns a Haskell input `x` into a heterogeneous list of binary encodings; it
  is a `Contravariant` functor, so `lmap`/`contramap` adapt the parameter type ([`Session/Encode.hs`][encode]).
- **`DecodeRow row y`** is a `ReaderT` over the raw row bytes in `Except Text`, deriving `Monad`,
  `Alternative`, `MonadError`, and `IsLabel` — so a decoder is written monadically and can fail with a
  typed decoding error ([`Session/Decode.hs`][decode]).
- Together, a `Statement` is a `Profunctor` (`lmap` over params, `rmap` over rows), a design the release
  notes credit to `hasql` ([`RELEASE NOTES.md`][relnotes]): _"The `Statement` `Profunctor` is heavily
  influenced by the `Statement` `Profunctor` from Nikita Volkov's excellent `hasql` library, building on
  the use of `postgresql-binary` for encoding and decoding."_

Most users never write encoders/decoders by hand: `GenericParams` and `GenericRow` derive them for any
`generics-sop` product type ([`Session/Encode.hs`][encode], [`Session/Statement.hs`][statement]). The
smart constructors `query`/`manipulation` call `genericParams`/`genericRow`, so a `Statement DB User ()`
encodes a Haskell `User` record into the right parameters and decodes result rows back into records — the
`User` in the README derives `SOP.Generic` and `SOP.HasDatatypeInfo` and nothing more ([`README.md`][readme]).

**Nullability is in the types, end to end.** A `'Null 'PGtext` column decodes to `Maybe Text` and a
`'NotNull 'PGtext` to `Text`; the `NullType` phantom propagates through expressions (`just_`, `fromNull`,
Option-aware operators), so a nullable column that is treated as non-null is a type error, matching the
survey's [nullability][typemap] axis.

---

## Effect model, transactions & error handling

### The `PQ` indexed monad

The signature feature — unusual even among typed libraries — is that Squeal's session type is an **Atkey
indexed monad transformer** parameterized by the schema _before_ and _after_. The `Session` module fixes
the usage ([`Session.hs`][session]): _"Using Squeal in your application will come down to defining the
`DB :: SchemasType` of your database and including `PQ DB DB` in your application's monad transformer
stack, giving it an instance of `MonadPQ DB`."_ The type itself
([`Session.hs`][session]):

```haskell
-- squeal-postgresql/src/Squeal/PostgreSQL/Session.hs
-- | We keep track of the schema via an Atkey indexed state monad transformer, PQ.
newtype PQ
  (db0 :: SchemasType)  -- schema before
  (db1 :: SchemasType)  -- schema after
  (m :: Type -> Type)
  (x :: Type) =
    PQ { unPQ :: K LibPQ.Connection db0 -> m (K x db1) }
```

The abstraction is generalized in `Squeal.PostgreSQL.Session.Indexed`, whose `IndexedMonadTrans` class
documents the theory ([`Session/Indexed.hs`][indexed]):

> _"An [Atkey indexed monad] ... is a `Functor` [enriched category]. An indexed monad transformer
> transforms a `Monad` into an indexed monad, and is a monad transformer when its source and target are
> the same, enabling use of standard `do` notation for endo-index operations."_

That last clause is the ergonomic payoff. When the schema does not change (`db0 ~ db1`), `PQ db db m` is
an ordinary `Monad`, so plain `do`-notation works for queries and DML. When it _does_ change — a
migration — you sequence with the indexed combinators (`pqThen`, `pqBind`, `&`), and `define ::
Definition db0 db1 -> pq db0 db1 io ()` lifts a schema-changing DDL into the indexed monad. The README's
end-to-end program threads a changing schema this way ([`README.md`][readme]): _"We can thread the
changing schema information through by using the indexed `PQ` monad transformer and when the schema
doesn't change we can use `Monad` and `MonadPQ` functionality."_ This is a very strong static guarantee:
the type of a session records the schema it started and ended in, so you cannot run a query against a
table a prior migration has not yet created, nor forget to update the schema after an `ALTER`.

### Running statements: `MonadPQ`

Statements run through an mtl-style class, `MonadPQ`, _"similar to `Control.Monad.State.Class.MonadState`,
for using `Database.PostgreSQL.LibPQ` to run `Statement`s"_ ([`Session/Monad.hs`][monad]). Its core method
is `executeParams`, with conveniences layered on top ([`Session/Monad.hs`][monad]):

```haskell
-- squeal-postgresql/src/Squeal/PostgreSQL/Session/Monad.hs
class Monad pq => MonadPQ db pq | pq -> db where
  executeParams :: Statement db x y -> x -> pq (Result y)
  execute       :: Statement db () y      -> pq (Result y)   -- parameter-free
  prepare       :: Statement db x y -> pq (Prepared pq x (Result y))
-- and derived helpers:
--   manipulateParams / manipulateParams_  (INSERT/UPDATE/DELETE with params)
--   runQueryParams / runQuery             (SELECT)
--   executePrepared / executePrepared_    (prepare once, run over a Traversable)
```

`Result y` is then drained with `getRows`, `firstRow`, or `ntuples`. `MonadPQ` is instanced for `PQ db db
io` (schema-preserving) and lifts through the standard mtl transformers, so a real app stack gets the API
for free ([`Session/Monad.hs`][monad]). Prepared statements are first-class: `prepare` returns a
`Prepared m x y` record (`runPrepared` + `deallocate`) that is a `Profunctor`/`Arrow`, so
`executePrepared` prepares once and runs a whole `Traversable` of parameter tuples.

### Transactions and savepoints

Transaction control is a set of combinators over `MonadPQ`. `transactionally` masks async exceptions,
`begin`s, runs the block, and `commit`s — rolling back and re-raising on exception
([`Session/Transaction/Unsafe.hs`][txunsafe]):

```haskell
-- squeal-postgresql/src/Squeal/PostgreSQL/Session/Transaction/Unsafe.hs
transactionally mode tx = mask $ \restore -> do
  manipulate_ $ begin mode
  result <- restore tx `onException` manipulate_ rollback
  manipulate_ commit
  return result
```

A `TransactionMode` bundles an `IsolationLevel` (`Serializable`/`RepeatableRead`/`ReadCommitted`/…), an
`AccessMode` (`ReadWrite`/`ReadOnly`), and a `DeferrableMode`, with presets `defaultMode`, `retryMode`
(serializable), and `longRunningMode`. **Nested transactions get real savepoints**: `withSavepoint`
issues a `SAVEPOINT`, runs the inner block, `ROLLBACK TO`s it on a `Left`, and `RELEASE`s it — so an
inner block can roll back without aborting the outer transaction ([`Session/Transaction/Unsafe.hs`][txunsafe]),
in contrast to `Slick`, whose nested `transactionally` adds no savepoints. `transactionallyRetry`
implements serialization-failure retry: it `try`s the block and, on a `SerializationFailure` or
`DeadlockDetected`, rolls back and loops; any other exception rolls back and rethrows
([`Session/Transaction/Unsafe.hs`][txunsafe]). `ephemerally` always rolls back, for tests.

A safety refinement sits above this: the `Squeal.PostgreSQL.Session.Transaction` module (the non-`Unsafe`
one) exposes a `Transaction db x` type _"that permit[s] only database operations, pure functions, and
synchronous exception handling forbidding arbitrary `IO` operations"_, so a transactional block cannot
accidentally launch a missile mid-transaction ([`Session/Transaction.hs`][tx]). The `.Unsafe` variants
re-admit arbitrary `IO` when you genuinely need it.

### Errors are exceptions, not a typed channel

This is where Squeal's guarantees stop. Unlike its schema story, its **error model is conventional
exceptions in `IO`**, not a typed error value in the effect. Failures surface as a `SquealException` sum
type thrown via `MonadThrow` ([`Session/Exception.hs`][exception]):

```haskell
-- squeal-postgresql/src/Squeal/PostgreSQL/Session/Exception.hs
data SquealException
  = SQLException SQLState            -- server-side SQLSTATE + message
  | ConnectionException Text         -- a libpq call returned failure
  | DecodingException Text Text      -- a DecodeRow failed
  | ColumnsException Text LibPQ.Column
  | RowsException Text LibPQ.Row LibPQ.Row
```

Convenience pattern synonyms name the common `SQLSTATE`s — `UniqueViolation` (`23505`), `CheckViolation`
(`23514`), `SerializationFailure` (`40001`), `DeadlockDetected` (`40P01`) — and `catchSqueal`,
`handleSqueal`, `trySqueal`, `throwSqueal` are the `MonadCatch` wrappers ([`Session/Exception.hs`][exception]).
This is the key contrast with the [typed-error][effects] effect mappers this survey weights most heavily:
where `doobie`/`skunk` keep errors in the effect's error type and `Effect TS` models an `SqlError` union,
Squeal invests its entire static budget in the _schema/query_ dimension and handles _errors_ the way
`JDBC` does — as exceptions you `catch`. A decoding mismatch is caught statically (the row type must
match), but a runtime constraint violation or serialization failure is a thrown value, not a type. For
an algebraic-effects-first design, that is the precise line Squeal draws: exhaustive static typing of
_what SQL you run against which schema_, but not of _how it can fail_.

---

## Ecosystem & maturity

Squeal is a mature, single-author-led library — Eitan Chatav / Morphism, LLC — published on
[Hackage][hackage] and [Stackage][stackage] under the permissive **BSD-3-Clause** license
([`LICENSE`][license], [`squeal-postgresql.cabal`][cabal]). It is **PostgreSQL-only** by design and by
dependency: it builds directly on `postgresql-libpq` (the C-level `libpq` binding) and `postgresql-binary`
(binary wire codecs), plus `generics-sop`/`records-sop` for the generic encode/decode, `free-categories`
for the `Definition` `Category`, `resource-pool` for pooling, and `mtl`/`mmorph`/`monad-control` for the
transformer machinery ([`squeal-postgresql.cabal`][cabal]). Notably it does **not** depend on `hasql`,
though it borrows `hasql`'s `Statement` profunctor design (above).

The repo is a small monorepo: the core `squeal-postgresql` package plus two extension packages —
`squeal-postgresql-ltree` (the `ltree` hierarchical-label type) and `squeal-postgresql-uuid-ossp` (the
`uuid-ossp` generation functions) — showing the intended extension pattern for Postgres features and
types beyond the core ([`squeal-postgresql-ltree.cabal`][ltree], repository layout). The version in the
pinned tree is `0.9.2.0`. Documentation is unusually deep for a library of its size: extensive haddocks
with doctested examples throughout, a book-length [Core Concepts Handbook][handbook] on the phantom-type
machinery, a `scrap-your-nils.md` note on the `generics-sop` heterogeneous lists it leans on, and a
recorded conference talk. Testing runs against a real Postgres on `localhost` ([`README.md`][readme]).

---

## Strengths

- **The schema is a type, checked end to end.** A query naming a missing column, comparing incompatible
  Postgres types, aggregating without `groupBy`, or treating a nullable column as non-null is a compile
  error — the deepest static schema guarantee in the survey.
- **Migrations are type-tracked and reversible.** A `Definition db0 db1` proves it transforms one schema
  into a specific other; reversible `IsoQ` migrations type-check `up`/`down` as inverses; the indexed
  `PQ` monad forbids running a session against a schema a migration has not yet produced.
- **Structural injection safety.** Values enter only as out-of-line `param`s encoded to binary and sent
  via `LibPQ.execParams`; there is no string to inject into. `Unsafe*` escape hatches are explicitly named.
- **Predictable, un-optimized SQL.** No AST-rewriting compiler — combinators render to the SQL you expect,
  inspectable with `printSQL`; the generated SQL is _"completely predictable."_
- **Composable codecs, generically derived.** `EncodeParams` (contravariant) and `DecodeRow` (monadic)
  compose; `generics-sop` derives them for record types, so most codecs are free.
- **Full PostgreSQL surface.** `WITH`/CTEs, window functions, correlated subqueries, upserts, arrays,
  composite/enum types, JSON, ranges, text search, real savepoints, and serialization-failure retry.
- **mtl-friendly.** `MonadPQ` lifts through standard transformers; `PQ DB DB` drops into an app's stack.

## Weaknesses

- **Steep type complexity.** The seven-parameter `Expression` and five-parameter `Query` produce large,
  hard-to-read signatures and type errors; the handbook calls the type parameters _"the most complicated
  part of learning to use Squeal,"_ and the trade-off is stated as _"you need verbosity to get type safety."_
- **PostgreSQL only.** No dialect abstraction; the schema kinds and codecs are Postgres-specific.
- **No code generation / introspection.** The schema type is authored by hand; nothing reads a live
  database to generate it, so the type and the deployed DDL can drift (unlike `jOOQ`/`sqlc`/`slick-codegen`).
- **Errors are exceptions, not a typed channel.** Constraint violations, serialization failures, and
  connection errors are thrown `SquealException`s you must `catch` — no enumerated error type in the
  effect, unlike `doobie`/`skunk`/`Effect TS`.
- **Effect model is `IO`-bound.** `PQ` is a transformer over `IO`, not an effect value interpreted by a
  runtime; resource lifetime is `bracket`/`mask`, not a first-class `Scope`/`Resource`.
- **GHC-version and extension heavy.** Requires many advanced extensions (`DataKinds`, `TypeFamilies`,
  `GADTs`, `UndecidableInstances`, `OverloadedLabels`, …) and long compile times for large schemas.

## Key design decisions and trade-offs

| Decision                                                            | Rationale                                                                                        | Trade-off                                                                                                  |
| ------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------- |
| **Type-level Postgres schema** (`SchemasType` of promoted kinds)    | Every table/column/nullability/constraint is checkable; a bad reference is a compile error       | Verbose schema types; complex signatures; PostgreSQL-specific kinds                                        |
| **Phantom-typed `ByteString`, no reified AST**                      | Predictable SQL, cheap rendering, all safety in the types                                        | No query rewriting/optimization; no dialect retargeting; SQL shape is what you wrote                       |
| **Indexed monad `PQ db0 db1`** (Atkey) tracking schema before/after | Migrations change the type; can't query a not-yet-created table; `do`-notation when schema fixed | A second sequencing vocabulary (`pqThen`/`pqBind`) for schema-changing code; extra concept to learn        |
| **Out-of-line `param` + `EncodeParams` over `libpq` binary**        | Structural injection safety; binary transfer; prepared-statement reuse                           | `Unsafe*` splices reintroduce risk; parameters are positional (`@1`, `@2`)                                 |
| **`Definition` `Category`, no codegen** (code-first schema)         | Schema is one authoritative Haskell type; DDL derives from it (`printSQL`)                       | Type and live DB can drift; large schemas are hand-maintained; no introspection path                       |
| **Generic codecs via `generics-sop`** (`EncodeParams`/`DecodeRow`)  | Record types map to rows/params for free; composable profunctor `Statement`                      | Ties the API to `generics-sop`; custom encodings need `IsPG`/`ToPG`/`FromPG` instances                     |
| **Errors as thrown `SquealException`s**                             | Simple; interops with `MonadCatch`; pattern synonyms name common `SQLSTATE`s                     | No typed error channel (unlike `doobie`/`Effect TS`); failures are runtime values, not types               |
| **Real savepoints for nested transactions**                         | Inner blocks roll back independently; serialization-failure retry built in                       | Transaction combinators live in an `.Unsafe` module (arbitrary `IO`) unless the safe `Transaction` is used |

---

## Sources

- [morphismtech/squeal — GitHub repository][repo] · [Hackage][hackage] · [Stackage][stackage]
- [`README.md` — deep-embedding pitch, schema encoding, `setup`/`getUsers`/`insertUser` examples, indexed `PQ` program][readme]
- [`squeal-core-concepts-handbook.md` — core types vs. phantom parameters, `from`-scope checking, compile-error walkthroughs][handbook]
- [`squeal-postgresql/src/Squeal/PostgreSQL/Type/Schema.hs` — `PGType`/`NullType`/`ColumnType`/`TableType`/`SchemaType`/`SchemasType`, schema type families][schema]
- [`Type/PG.hs` — `IsPG` class + `PG` type family (Haskell → Postgres type mapping)][pg]
- [`Query.hs` — `Query` newtype, five phantom parameters, `Query_`, set operations, printed SQL examples][query] · [`Expression.hs`][expr] · [`Manipulation.hs`][manip] · [`Query/Select.hs`][select] · [`Definition.hs`][defn]
- [`Session.hs` — the `PQ` indexed monad, `MonadPQ` instance, `executeParams`/`LibPQ.execParams`, `withConnection`][session]
- [`Session/Indexed.hs` — `IndexedMonadTrans` / Atkey indexed monad, `define`][indexed]
- [`Session/Monad.hs` — `MonadPQ` class, `executeParams`/`manipulateParams`/`runQuery`/`prepare`][monad]
- [`Session/Statement.hs` — `Statement` = `Query`/`Manipulation` + `EncodeParams` + `DecodeRow`; `Prepared`][statement]
- [`Session/Encode.hs` — `EncodeParams` (contravariant), `GenericParams`, `IsPG`/`ToPG`][encode] · [`Session/Decode.hs` — `DecodeRow` (monadic), `GenericRow`][decode]
- [`Session/Migration.hs` — `Migration`/`Migratory`, four flavours, `MigrationsTable`, `mainMigrate`][migration]
- [`Session/Transaction/Unsafe.hs` — `transactionally`/`withSavepoint`/`transactionallyRetry`, `TransactionMode`][txunsafe] · [`Session/Transaction.hs` — safe `Transaction` type][tx]
- [`Session/Exception.hs` — `SquealException`, `SQLSTATE` pattern synonyms, `catchSqueal`][exception] · [`Session/Pool.hs` — `resource-pool` pooling][pool]
- [`RELEASE NOTES.md` — `hasql` `Statement`-profunctor influence, `Prepared` addition][relnotes] · [`squeal-postgresql.cabal` — deps, license, modules][cabal] · [`LICENSE` — BSD-3-Clause][license]
- Concepts: [abstraction ladder][ladder] · [query construction models / phantom types][qmodels] · [statements & injection][injection] · [type mapping & decoding][typemap] · [schema & migrations][schemamig] · [effects, transactions & errors][effects] · [connections & pools][pools]

<!-- References -->

[repo]: https://github.com/morphismtech/squeal
[hackage]: https://hackage.haskell.org/package/squeal-postgresql
[stackage]: https://www.stackage.org/package/squeal-postgresql
[handbook]: https://github.com/morphismtech/squeal/blob/533cab7bbc4ccd8da2872af511c79acf9896cd8c/squeal-core-concepts-handbook.md
[readme]: https://github.com/morphismtech/squeal/blob/533cab7bbc4ccd8da2872af511c79acf9896cd8c/README.md
[raveline]: https://github.com/morphismtech/squeal/blob/533cab7bbc4ccd8da2872af511c79acf9896cd8c/squeal-presentation-raveline.md
[relnotes]: https://github.com/morphismtech/squeal/blob/533cab7bbc4ccd8da2872af511c79acf9896cd8c/RELEASE%20NOTES.md
[license]: https://github.com/morphismtech/squeal/blob/533cab7bbc4ccd8da2872af511c79acf9896cd8c/squeal-postgresql/LICENSE
[cabal]: https://github.com/morphismtech/squeal/blob/533cab7bbc4ccd8da2872af511c79acf9896cd8c/squeal-postgresql/squeal-postgresql.cabal
[ltree]: https://github.com/morphismtech/squeal/blob/533cab7bbc4ccd8da2872af511c79acf9896cd8c/squeal-postgresql-ltree/squeal-postgresql-ltree.cabal
[schema]: https://github.com/morphismtech/squeal/blob/533cab7bbc4ccd8da2872af511c79acf9896cd8c/squeal-postgresql/src/Squeal/PostgreSQL/Type/Schema.hs
[pg]: https://github.com/morphismtech/squeal/blob/533cab7bbc4ccd8da2872af511c79acf9896cd8c/squeal-postgresql/src/Squeal/PostgreSQL/Type/PG.hs
[query]: https://github.com/morphismtech/squeal/blob/533cab7bbc4ccd8da2872af511c79acf9896cd8c/squeal-postgresql/src/Squeal/PostgreSQL/Query.hs
[expr]: https://github.com/morphismtech/squeal/blob/533cab7bbc4ccd8da2872af511c79acf9896cd8c/squeal-postgresql/src/Squeal/PostgreSQL/Expression.hs
[manip]: https://github.com/morphismtech/squeal/blob/533cab7bbc4ccd8da2872af511c79acf9896cd8c/squeal-postgresql/src/Squeal/PostgreSQL/Manipulation.hs
[select]: https://github.com/morphismtech/squeal/blob/533cab7bbc4ccd8da2872af511c79acf9896cd8c/squeal-postgresql/src/Squeal/PostgreSQL/Query/Select.hs
[defn]: https://github.com/morphismtech/squeal/blob/533cab7bbc4ccd8da2872af511c79acf9896cd8c/squeal-postgresql/src/Squeal/PostgreSQL/Definition.hs
[session]: https://github.com/morphismtech/squeal/blob/533cab7bbc4ccd8da2872af511c79acf9896cd8c/squeal-postgresql/src/Squeal/PostgreSQL/Session.hs
[indexed]: https://github.com/morphismtech/squeal/blob/533cab7bbc4ccd8da2872af511c79acf9896cd8c/squeal-postgresql/src/Squeal/PostgreSQL/Session/Indexed.hs
[monad]: https://github.com/morphismtech/squeal/blob/533cab7bbc4ccd8da2872af511c79acf9896cd8c/squeal-postgresql/src/Squeal/PostgreSQL/Session/Monad.hs
[statement]: https://github.com/morphismtech/squeal/blob/533cab7bbc4ccd8da2872af511c79acf9896cd8c/squeal-postgresql/src/Squeal/PostgreSQL/Session/Statement.hs
[encode]: https://github.com/morphismtech/squeal/blob/533cab7bbc4ccd8da2872af511c79acf9896cd8c/squeal-postgresql/src/Squeal/PostgreSQL/Session/Encode.hs
[decode]: https://github.com/morphismtech/squeal/blob/533cab7bbc4ccd8da2872af511c79acf9896cd8c/squeal-postgresql/src/Squeal/PostgreSQL/Session/Decode.hs
[migration]: https://github.com/morphismtech/squeal/blob/533cab7bbc4ccd8da2872af511c79acf9896cd8c/squeal-postgresql/src/Squeal/PostgreSQL/Session/Migration.hs
[txunsafe]: https://github.com/morphismtech/squeal/blob/533cab7bbc4ccd8da2872af511c79acf9896cd8c/squeal-postgresql/src/Squeal/PostgreSQL/Session/Transaction/Unsafe.hs
[tx]: https://github.com/morphismtech/squeal/blob/533cab7bbc4ccd8da2872af511c79acf9896cd8c/squeal-postgresql/src/Squeal/PostgreSQL/Session/Transaction.hs
[exception]: https://github.com/morphismtech/squeal/blob/533cab7bbc4ccd8da2872af511c79acf9896cd8c/squeal-postgresql/src/Squeal/PostgreSQL/Session/Exception.hs
[pool]: https://github.com/morphismtech/squeal/blob/533cab7bbc4ccd8da2872af511c79acf9896cd8c/squeal-postgresql/src/Squeal/PostgreSQL/Session/Pool.hs
[concepts]: ./concepts.md
[ladder]: ./concepts.md#the-abstraction-ladder
[qmodels]: ./concepts.md#query-construction-models
[injection]: ./concepts.md#statements-parameters-and-sql-injection
[typemap]: ./concepts.md#type-mapping-and-result-decoding
[schemamig]: ./concepts.md#schema-migrations-code-generation
[effects]: ./concepts.md#effects-transactions-and-error-handling
[pools]: ./concepts.md#connections-pools-and-sessions
