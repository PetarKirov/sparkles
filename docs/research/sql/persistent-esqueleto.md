# persistent + esqueleto (Haskell)

The Yesod ecosystem's ORM: `persistent` turns a whitespace **schema block** into Haskell entity types and migrations via Template Haskell and gives you type-safe single-table CRUD, while `esqueleto` layers a type-safe SQL EDSL — the `JOIN`s and complex `SELECT`s persistent deliberately omits — over the exact same schema.

| Field              | Value                                                                                                                                                                           |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language           | Haskell (GHC; heavy Template Haskell + `QuasiQuotes`, GADTs, type families, `DataKinds`)                                                                                        |
| License            | `persistent`: **MIT** (`LICENSE`, `persistent.cabal`); `esqueleto`: **BSD-3-Clause** (`LICENSE`, `esqueleto.cabal` `license: BSD3`)                                             |
| Repository         | [yesodweb/persistent][prepo] · [bitemyapp/esqueleto][erepo]                                                                                                                     |
| Documentation      | [hackage: persistent][phackage] · [hackage: esqueleto][ehackage] · [Yesod book — Persistent chapter][ybook]                                                                     |
| Category           | [Full ORM (data-mapper)][ladder] — code-first entities + migrations + `Key`/`Entity` identity (`persistent`); [typed relational algebra][qcm] join EDSL (`esqueleto`)           |
| Abstraction level  | The [full-ORM][ladder] rung for schema/entities/migration, but **without** change tracking, unit of work, or lazy loading; `esqueleto` adds the [typed-algebra][qcm] query rung |
| Query model        | TH-declared entities + `persistent` typed filters (`[PersonAge >. 30]`); `esqueleto` typed relational algebra over `SqlExpr` (a [quoted DSL → AST][qcm])                        |
| Effect/async model | `SqlPersistT` = `ReaderT SqlBackend` over `IO` (**blocking**, `MonadUnliftIO`); transactions bracket the `ReaderT`                                                              |
| Backends           | PostgreSQL, SQLite, MySQL via `persistent-*`; historically MongoDB, Redis (key-value subset)                                                                                    |
| First release      | ≈2012 (web-attested; both `LICENSE`s dated 2012)                                                                                                                                |
| Latest version     | `persistent 2.18.1.0`, `esqueleto 3.6.0.0` (`*.cabal`; web-attested for release date)                                                                                           |

> [!NOTE]
> This pair is the survey's data point for a **code-first ORM in a statically-typed,
> pure-functional ecosystem**. `persistent` owns the schema (it _generates_ entity types and
> migrations from a Template-Haskell block) and the identity story (`Key`/`Entity`), which
> puts it at the [full-ORM rung][ladder] — but it deliberately drops the mutable-object half
> of a classic ORM: no [change tracking][orm], no [unit of work][orm], no [lazy load][nplusone].
> Its query API is intentionally single-table CRUD, so `esqueleto` supplies the missing
> [typed relational algebra][qcm] (`JOIN`s, sub-selects, aggregates) over the same entities.
> Contrast `Beam` and `Squeal`, which unify schema and full queries in one library, and
> `Ecto`, whose `Changeset` adds a validation/tracking layer persistent has no analogue for.
> Terms below link to [concepts][concepts].

---

## Overview

### What it solves

`persistent` is, in its own `persistent.cabal` one-liner, _"Type-safe, multi-backend data
serialization"_ ([`persistent.cabal`][pcabal]). Its `README` frames the ORM label carefully
([`README.md`][preadme]):

> _"A Haskell datastore. Datastores are often referred to as "ORM"s. While 'O' traditionally
> means object, the concept can be generalized as: avoidance of boilerplate serialization. …
> the ORM concept is a way to make what is usually an un-typed driver type-safe."_

The `Database.Persist` module doc states the backend reach directly
([`Database/Persist.hs`][ppersist]):

> _"This library intends to provide an easy, flexible, and convenient interface to various
> data storage backends. Backends include SQL databases, like `mysql`, `postgresql`, and
> `sqlite`, as well as NoSQL databases, like `mongodb` and `redis`."_

Because it is backend-agnostic, `persistent` cannot offer everything every backend can do —
and it says so. Its `README` names the exact gap that `esqueleto` exists to fill
([`README.md`][preadme]):

> _"Providing a universal query layer will always be limiting. A major limitation for SQL
> databases is that the persistent library does not directly provide joins. However, you can
> use Esqueleto with Persistent's serialization to write type-safe SQL queries."_

`esqueleto` picks up there. Its `README` positions it as the join layer, and its `cabal`
description spells out the division of labour ([`README.md`][ereadme], [`esqueleto.cabal`][ecabal]):

> _"Esqueleto is a bare bones, type-safe EDSL for SQL queries that works with unmodified
> persistent SQL backends. … In particular, esqueleto is the recommended library for type-safe
> JOINs on persistent SQL backends. (The alternative is using raw SQL, but that's error prone
> and does not offer any composability.)"_

> _"While `persistent` is a nice library for storing and retrieving records, including with
> filters, it does not try to support some of the features that are specific to SQL backends.
> In particular, `esqueleto` is the recommended library for type-safe `JOIN`s on `persistent`
> SQL backends."_

So the two libraries are read together: `persistent` owns **entities, migrations, identity, and
CRUD**; `esqueleto` owns **relational queries** over those entities. Neither replaces the other,
and (per the esqueleto `README`) _"Other than identifier name clashes, `esqueleto` does not
conflict with `persistent` in any way."_

### Design philosophy

`persistent`'s guiding ambition is **compile-time totality** — catch schema and query mistakes
in the type-checker, not at runtime ([`README.md`][preadme]):

> _"Persistent's goal is to catch every possible error at compile-time, and it comes close to
> that."_

That is why the schema is not a runtime config but a Template-Haskell program that _emits_ the
record types, the `Key`/`EntityField` GADTs, the `PersistEntity` instances, and the migration —
the compiler then checks every `insert`, filter, and projection against those generated types.

`esqueleto`'s three stated goals are narrower and SQL-literal ([`Database/Esqueleto.hs`][emod],
[`README.md`][ereadme]):

> _"Be easily translatable to SQL. When you take a look at a `esqueleto` query, you should be
> able to know exactly how the SQL query will end up. … Support the most widely used SQL
> features. … Be as type-safe as possible."_

Crucially, portability is a **non-goal**: _"It is not a goal to be able to write portable SQL.
We do not try to hide the differences between DBMSs from you"_ ([`README.md`][ereadme]). Where a
[typed relational-algebra][qcm] library like `Opaleye` hides the dialect, esqueleto keeps the
generated SQL predictable and lets RDBMS-specific modules (`Database.Esqueleto.PostgreSQL`,
`.MySQL`, `.SQLite`) surface engine features.

---

## Connection, pooling & resource lifetime

Both libraries run over `persistent`'s `SqlBackend` — an open connection plus its prepared-statement
cache and the `connBegin`/`connCommit`/`connRollback` hooks. Execution happens inside the
`SqlPersistT` monad, a plain reader over that backend ([`Database/Persist/Sql/Types.hs`][ptypes]):

```haskell
type SqlPersistT = ReaderT SqlBackend

type SqlPersistM = SqlPersistT (NoLoggingT (ResourceT IO))
```

A [pool][pool] of connections is a `Pool SqlBackend` (`ConnectionPool`), created with
`withSqlPool`/`createSqlPoolWithConfig`; sizing is a `ConnectionPoolConfig` with
`connectionPoolConfigStripes`, `connectionPoolConfigIdleTimeout`, and `connectionPoolConfigSize`
([`Database/Persist/Sql/Types.hs`][ptypes]). Resource lifetime is handled through
`resourcet`/`MonadUnliftIO`: `withSqlPoolWithConfig` brackets the pool with
`UE.bracket … destroyAllResources` ([`Database/Persist/Sql/Run.hs`][prun]), so a leaked pool is
closed by the bracket rather than a finalizer.

You enter the monad with `runSqlPool` (lease from the pool) or `runSqlConn` (a single connection);
both wrap the action in a transaction ([`Database/Persist/Sql/Run.hs`][prun]):

> _"Get a connection from the pool, run the given action, and then return the connection to the
> pool. This function performs the given action in a transaction. If an exception occurs during
> the action, then the transaction is rolled back."_

`esqueleto` adds **no** connection or pooling machinery of its own — its `select`, `update`, and
`delete` run in the same `ReaderT backend m` (constrained by `SqlBackendCanRead`/`SqlBackendCanWrite`),
so they compose inside a `runSqlPool`/`runSqlConn` bracket exactly like persistent's own actions.

## Query construction & injection safety

This is where the two libraries split most sharply, and where the survey's safe-SQL story lives.

**persistent: typed filters over an `EntityField` GADT.** persistent's query API is deliberately
small — single-table `SELECT`/`UPDATE`/`DELETE` expressed as lists of `Filter`s and `SelectOpt`s,
never joins. A `Filter` pins a generated `EntityField` to a value and a comparison operator
([`Database/Persist/Class/PersistEntity.hs`][pentity]):

```haskell
data Filter record
    = forall typ. (PersistField typ) => Filter
        { filterField :: EntityField record typ
        , filterValue :: FilterValue typ
        , filterFilter :: PersistFilter
        }
    | FilterAnd [Filter record]
    | FilterOr  [Filter record]
    | BackendFilter (BackendSpecificFilter (PersistEntityBackend record) record)
```

The comparison combinators are thin constructors of that GADT — every one binds its argument as a
`FilterValue`, never as SQL text ([`Database/Persist.hs`][ppersist]):

```haskell
infix 4 ==., <., <=., >., >=., !=.
f ==. a = Filter f (FilterValue a) Eq
f >.  a = Filter f (FilterValue a) Gt   -- likewise >=. Ge, <. Lt, <=. Le, !=. Ne
f <-. a = Filter f (FilterValues a) In  -- value in a list
[ ... ] ||. [ ... ]                     -- OR of two filter lists
```

A query then reads as data — `selectList [PersonAge >. 30] [LimitTo 10]` — where `PersonAge` is a
constructor of the TH-generated `EntityField Person Int` GADT, so a typo or a type-mismatched
comparison is a **compile** error. The `SelectOpt` list carries ordering and paging
(`Asc`/`Desc`/`OffsetBy`/`LimitTo`) ([`Database/Persist/Class/PersistEntity.hs`][pentity]).
Because the value only ever enters as a `FilterValue`, persistent's filters are
[injection-safe][inject] by construction — there is no string to interpolate into. The escape
hatch is `rawSql`/`rawExecute`, where you _do_ write SQL text but values still bind as `?`
placeholders ([`Database/Persist/Sql/Raw.hs`][praw]):

> _"You may put value placeholders (question marks, `?`) in your SQL query. These placeholders
> are then replaced by the values you pass on the second parameter, already correctly escaped. …
> Since you're giving a raw SQL statement, you don't get any guarantees regarding safety."_

`rawSql` also uses a **double-question-mark** entity placeholder `??`, expanded to the full,
correctly-ordered column list for an `Entity` — the low-level seam persistent uses when the DSL
can't express a query (e.g. joins).

**esqueleto: a typed SQL EDSL over `SqlExpr`.** esqueleto restores everything the filter API can't
express. A query is a `SqlQuery` (a `WriterT` accumulating `SideData` — from-clauses, where-clauses,
etc.), and every expression is a typed `SqlExpr` that renders to a builder plus a list of bound
`PersistValue`s ([`Database/Esqueleto/Internal/Internal.hs`][eint]):

```haskell
newtype SqlQuery a = Q { unQ :: W.WriterT SideData (S.State IdentState) a }

data SqlExpr a = ERaw SqlExprMeta (NeedParens -> IdentInfo -> (TLB.Builder, [PersistValue]))
```

The signature surface is small and reads like SQL — `where_`, `on`, `(^.)`, and `val`
([`Database/Esqueleto/Internal/Internal.hs`][eint], [`README.md`][ereadme]):

```haskell
where_ :: SqlExpr (Value Bool) -> SqlQuery ()          -- WHERE
on     :: SqlExpr (Value Bool) -> SqlQuery ()          -- ON (join condition)
(^.)   :: (PersistEntity val, PersistField typ)        -- project a field
       => SqlExpr (Entity val) -> EntityField val typ -> SqlExpr (Value typ)

select $
  from $ \p -> do
    where_ (p ^. PersonName ==. val "John")
    return p
```

Two mechanisms make this safe. `(^.)` (_"Project a field of an entity"_) takes a generated
`EntityField`, so a projection can only name a column that exists on that entity, at its real type
([`Database/Esqueleto/Internal/Internal.hs`][eint]). And `val` — the one way a Haskell value enters
a query — compiles to a bound parameter, **not** to SQL text ([`Database/Esqueleto/Internal/Internal.hs`][eint]):

```haskell
-- | Lift a constant value from Haskell-land to the query.
val :: PersistField typ => typ -> SqlExpr (Value typ)
val v = ERaw noMeta $ \_ _ -> ("?", [toPersistValue v])
```

The `README`'s injection section makes the guarantee concrete: a `val`-lifted string containing
`'; DROP TABLE foo; --` renders as a single quoted `?` parameter and drops nothing
([`README.md`][ereadme]):

> _"Esqueleto uses parameterization to prevent sql injections on values and arguments on all
> queries … And the printed value is `hi'; DROP TABLE foo; select 'bye'` and no table is dropped.
> This is good and makes the use of strings values safe."_

The loud exception is the `unsafeSql*` family (`unsafeSqlFunction`, `unsafeSqlValue`,
`unsafeSqlCastAs`) for calling functions esqueleto doesn't model. These splice text **verbatim**,
and the `README` warns that they re-open injection: an `unsafeSqlFunction "0; DROP TABLE bar; …"`
_will_ erase `bar`, so _"never use any user or third party input inside an unsafe function without
first parsing it or heavily sanitizing the input"_ ([`README.md`][ereadme]).

**The join story — the whole point.** The legacy `from` takes a lambda whose argument encodes the
join shape as nested `InnerJoin`/`LeftOuterJoin` types, with `on` clauses supplied separately
([`README.md`][ereadme]):

```haskell
select $
  from $ \(p `LeftOuterJoin` mb) -> do
    on (just (p ^. PersonId) ==. mb ?. BlogPostAuthorId)
    orderBy [asc (p ^. PersonName), asc (mb ?. BlogPostTitle)]
    return (p, mb)
```

On an outer join the right side may be absent, so `mb :: SqlExpr (Maybe (Entity BlogPost))` and you
project it with `(?.)` (nullable) instead of `(^.)` — the nullability is in the **type**, and the
result comes back as `Maybe (Entity BlogPost)`. The weakness of this form is that a stray or
missing `on` is a **runtime** error: `OnClauseWithoutMatchingJoinException`, _"thrown whenever `on`
is used to create an `ON` clause but no matching `JOIN` is found"_
([`Database/Esqueleto/Internal/Internal.hs`][eint]).

The `Database.Esqueleto.Experimental` module (introduced in `3.3.3.0`, becoming the default in
`4.0.0.0`) fixes exactly that by attaching each `on` to its join with the `(:&)` pattern
([`Database/Esqueleto/Experimental.hs`][eexp]):

```haskell
select $ do
  (people :& blogPosts) <-
    from $ table @Person
      `leftJoin` table @BlogPost
      `on` (\(people :& blogPosts) ->
              just (people ^. PersonId) ==. blogPosts ?. BlogPostAuthorId)
  where_ (people ^. PersonAge >. just (val 18))
  pure (people, blogPosts)
```

The module doc states the payoff ([`Database/Esqueleto/Experimental.hs`][eexp]):

> _"As a consequence of this, several classes of runtime errors are now caught at compile time.
> This includes missing 'on' clauses and improper handling of `Maybe` values in outer joins."_

The experimental `from` also enables `UNION`/`UNION ALL`/`INTERSECT`/`EXCEPT` (`union_`, `unionAll_`,
`intersect_`, `except_`), subqueries in joins, and common table expressions (`with`, `withRecursive`)
— the _"Support the most widely used SQL features"_ goal made good. Both persistent's `OverloadedLabels`
(`p ^. #name`) and GHC 9.2's `OverloadedRecordDot` (`person.name`) work as terser field projections
([`README.md`][ereadme]).

## Schema, migrations & code generation

This is persistent's signature move and the reason it sits at the ORM rung: the schema is **code you
write once, in a QuasiQuote block, that the compiler expands into everything else**.

**The schema block.** You declare tables in a whitespace DSL inside `[persistLowerCase| … |]` (or
`persistUpperCase`, or `persistFileWith` for an external file). The `Database.Persist.Quasi` module
doc defines the syntax ([`Database/Persist/Quasi.hs`][pquasi]):

> _"This module defines the Persistent entity syntax used in the quasiquoter to generate persistent
> entities. The basic structure of the syntax looks like this: … You start an entity definition with
> the table name … followed by a list of fields … `fieldName FieldType`. You can indicate that a
> field is nullable with `Maybe` at the end of the type."_

```haskell
share [mkPersist sqlSettings, mkMigrate "migrateAll"] [persistLowerCase|
Person
    name String
    age  Int Maybe
    deriving Show
BlogPost
    title    String
    authorId PersonId          -- a foreign key: PersonId is Person's Key type
    deriving Show
|]
```

**What Template Haskell generates.** `mkPersist` _"Create[s] data types and appropriate
'PersistEntity' instances for the given 'UnboundEntityDef's"_ ([`Database/Persist/TH/Internal.hs`][pth]);
`share` just _"Apply[s] the given list of functions to the same `EntityDef`s"_ so `mkPersist` and
`mkMigrate` see one schema. From the block above the compiler emits: the record types (`data Person =
Person { personName :: String, personAge :: Maybe Int }`), the `Key Person`/`PersonId` newtype, the
`EntityField Person typ` GADT (`PersonName`, `PersonAge`, `PersonId`) used by both persistent's filters
and esqueleto's `(^.)`, and the `PersistEntity Person` instance carrying the metadata
([`Database/Persist/Class/PersistEntity.hs`][pentity]):

> _"Persistent serialized Haskell records to the database. A Database 'Entity' (A row in SQL, a
> document in MongoDB, etc) corresponds to a 'Key' plus a Haskell record. … For every Haskell record
> type stored in the database there is a corresponding 'PersistEntity' instance. An instance of
> PersistEntity contains meta-data for the record."_

`persistent` _"automatically generates an ID column for you, if you don't specify one"_
([`Database/Persist/Quasi.hs`][pquasi]) — the default `Key` is a backend auto-increment `Int64`,
overridable with an `Id` line, a `Primary` natural/composite key, or a custom type. A generated
type-level check, `SafeToInsert`, even rejects `insert` on an entity whose primary key has no default,
forcing `insertKey` instead ([`Database/Persist/Class/PersistEntity.hs`][pentity]).

**Auto-migration.** `mkMigrate "migrateAll"` builds a `Migration` value; `runMigration migrateAll`
diffs the declared schema against the live database and applies `CREATE`/`ALTER`. A `Migration` is a
writer stack that accumulates a `CautiousMigration = [(Bool, Sql)]`, where the `Bool` flags whether a
step is _unsafe_ (destructive) ([`Database/Persist/Sql/Migration.hs`][pmig]):

> _"A list of SQL operations, marked with a safety flag. If the `Bool` is `True`, then the operation
> is unsafe — it might be destructive, or otherwise not idempotent. If the `Bool` is `False`, then
> the operation is safe, and can be run repeatedly without issues."_

`runMigration` runs the safe steps but refuses the dangerous ones ([`Database/Persist/Sql/Migration.hs`][pmig]):

> _"Runs a migration. If the migration fails to parse or if any of the migrations are unsafe, then
> this throws a 'PersistUnsafeMigrationException'."_

To apply a destructive change you must opt in with `runMigrationUnsafe`, or inspect the plan first
with `showMigration`/`printMigration`. This is strictly **code-first**: the entity definitions are the
single source of truth, migrations are derived, and there is **no db-first introspection / codegen**
(unlike `jOOQ`/`sqlc`). The schema DSL is rich — nullability, `default=`, `sqltype=`, unique keys,
`Primary`/composite keys, `Foreign` keys with `OnDelete`/`OnUpdate` actions, sum-type entities, and
Haddock-style doc comments are all documented in the `Quasi` module ([`Database/Persist/Quasi.hs`][pquasi]).
`esqueleto` contributes **no** schema or migration machinery of its own — it consumes persistent's
generated `EntityField`/`PersistEntity` instances directly, which is what "works with unmodified
persistent SQL backends" means.

## Type mapping and result decoding

Every stored type is a `PersistField`, mapping a Haskell value to/from a `PersistValue` (the backend's
tagged cell type) via `toPersistValue`/`fromPersistValue`. An entity's row round-trips through
`toPersistFields :: record -> [PersistValue]` and `fromPersistValues :: [PersistValue] -> Either Text
record` ([`Database/Persist/Class/PersistEntity.hs`][pentity]) — note the `Either Text`, so a
[decode][typemap] failure is a value, surfaced by the runner as a `PersistMarshalError`. The
Haskell↔SQL default mapping (e.g. `Text → VARCHAR`, `Int → INT8`/`BIGINT`, `UTCTime → TIMESTAMP`, and
`ZonedTime` dropped since persistent 2.0) is tabulated in the TH docs and customizable per column with
`sqltype=` ([`Database/Persist/Quasi.hs`][pquasi]).

**Nullability is in the type.** A `Maybe`-suffixed field becomes `Maybe a` in the record, and on the
query side esqueleto tracks it structurally: `(^.)` yields `SqlExpr (Value typ)` but `(?.)` yields
`SqlExpr (Value (Maybe (Nullable typ)))`, and an outer-joined table is `SqlExpr (Maybe (Entity a))`
that `select` returns as `Maybe (Entity a)` ([`Database/Esqueleto/Internal/Internal.hs`][eint]). `just`
lifts a non-null expression into a nullable one (`just (val 18)`), so comparing an optional column to a
constant is type-checked rather than silently coerced.

**Row hydration.** persistent's own reads hydrate to `Entity record` (a `Key` plus the record) or to
the record; esqueleto's `select` is polymorphic in the return shape via the `SqlSelect a r` class
([`Database/Esqueleto/Internal/Internal.hs`][eint]):

> _"You may return a `SqlExpr (Entity v)` … returned to Haskell-land as just `Entity v`. … You may
> return a `SqlExpr (Maybe (Entity v))` … as `Maybe (Entity v)`. Used for `OUTER JOIN`s. … You may
> return a `SqlExpr (Value t)` … as `Value t`."_

`SqlSelect`'s functional dependencies flow type information both ways, which is why _"you'll almost
never have to give any type signatures for `esqueleto` queries."_ There is no ORM-style object graph
here: a join returns a **tuple** of entities, and relations are made explicit in the query — the
functional-mapper way to sidestep the [N+1 problem][nplusone] rather than lazy-load it.

## Effect model, transactions & error handling

This is the dimension the survey weights most, and where persistent+esqueleto differ from the
effect-system flagships.

**Blocking `ReaderT`, not an effect value.** A database action is a `SqlPersistT m a = ReaderT
SqlBackend m a`, run with `runSqlConn`/`runSqlPool` ([`Database/Persist/Sql/Types.hs`][ptypes],
[`Database/Persist/Sql/Run.hs`][prun]). It is **not** a first-class [effect description][effects] like
doobie's `ConnectionIO` or a `ZIO`/`Effect` value; it is a reader over the connection that executes as
soon as the surrounding `IO` runs. Concurrency is ordinary Haskell (`MonadUnliftIO`, green threads),
not a fiber runtime. persistent's actions and esqueleto's queries share this one monad, so they
interleave freely:

```haskell
main :: IO ()
main = runSqlite ":memory:" $ do
    runMigration migrateAll          -- persistent: auto-migrate
    johnId <- insert $ Person "John" (Just 35)   -- insert :: record -> ReaderT backend m (Key record)
    people <- E.select $ do          -- esqueleto: typed query, same monad
      p <- E.from $ E.table @Person
      E.where_ (p E.^. PersonId E.==. E.val johnId)
      pure p
    liftIO $ print (people :: [Entity Person])
```

`insert` returns the freshly-minted `Key record` ([`Database/Persist/Class/PersistStore.hs`][pstore]);
`get :: Key record -> ReaderT backend m (Maybe record)` looks a row up by primary key. esqueleto's
`select :: SqlQuery a -> ReaderT backend m [r]` runs inside the same `ReaderT`
([`Database/Esqueleto/Internal/Internal.hs`][eint]).

**Transactions bracket the runner, not a combinator.** There is no `withTransaction` block — the
transaction boundary _is_ the `runSqlConn`/`runSqlPool` call. `rawAcquireSqlConn` brackets the action
with `connBegin` on acquire and `connCommit` on normal release / `connRollback` on exception
([`Database/Persist/Sql/Run.hs`][prun]):

> _"Starts a new transaction on the connection. When the acquired connection is released the
> transaction is committed and the connection returned to the pool. Upon an exception the transaction
> is rolled back and the connection destroyed."_

Within a transaction you can force a boundary manually: `transactionSave` _"Commit[s] the current
transaction and begin[s] a new one"_, and `transactionUndo` _"Roll[s] back the current transaction and
begin[s] a new one. This rolls back to the state of the last call to 'transactionSave' or the enclosing
'runSqlConn' call"_ ([`Database/Persist/Sql.hs`][psql]). Note these are **commit/rollback + begin**, not
`SAVEPOINT`s — the base persistent API has **no nested-transaction / savepoint** primitive (individual
backends and `runSqlPoolWithIsolation` add [isolation levels][effects], and a savepoint concept lives in
backend packages, not the core). Nesting `runSqlConn` inside `runSqlConn` opens a second `BEGIN` on a
second connection rather than a savepoint.

**Errors are exceptions, not a typed channel.** persistent's failures are thrown, not returned:
`PersistException` (`PersistError`, `PersistMarshalError`, `PersistForeignConstraintUnmet`, …) and
`PersistentSqlException` are `Exception` instances ([`Database/Persist/Types/Base.hs`][pbase],
[`Database/Persist/Sql/Types.hs`][ptypes]); esqueleto's `OnClauseWithoutMatchingJoinException` likewise
([`Database/Esqueleto/Internal/Internal.hs`][eint]). Only the _lower-level_ conversions return
`Either Text` (`fromPersistValues`, `keyFromValues`). So unlike [Ecto][effects]'s `{:ok, _}`/`{:error, _}`
tuples or doobie's typed error type, the failure set is **not** reflected in the action's type — you
catch `SomeException` at the edge. This is the conventional Haskell-`IO` posture, and the main axis on
which this pair sits below the effect-system libraries the survey is designed around.

## Ecosystem & maturity

`persistent` is the storage layer of the **Yesod** web framework and one of the most-depended-upon
database libraries on Hackage (web-attested); it is authored by Michael Snoyman and maintained under
the `yesodweb` org, licensed **MIT** ([`persistent.cabal`][pcabal], `LICENSE` dated 2012). The pinned
tree is `2.18.1.0` ([`persistent.cabal`][pcabal], [`ChangeLog.md`][pchangelog]). Its backend-agnostic
core is realized as sibling packages in the monorepo — `persistent-postgresql`, `persistent-sqlite`,
`persistent-mysql`, plus `persistent-mongoDB` and `persistent-redis` (the last two filling only the
key-value `PersistStore` portion of the API, not `PersistQuery`) ([`README.md`][preadme]). The `README`
is candid that _"The MySQL backend is in need of a maintainer"_ and that MongoDB migrations/composite
keys are limited ([`README.md`][preadme]).

`esqueleto` was created by Felipe Lessa (_"inspired by Scala's Squeryl but created from scratch"_) and
is now maintained under the `bitemyapp` org, licensed **BSD-3-Clause**; the pinned tree is `3.6.0.0`
([`esqueleto.cabal`][ecabal], [`changelog.md`][echangelog]). It works with any unmodified persistent
SQL backend and ships RDBMS-specific modules for PostgreSQL, MySQL, and SQLite. Both libraries date to
2012 and are stable, widely-used, production-grade infrastructure in the Haskell web ecosystem
(web-attested for adoption).

## Strengths

- **Compile-time schema safety from one source.** A single QuasiQuote block generates entity types,
  `Key`/`EntityField` GADTs, `PersistEntity` instances, and migrations — a column typo, a wrong field
  type, or an unsafe `insert` (`SafeToInsert`) is a compile error ([`Database/Persist/Quasi.hs`][pquasi],
  [`Database/Persist/Class/PersistEntity.hs`][pentity]).
- **Code-first auto-migration with a safety flag.** `runMigration` applies the derived schema diff and
  _refuses_ destructive steps by default (`CautiousMigration`, `PersistUnsafeMigrationException`)
  ([`Database/Persist/Sql/Migration.hs`][pmig]).
- **Backend-agnostic core.** The same entities serialize to PostgreSQL, SQLite, MySQL, or (for the
  key-value subset) MongoDB/Redis ([`Database/Persist.hs`][ppersist], [`README.md`][preadme]).
- **Injection-safe by construction on both layers.** persistent filters bind values as `FilterValue`;
  esqueleto's `val` compiles to a `?` parameter; even `rawSql` binds `?` placeholders
  ([`Database/Persist.hs`][ppersist], [`Database/Esqueleto/Internal/Internal.hs`][eint], [`README.md`][ereadme]).
- **Full relational power, type-checked.** esqueleto adds joins, sub-selects, aggregates, `UNION`/`EXCEPT`,
  and CTEs, with nullability in the type; the experimental `(:&)` join syntax moves missing-`on` and
  outer-join-`Maybe` bugs to compile time ([`Database/Esqueleto/Experimental.hs`][eexp]).
- **Predictable SQL.** esqueleto's stated goal is that you can read a query and know the SQL it emits;
  RDBMS-specific modules expose engine features rather than hiding them ([`README.md`][ereadme]).
- **The two compose cleanly.** Same schema, same `SqlPersistT` monad, same transaction bracket — mix
  persistent CRUD and esqueleto queries in one action.

## Weaknesses

- **No effect value / no typed error channel.** Actions are a blocking `ReaderT SqlBackend`, and
  failures are thrown `PersistException`/`OnClauseWithoutMatchingJoinException`, not carried in the type
  — the opposite of doobie/[Effect TS][effects] ([`Database/Persist/Types/Base.hs`][pbase]).
- **persistent's query API is intentionally crippled.** Single-table filters only; **no joins** — you
  must reach for esqueleto (or `rawSql`) for anything relational, by design ([`README.md`][preadme]).
- **Not a full ORM despite the schema/migration ownership.** No [change tracking][orm], no
  [unit of work][orm], no [lazy loading][nplusone]; relations are explicit joins returning tuples.
- **No savepoints / nested transactions in core.** `transactionSave`/`transactionUndo` are commit/begin
  and rollback/begin, not `SAVEPOINT`s ([`Database/Persist/Sql.hs`][psql]).
- **Template-Haskell heaviness.** The schema is a TH/QuasiQuote program (needs `TemplateHaskell`,
  `QuasiQuotes`, `GADTs`, `TypeFamilies`, `DataKinds`, …); errors can be opaque, and TH slows compiles.
- **esqueleto's unsafe hatch re-opens injection.** `unsafeSqlFunction`/`unsafeSqlValue` splice text
  verbatim — user input there is a live SQL-injection hazard ([`README.md`][ereadme]).
- **Legacy join syntax is runtime-error-prone.** The pre-experimental `from`/`on` throws
  `OnClauseWithoutMatchingJoinException` at runtime; the experimental module is not yet the default
  (until `4.0.0.0`) ([`Database/Esqueleto/Internal/Internal.hs`][eint], [`Database/Esqueleto/Experimental.hs`][eexp]).
- **No db-first codegen.** Code-first only; there is no introspection/scaffolding from a live database.

## Key design decisions and trade-offs

| Decision                                                                    | Rationale                                                                                         | Trade-off                                                                                                             |
| --------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| Schema as a Template-Haskell QuasiQuote block generating types + migrations | One source of truth; compile-time-checked entities, keys, and filters; auto-migration             | TH/QuasiQuote weight; opaque errors; slower compiles; code-first only (no db-first codegen)                           |
| Backend-agnostic serialization core                                         | Same entities target SQL and NoSQL backends                                                       | The universal API can't offer joins/SQL features — a deliberate limitation the `README` states outright               |
| Query API = single-table typed filters (`[PersonAge >. 30]`)                | Small, injection-safe, compile-checked CRUD covering the common case                              | No joins/sub-selects/aggregates in persistent itself; esqueleto (or `rawSql`) is mandatory for relational work        |
| esqueleto as a **separate** typed EDSL over the same schema                 | Restores type-safe joins/CTEs/set-ops; composes with persistent unchanged                         | Two libraries and two query surfaces to learn; identifier clashes need qualified imports                              |
| `val` / `FilterValue` bind every value as a `?` parameter                   | Injection impossible for values, on both layers                                                   | Escape hatches (`rawSql` text, esqueleto `unsafeSql*`) re-expose risk; `unsafeSql*` splices verbatim                  |
| `(:&)` experimental join with `on` attached to each join                    | Moves missing-`on` and outer-join-`Maybe` bugs from runtime to compile time; enables `UNION`/CTEs | Not the default until `4.0.0.0`; legacy `from`/`on` still throws `OnClauseWithoutMatchingJoinException`               |
| Effect model = blocking `ReaderT SqlBackend` over `IO`                      | Simple, unsurprising; transaction = the `runSqlConn`/`runSqlPool` bracket; composes with `IO`     | No effect value, no typed error channel, no savepoints in core — below the effect-system libraries the survey targets |
| Auto-migration refuses unsafe steps unless opted in                         | Prevents accidental data loss (`CautiousMigration` safe/unsafe flag)                              | Destructive changes need `runMigrationUnsafe`; migrations are derived, not hand-audited by default                    |

---

## Sources

- [yesodweb/persistent — GitHub repository][prepo] · [bitemyapp/esqueleto — GitHub repository][erepo]
- [`persistent/README.md` — "A Haskell datastore", "catch every possible error at compile-time", "does not directly provide joins … use Esqueleto", backend list][preadme]
- [`persistent.cabal` — MIT, synopsis "Type-safe, multi-backend data serialization", version 2.18.1.0][pcabal] · [`ChangeLog.md`][pchangelog]
- [`Database/Persist/Quasi.hs` — the schema QuasiQuote syntax, auto-generated ID, nullability, defaults, foreign/composite keys][pquasi]
- [`Database/Persist/TH/Internal.hs` — `mkPersist`/`mkPersistWith`, `share`, `mkMigrate`/`migrateModels`][pth]
- [`Database/Persist/Class/PersistEntity.hs` — `PersistEntity` class, `Key`/`EntityField`/`Entity`, `Filter`/`FilterValue`/`SelectOpt`, `SafeToInsert`][pentity]
- [`Database/Persist.hs` — module doc + the filter/update operators (`==.`, `>.`, `<-.`, `||.`, `=.`)][ppersist]
- [`Database/Persist/Class/PersistStore.hs` — `insert`/`get`][pstore]
- [`Database/Persist/Sql/Types.hs` — `SqlPersistT`/`SqlPersistM`, `ConnectionPool`/`ConnectionPoolConfig`, `PersistentSqlException`][ptypes]
- [`Database/Persist/Sql/Run.hs` — `runSqlConn`/`runSqlPool`, `rawAcquireSqlConn` transaction bracket, pool lifetime][prun]
- [`Database/Persist/Sql/Migration.hs` — `Migration`/`CautiousMigration`, `runMigration`, `PersistUnsafeMigrationException`][pmig]
- [`Database/Persist/Sql.hs` — `transactionSave`/`transactionUndo`][psql] · [`Database/Persist/Sql/Raw.hs` — `rawSql` `?`/`??` placeholders][praw]
- [`Database/Persist/Types/Base.hs` — `PersistException`][pbase]
- [`esqueleto/README.md` — "bare bones, type-safe EDSL", "recommended library for type-safe JOINs", injection section, unsafe-function warning, join examples][ereadme]
- [`esqueleto.cabal` — BSD3, synopsis + description, version 3.6.0.0][ecabal] · [`changelog.md`][echangelog]
- [`Database/Esqueleto.hs` — top-level EDSL module doc + goals][emod]
- [`Database/Esqueleto/Experimental.hs` — the `(:&)` join syntax, "runtime errors now caught at compile time", set operations/CTEs][eexp]
- [`Database/Esqueleto/Internal/Internal.hs` — `SqlQuery`/`SqlExpr`, `where_`/`on`/`(^.)`/`(?.)`, `val` = `?` parameter, `select`, `OnClauseWithoutMatchingJoinException`][eint]
- Shared vocabulary: [SQL & ORM concepts][concepts] ([abstraction ladder][ladder] · [query models][qcm] · [injection][inject] · [schema & migrations][schema] · [ORM patterns][orm] · [N+1][nplusone] · [type mapping][typemap] · [effects & transactions][effects] · [pools][pool])
- Related deep-dives in this survey (by name; pages may not exist yet): `Beam`, `Squeal`, `Opaleye`, `hasql`, `doobie`, `Ecto`

<!-- References -->

[prepo]: https://github.com/yesodweb/persistent
[erepo]: https://github.com/bitemyapp/esqueleto
[phackage]: https://hackage.haskell.org/package/persistent
[ehackage]: https://hackage.haskell.org/package/esqueleto
[ybook]: https://www.yesodweb.com/book/persistent
[preadme]: https://github.com/yesodweb/persistent/blob/master/README.md
[pcabal]: https://github.com/yesodweb/persistent/blob/master/persistent/persistent.cabal
[pchangelog]: https://github.com/yesodweb/persistent/blob/master/persistent/ChangeLog.md
[pquasi]: https://github.com/yesodweb/persistent/blob/master/persistent/Database/Persist/Quasi.hs
[pth]: https://github.com/yesodweb/persistent/blob/master/persistent/Database/Persist/TH/Internal.hs
[pentity]: https://github.com/yesodweb/persistent/blob/master/persistent/Database/Persist/Class/PersistEntity.hs
[ppersist]: https://github.com/yesodweb/persistent/blob/master/persistent/Database/Persist.hs
[pstore]: https://github.com/yesodweb/persistent/blob/master/persistent/Database/Persist/Class/PersistStore.hs
[ptypes]: https://github.com/yesodweb/persistent/blob/master/persistent/Database/Persist/Sql/Types.hs
[prun]: https://github.com/yesodweb/persistent/blob/master/persistent/Database/Persist/Sql/Run.hs
[pmig]: https://github.com/yesodweb/persistent/blob/master/persistent/Database/Persist/Sql/Migration.hs
[psql]: https://github.com/yesodweb/persistent/blob/master/persistent/Database/Persist/Sql.hs
[praw]: https://github.com/yesodweb/persistent/blob/master/persistent/Database/Persist/Sql/Raw.hs
[pbase]: https://github.com/yesodweb/persistent/blob/master/persistent/Database/Persist/Types/Base.hs
[ereadme]: https://github.com/bitemyapp/esqueleto/blob/master/README.md
[ecabal]: https://github.com/bitemyapp/esqueleto/blob/master/esqueleto.cabal
[echangelog]: https://github.com/bitemyapp/esqueleto/blob/master/changelog.md
[emod]: https://github.com/bitemyapp/esqueleto/blob/master/src/Database/Esqueleto.hs
[eexp]: https://github.com/bitemyapp/esqueleto/blob/master/src/Database/Esqueleto/Experimental.hs
[eint]: https://github.com/bitemyapp/esqueleto/blob/master/src/Database/Esqueleto/Internal/Internal.hs
[concepts]: ./concepts.md
[ladder]: ./concepts.md#the-abstraction-ladder
[qcm]: ./concepts.md#query-construction-models
[inject]: ./concepts.md#statements-parameters-and-sql-injection
[schema]: ./concepts.md#schema-migrations-code-generation
[orm]: ./concepts.md#orm-patterns
[nplusone]: ./concepts.md#loading-strategies-and-the-n1-problem
[typemap]: ./concepts.md#type-mapping-and-result-decoding
[effects]: ./concepts.md#effects-transactions-and-error-handling
[pool]: ./concepts.md#connections-pools-and-sessions
