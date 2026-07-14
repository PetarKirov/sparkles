# Opaleye (Haskell)

Haskell's profunctor-and-arrow relational-algebra EDSL for PostgreSQL: a query is a `Select`/`SelectArr` value — an arrow from input columns to output columns — whose column references and SQL types are checked by the compiler, that reifies to a relational-algebra AST, renders to SQL, and executes on top of [`postgresql-simple`][pgsimple].

| Field              | Value                                                                                                                                           |
| ------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| Language           | Haskell (`Haskell2010`; `MultiParamTypeClasses` + `FlexibleContexts` + `FlexibleInstances`; tested GHC 8.8 – 9.12) ([`opaleye.cabal`][cabal])   |
| License            | BSD-3-Clause — © 2014–2018 Purely Agile Limited; 2019–2026 Tom Ellis ([`LICENSE`][license], [`opaleye.cabal`][cabal])                           |
| Repository         | [tomjaguarpaw/haskell-opaleye][repo]                                                                                                            |
| Documentation      | [Hackage haddocks][hackage] · in-repo [`Doc/Tutorial/`][docdir] (basic, manipulation, `Default` explanation) · [`Doc/Design/DESIGN.md`][design] |
| Category           | [Typed query builder][ladder] — a typed [relational algebra][qmodels] built on **profunctors** and **arrows**                                   |
| Abstraction level  | Typed query builder / functional-relational — above a driver, below a full ORM ([ladder][ladder])                                               |
| Query model        | [Typed relational algebra][qmodels]: a `Select`/`SelectArr` arrow reified to a `PrimQuery` AST, then printed to SQL                             |
| Effect/async model | **Blocking `IO`** — `runSelect`/`runInsert` take a `postgresql-simple` `Connection`; no effect value, no async, no transaction layer of its own |
| Backends           | **PostgreSQL** (the synopsis is "An SQL-generating DSL targeting PostgreSQL"; a minimal `opaleye-sqlite` companion lives in-repo)               |
| First release      | ≈2014–2015 (copyright runs from 2014; the `0.3` line is the earliest in the changelog) — web/soft                                               |
| Latest version     | `0.10.8.0` (the pinned checkout; [`opaleye.cabal`][cabal], [`CHANGELOG.md`][changelog])                                                         |

> [!NOTE]
> Opaleye is this survey's data point for the **profunctor/arrow** flavour of a [typed relational
> algebra][qmodels]. Where `Slick` lifts collection operations into a `Rep[T]` embedding and
> `Squeal` pushes the whole schema into the type level, Opaleye models a `SELECT` as a
> _composable arrow_ `SelectArr a b` and drives both field mapping and result decoding through one
> typeclass — `Default` from `product-profunctors`. Crucially it is only the **query layer**:
> it owns no connection pool, no transaction abstraction, and no effect type — execution delegates
> to [`postgresql-simple`][pgsimple] in `IO`. That places it a rung below the effect-system mappers
> (`doobie`, `skunk`, `Effect TS`) this survey weights most heavily. Compare with the
> type-level-schema `Squeal` and the code-first `Beam`.

---

## Overview

### What it solves

Opaleye's design document opens with a list of grievances against writing SQL by hand or by string
concatenation ([`Doc/Design/DESIGN.md`][design]):

> _"It's very heavyweight to abstract over anything in SQL. … This means it's very hard to reuse
> code."_

and, most pointedly for a typed library:

> _"Although you can generate SQL strings at runtime you can't know at compile time that your SQL is
> syntactically correct."_

Opaleye's answer is an **SQL-generating embedded domain-specific language**. Its cabal synopsis is
terse ([`opaleye.cabal`][cabal]): _"An SQL-generating DSL targeting PostgreSQL"_. The README expands
the pitch ([`README.md`][readme]):

> _"Opaleye is a Haskell library that provides an SQL-generating embedded domain specific language
> for targeting Postgres. You need Opaleye if you want to use Haskell to write typesafe and
> composable code to query a Postgres database."_

You describe your **already-existing** Postgres tables in Haskell, build queries against them as
ordinary Haskell values, and hand those values to a runner that generates SQL and executes it. The
library descends from **HaskellDB** (Daan Leijen et al.) and was founded by Tom Ellis, _"inspired by
theoretical work on databases by David Spivak"_ ([`README.md`][readme]).

### Design philosophy

The headline promise is **compile-time soundness of the generated SQL** ([`README.md`][readme]):

> _"Opaleye allows you to define your database tables and write queries against them in Haskell
> code, and aims to be typesafe in the sense that if your code compiles then the generated SQL query
> will not fail at runtime. A wide range of SQL functionality is supported including inner and outer
> joins, restriction, aggregation, distinct, sorting and limiting, unions and differences.
> Facilities to insert to, update and delete from tables are also provided. Code written using
> Opaleye is composable at a very fine level of granularity, promoting code reuse and high levels of
> abstraction."_

Two claims in that paragraph carry the whole design. **Type-safety-to-runtime**: the type of a
`Select` records the SQL type of every one of its fields, so a mistyped comparison or a reference to
a non-existent column is a _compile error_, not a runtime `SqlError`. And **fine-grained
composability**: because a query is a first-class arrow value, sub-queries and even bare restrictions
can be named, reused, and glued together (see [Query construction](#query-construction--injection-safety)).
The tutorial singles out one payoff ([`Doc/Tutorial/TutorialBasic.lhs`][tutbasic]):

> _"Type safe aggregation is the jewel in the crown of Opaleye. Even SQL generating APIs which are
> otherwise type safe often fall down when it comes to aggregation."_

The machinery that makes all of this ergonomic is a single typeclass. The `Default` explanation
tutorial is unusually candid about it ([`Doc/Tutorial/DefaultExplanation.lhs`][defaultexpl]):

> _"Instances of `ProductProfunctor` are very common in Opaleye. … The `Default` typeclass from
> product-profunctors is used throughout Opaleye to avoid API users having to write a lot of
> automatically derivable code, and it deserves a thorough explanation."_

That the library ships a whole tutorial devoted to `Default`/`ProductProfunctor` is itself the
central trade-off: the power (one uniform mechanism for schema mapping, encoding, decoding, joins,
and unions) is bought with a type-machinery learning curve and famously baffling type errors when an
instance can't be resolved.

---

## Connection, pooling & resource lifetime

Opaleye has **no connection or pool abstraction of its own**. Every runner takes a bare
[`postgresql-simple`][pgsimple] `Connection` and returns an `IO` action
([`src/Opaleye/RunSelect.hs`][runselect]):

```haskell
-- src/Opaleye/RunSelect.hs
runSelect :: D.Default FromFields fields haskells
          => PGS.Connection
          -> S.Select fields
          -> IO [haskells]
runSelect = RQ.runQuery
```

There is no `Transactor` (as in `doobie`), no self-managed socket and pool (as in `skunk`), and no
scoped `Resource`. Acquiring a `Connection`, pooling it (with e.g. `resource-pool`), and closing it
are entirely the caller's responsibility and postgresql-simple's domain. This is the concrete
consequence of Opaleye being _only_ the query layer: it sits above the [driver][pools] but delegates
the connection lifetime wholesale, so a leaked connection is neither prevented nor tracked by
Opaleye.

For large result sets Opaleye offers streaming, but still in `IO` and still on a caller-supplied
connection: `runSelectFold` consumes rows with a left fold, and a Postgres cursor interface
(`declareCursor`/`foldForward`/`closeCursor`) reads them in chunks — with an explicit strictness
caveat ([`src/Opaleye/RunSelect.hs`][runselect]):

> _"This fold is /not/ strict. The stream consumer is responsible for forcing the evaluation of its
> result to avoid space leaks."_

---

## Query construction & injection safety

### `Select` and `SelectArr`: the query is an arrow

The two load-bearing types are `Select` and `SelectArr`. A `SelectArr a b` is a query _parameterised_
by an input `a` — literally an arrow from input columns to output columns
([`src/Opaleye/Select.hs`][select], [`src/Opaleye/Internal/QueryArr.hs`][queryarr]):

```haskell
-- src/Opaleye/Internal/QueryArr.hs
-- | A parametrised 'Select'.  A @SelectArr a b@ accepts an argument
-- of type @a@.
--
-- @SelectArr a b@ is analogous to a Haskell function @a -> [b]@.
newtype SelectArr a b = QueryArr { unQueryArr :: a -> State Tag (b, PQ.PrimQueryArr) }

-- | A @SELECT@ … @Select a@ is analogous to a Haskell value @[a]@.
type Select = SelectArr ()
```

So `Select a` — the runnable form — is just `SelectArr () a`: a query taking no input and producing
rows of `a`, "analogous to a Haskell value `[a]`". `SelectArr` is given the full complement of
composition instances — `Category`, `Arrow`, `ArrowChoice`, `ArrowApply`, plus `Functor`,
`Applicative`, `Monad`, `Profunctor` and `ProductProfunctor` ([`src/Opaleye/Internal/QueryArr.hs`][queryarr]):

```haskell
-- src/Opaleye/Internal/QueryArr.hs
instance C.Category QueryArr where
  id = arr id
  QueryArr f . QueryArr g = QueryArr $ \a -> do
    (b, pqf)  <- g a
    (c, pqf') <- f b
    pure (c, pqf <> pqf')

instance Arr.Arrow QueryArr where
  arr f   = QueryArr (\a -> pure (f a, mempty))
  first (QueryArr f) = QueryArr g
    where g (b, d) = do { (c, pq) <- f b; pure ((c, d), pq) }
```

Because `QueryArr` is both an `Arrow` and a `Monad`, you can write queries in **arrow notation**
(`proc`/`-<`, composing with `<<<`) or in **`do`-notation**. Restriction shows both idioms — one
combinator for each ([`src/Opaleye/Operators.hs`][operators]):

```haskell
-- src/Opaleye/Operators.hs
-- | You would typically use 'restrict' if you want to write your query
-- using 'A.Arrow' notation.  If you want to use monadic style
-- then 'where_' will suit you better.
restrict :: S.SelectArr (F.Field T.SqlBool) ()
restrict = O.restrict

where_ :: F.Field T.SqlBool -> S.Select ()
where_ = L.viaLateral restrict
```

A representative query in `do`-notation, straight from the tutorial — select people, keep only the
twenty-somethings at a given address ([`Doc/Tutorial/TutorialBasic.lhs`][tutbasic]):

```haskell
-- Doc/Tutorial/TutorialBasic.lhs
twentiesAtAddress :: Select (Field SqlText, Field SqlInt4, Field SqlText)
twentiesAtAddress = do
  row@(_, age, address) <- personSelect
  where_ $ (20 .<= age) .&& (age .< 30)
  where_ $ address .== sqlString "1 My Street, My Town"
  pure row
```

The "fine-grained composability" claim is concrete: a bare restriction is itself a value of type
`SelectArr a ()` ("reads fields of type `a` but returns none"), so the two `where_`s above can be
factored into named, reusable pieces and recombined, generating _identical_ SQL
([`Doc/Tutorial/TutorialBasic.lhs`][tutbasic]):

```haskell
-- Doc/Tutorial/TutorialBasic.lhs
restrictIsTwenties :: Field SqlInt4 -> Select ()
restrictIsTwenties age = where_ $ (20 .<= age) .&& (age .< 30)

twentiesAtAddress' = do
  row@(_, age, address) <- personSelect
  restrictIsTwenties age
  restrictAddressIs1MyStreet address
  pure row
```

Products (Cartesian joins), inner joins (product + `where_`), left joins (`optional`, yielding a
`MaybeFields a`), aggregation, ordering, and `LIMIT`/`OFFSET` all compose the same way. The design
doc frames the underlying identity precisely ([`Doc/Design/DESIGN.md`][design]): _"A `Select` is a
collection of rows … if we have two of them we can form their Cartesian product. This corresponds
exactly to Haskell's `Applicative` product on lists."_

### `Field_`: typed SQL expressions

A column/expression is a `Field_`, carrying its **nullability** (a `DataKinds` promoted enum) and its
**SQL type** as phantom type parameters over a single opaque AST node
([`src/Opaleye/Internal/Column.hs`][column]):

```haskell
-- src/Opaleye/Internal/Column.hs
data Nullability = NonNullable | Nullable

-- | A field of a @Select@, of type @sqlType@.
newtype Field_ (n :: Nullability) sqlType = Column HPQ.PrimExpr

type Field         = Field_ NonNullable
type FieldNullable = Field_ 'Nullable
```

Every operator is typed against those phantoms and, at the value level, merely builds an AST node.
Equality is `Field a -> Field a -> Field SqlBool` — both operands must share the SQL type `a`, and
the result is a boolean expression, not a Haskell `Bool` ([`src/Opaleye/Operators.hs`][operators],
[`src/Opaleye/Internal/Column.hs`][column]):

```haskell
-- src/Opaleye/Operators.hs
(.==) :: Field a -> Field a -> F.Field T.SqlBool
(.==) = C.binOp (HPQ.:==)

-- src/Opaleye/Internal/Column.hs
binOp :: HPQ.BinOp -> Field_ n a -> Field_ n' b -> Field_ n'' c
binOp op (Column e) (Column e') = Column (HPQ.BinExpr op e e')
```

Comparing a `Field SqlInt4` with a `Field SqlText`, or naming a column that the table description
does not expose, is therefore a type error before any SQL is generated. The tutorial's `Warehouse`
example weaponises this with `newtype`s: wrapping an integer id in a `WarehouseId'` phantom makes
`wId w .== wNumGoods w` fail to compile — _"Couldn't match type `WarehouseId' (Field SqlInt4)` with
`Field SqlInt4`"_ ([`Doc/Tutorial/TutorialBasic.lhs`][tutbasic]) — the same [phantom-type][qmodels]
technique `Squeal` and `Slick` rely on.

### The query is a reified relational-algebra AST

Building a `Select` accumulates a `PrimQuery` — an algebra of relational operators
([`src/Opaleye/Internal/PrimQuery.hs`][primquery]): `Unit`, `BaseTable`, `Product`, `Aggregate`,
`Join` (`LeftJoin`/`RightJoin`/`FullJoin`), `Semijoin` (`Semi`/`Anti`), `Limit`, `Exists`, `Values`,
`Label`, `Rebind`, and the binary set ops (`Union`/`Except`/`Intersect`). That tree is optimized and
printed to SQL, and you can inspect the result without a database ([`src/Opaleye/Sql.hs`][sql]):

```haskell
-- src/Opaleye/Sql.hs
showSql :: D.Default U.Unpackspec fields fields => S.Select fields -> Maybe String
```

(`Nothing` means the `Select` is statically known to return zero rows.) Reifying the query as data is
what lets Opaleye optimize the tree and aim at readable output — the tutorial pairs every generated
query with an "idealized" hand-written equivalent to show how close the two are.

### Injection safety: structural, via escaped literals rather than bind parameters

Opaleye is injection-safe, but the mechanism differs from the prepared-statement
[parameter binding][injection] most of this survey uses. There are **two** structural facts, and it
is worth being precise about them.

First, **there is no string-building surface at all.** You never concatenate SQL text; a Haskell
value can only enter a query by being turned into a typed `Field`, via `toFields`, the numeric `Num`
instance, or a per-type constructor such as `sqlStrictText`/`sqlString`/`sqlInt4`
([`src/Opaleye/SqlTypes.hs`][sqltypes]). The `Field_` type is the _only_ way an expression exists, and
its constructor is a `PrimExpr`, never a fragment of text you assembled. A stray Haskell `String` in a
predicate is a type error, not a splice point.

Second, **those literals are rendered as escaped Postgres string literals**, and the whole statement
is sent with **no bind parameters**. Execution uses postgresql-simple's _parameterless_ `queryWith_`
and `execute_` ([`src/Opaleye/Internal/RunQueryExternal.hs`][runqueryext],
[`src/Opaleye/Manipulation.hs`][manipulation]) — the SQL string is fully rendered, literals included.
A `String` becomes a `ConstExpr (StringLit …)` node that the printer emits through `quote`, which
uses Postgres escape-strings and doubles every quote ([`src/Opaleye/Internal/HaskellDB/Sql/Default.hs`][sqldefault]):

```haskell
-- src/Opaleye/Internal/HaskellDB/Sql/Default.hs
quote :: String -> String
quote s = "E'" ++ concatMap escape s ++ "'"

escape :: Char -> String
escape '\'' = "''"
escape '"'  = "\\\""
escape '\\' = "\\\\"
-- … (control chars → \b \n \r \t, non-printables → \Uxxxxxxxx)
```

So a hostile input becomes an _inert, correctly-escaped SQL literal_ — it cannot change the query's
structure. The safety comes from **non-interpolation plus literal escaping**, not from the out-of-band
data channel a `$1` placeholder gives you. This is a genuine contrast with the tagged-template and
prepared-statement libraries in the survey (`skunk`, `Effect TS`, `postgres.js`): those
never render user data into SQL text at all, whereas Opaleye renders it but guarantees it renders as a
literal. The practical upshot is the same (injection is structurally impossible), but the reliance on
correct escaping — rather than protocol-level channel separation — is a design choice worth naming.

There is, correspondingly, **no raw-SQL escape hatch that re-opens injection.** The "unsafe" surface
is not string splicing but _type coercions_: `unsafeCoerceField`, `unsafeCast`, `unsafeFromField`, and
the `Internal.*` modules. Those let you lie about a column's type (risking a runtime SQL error), but
they never let you inject text.

---

## Schema, migrations & code generation

Opaleye is strictly **database-first**, and it says so ([`Doc/Tutorial/TutorialBasic.lhs`][tutbasic]):

> _"Opaleye assumes that a Postgres database already exists. Currently there is no support for
> creating databases or tables, though these features may be added later according to demand."_

You _describe_ an existing table with `table` and `tableField`; the description is a
`TableFields writeFields viewFields` — a **profunctor** whose two type parameters split the columns
you may _write_ from the columns you may _read_ ([`src/Opaleye/Table.hs`][table],
[`src/Opaleye/Internal/Table.hs`][inttable]):

```haskell
-- src/Opaleye/Table.hs
table :: String -> TableFields writeFields viewFields -> Table writeFields viewFields

-- src/Opaleye/Internal/Table.hs
data TableFields writeColumns viewColumns = TableFields
   { tablePropertiesWriter :: Writer writeColumns viewColumns
   , tablePropertiesView   :: View viewColumns }

instance ProductProfunctor TableFields where
  purePP = pure
  (****) = (<*>)
```

The write/read split is where Opaleye encodes column optionality and nullability
([`src/Opaleye/Table.hs`][table]): a `requiredTableField` gives
`TableFields (Field SqlInt4) (Field SqlInt4)` (you must supply it on writes), while an
`optionalTableField` gives `TableFields (Maybe (Field SqlInt4)) (Field SqlInt4)` — a `Nothing` write
emits SQL `DEFAULT`, so `SERIAL`/`DEFAULT` columns are omittable on insert. `tableField` infers which
you want from the write type. A tuple table is described with a size-indexed adaptor (`p2`, `p3`, …);
a record table with a Template-Haskell-derived adaptor ([`Doc/Tutorial/TutorialBasic.lhs`][tutbasic]):

```haskell
-- Doc/Tutorial/TutorialBasic.lhs
personTable :: Table (Field SqlText, Field SqlInt4, Field SqlText)
                     (Field SqlText, Field SqlInt4, Field SqlText)
personTable = table "personTable" (p3 ( tableField "name"
                                       , tableField "age"
                                       , tableField "address" ))

data Widget a b c d e = Widget { style :: a, color :: b, location :: c
                               , quantity :: d, radius :: e }
$(makeAdaptorAndInstanceInferrable "pWidget" ''Widget)
```

`selectTable :: Default Unpackspec fields fields => Table a fields -> Select fields` turns a table
description into a runnable `Select` ([`src/Opaleye/Table.hs`][table]).

What Opaleye does **not** provide is a finding in its own right. There is **no migration runner**, **no
DDL generation**, and **no introspection/code-generation** step — you hand-write the `Table`
descriptions to match a schema you evolve by other means. This is more minimal than `Slick`
(which ships `slick-codegen` database-first introspection) or `Squeal` (which carries the schema at
the type level _and_ a migration story). Opaleye owns the schema _description_ only, never its
_evolution_ — see [schema, migrations & code generation][schemamig] in the concepts page.

---

## Type mapping & result decoding

Every boundary crossing in Opaleye — Haskell → SQL literal, table column → field, SQL row → Haskell
value, two queries → a union — is a `ProductProfunctor`, and the `Default` typeclass supplies the
right one automatically. The `Default` tutorial motivates the pattern with `FromFields`
([`Doc/Tutorial/DefaultExplanation.lhs`][defaultexpl]): every operation has an explicit form taking a
profunctor value and a convenience form that derives it, so _"we don't have to explicitly specify"_ the
plumbing. In the general case, for a product type with _n_ parameters, the correct profunctor is
"automatically deduced" from the base instances via the product operation `(***!)`.

**Encoding (`ToFields`)** turns Haskell values into fields ([`src/Opaleye/Internal/Constant.hs`][constant]):

```haskell
-- src/Opaleye/Internal/Constant.hs
-- | A way of turning Haskell values of type @haskells@ into SQL fields.
newtype ToFields haskells fields = ToFields { constantExplicit :: haskells -> fields }

instance D.Default ToFields Int    (Field T.SqlInt4) where def = toToFields T.sqlInt4
instance D.Default ToFields ST.Text (Field T.SqlText) where def = toToFields T.sqlStrictText
```

`toFields :: Default ToFields haskells fields => haskells -> fields` is what you reach for to insert a
runtime value ([`src/Opaleye/ToFields.hs`][tofields]) — the manipulation tutorial notes that a
variable _"can't rely on the `Num` instance and must use `toFields`"_ ([`Doc/Tutorial/TutorialManipulation.lhs`][tutmanip]).

**Decoding (`FromFields`)** is the mirror image, and it is explicitly a wrapper over postgresql-simple's
row parser ([`src/Opaleye/Internal/RunQuery.hs`][runquery]):

```haskell
-- src/Opaleye/Internal/RunQuery.hs
-- | A 'FromFields' specifies how to convert Postgres values (@fields@)
--   into Haskell values (@haskells@).
data FromFields fields haskells =
   FromFields (U.Unpackspec fields ())
              (fields -> RowParser haskells)
              (fields -> Int)
```

The docstring pins the correspondence: _"`FromFields fields haskells` corresponds to
postgresql-simple's `RowParser haskells`"_, and `Default FromFields fields haskells` corresponds to a
`FromRow` ([`src/Opaleye/Internal/RunQuery.hs`][runquery]). The per-type decoders are a
`DefaultFromField` class, most instances just wrapping an existing postgresql-simple `FromField`:

```haskell
-- src/Opaleye/Internal/RunQuery.hs
class DefaultFromField sqlType haskellType where
  defaultFromField :: FromField sqlType haskellType

instance DefaultFromField T.SqlInt4 Int    where defaultFromField = fromPGSFromField
instance DefaultFromField T.SqlText String where defaultFromField = fromPGSFromField
```

**Nullability lands in the Haskell type.** The `Default` instance for a nullable field decodes to a
`Maybe`, using postgresql-simple's `optionalField` ([`src/Opaleye/Internal/RunQuery.hs`][runquery]):

```haskell
-- src/Opaleye/Internal/RunQuery.hs
instance DefaultFromField a b =>
         D.Default FromFields (FieldNullable a) (Maybe b) where
  def = fromFieldsNullable defaultFromField
```

So a `FieldNullable SqlText` column materialises as `Maybe String` — the tutorial's rule is _"nullable
fields … are converted to `Maybe` when executed"_ ([`Doc/Tutorial/TutorialBasic.lhs`][tutbasic]),
the [nullability-in-the-type-system][typemap] property this survey tracks.

Row **hydration** is positional and profunctor-composed: tuples via `pN`/`(***!)`, records via the
TH-derived adaptor, `newtype`s via their derived instance. A `Select (Widget (Field SqlText) …)`
decodes to `[Widget String …]` with no hand-written decoder. The whole family — `ToFields`,
`FromFields`, `TableFields`, `Unpackspec` (rename fields), `Binaryspec` (union two queries),
`Valuesspec` (`VALUES` literals) — is the _same_ `ProductProfunctor` shape, which is the design's
signature and, equally, its learning cost.

---

## Effect model, transactions & error handling

This is the dimension where Opaleye sits furthest from the libraries this survey weights most. **A
`Select` is a pure value, but running it is eager, blocking `IO`.** There is no effect-value type
(`ConnectionIO`, `ZIO`, `Effect`), no async `Future`/`Task`, and no error type parameter. Every runner
bottoms out in postgresql-simple `IO` — `runSelect` returns `IO [haskells]` (above); manipulations
return `IO haskells` ([`src/Opaleye/Manipulation.hs`][manipulation]):

```haskell
-- src/Opaleye/Manipulation.hs
runInsert :: PGS.Connection -> Insert haskells -> IO haskells
runUpdate :: PGS.Connection -> Update haskells -> IO haskells
runDelete :: PGS.Connection -> Delete haskells -> IO haskells
```

Inserts, updates, and deletes are described as record values (`Insert{..}`, `Update{..}`, `Delete{..}`)
carrying a `Returning` — `rCount` for a row count or `rReturning` for a projection of the affected rows
(SQL `RETURNING`) — and an `OnConflict` (only `doNothing` is supported) ([`src/Opaleye/Manipulation.hs`][manipulation]):

```haskell
-- Doc/Tutorial/TutorialManipulation.lhs
insertReturning :: Insert [Int]
insertReturning = Insert
  { iTable      = myTable
  , iRows       = [(Nothing, 4, 5, sqlString "Bye")]
  , iReturning  = rReturning (\(id_, _, _, _) -> id_)
  , iOnConflict = Nothing
  }
```

Manipulation is also deliberately limited to constant values ([`src/Opaleye/Manipulation.hs`][manipulation]):
_"Opaleye currently only supports INSERT or UPDATE with constant values, not the result of
SELECTs."_

**There is no transaction abstraction in Opaleye.** A grep of the source turns up no `BEGIN`,
`COMMIT`, `ROLLBACK`, `SAVEPOINT`, or `withTransaction` — transactions, savepoints, and isolation
levels are entirely postgresql-simple's responsibility (its `withTransaction`/`withSavepoint`,
web-attested; postgresql-simple is not in the pinned tree). You wrap a block of Opaleye `IO` actions
in postgresql-simple's transaction combinator yourself. So unlike `Slick`'s `.transactionally`
or `doobie`'s `ConnectionIO` transaction, nesting/savepoint/isolation semantics are not something
Opaleye models at all — it is one layer too low.

**Errors are exceptions in `IO`, not a typed channel.** Opaleye has no error-type parameter anywhere;
a database or decoding failure surfaces as a postgresql-simple exception (`SqlError`, `ResultError`)
thrown in `IO`, handled with ordinary `IO` exception handling. This is the sharp contrast with the
[typed-error][effects] effect mappers (`doobie`/`skunk` keep errors in the effect's error type;
`Effect TS` models an 11-reason `SqlError` union) and even with `Slick`'s
`asTry`/`cleanUp` combinators. Opaleye's counter-claim is that it moves an entire _class_ of errors
(column existence, type mismatches) from runtime to _compile time_ — _"if your code compiles then the
generated SQL query will not fail at runtime"_ ([`README.md`][readme]) — so the surviving exception
surface is narrower than a raw-string library's. But what remains is still exceptions, not values.

---

## Ecosystem & maturity

Opaleye is a mature, long-lived library under the permissive **BSD-3-Clause** licence, © 2014–2018
Purely Agile Limited and 2019–2026 Tom Ellis ([`LICENSE`][license], [`opaleye.cabal`][cabal]). Its
lineage is explicit: much of the implementation is _"based on ideas and code from the HaskellDB
project by Daan Leijen"_ and others, and the project was _"founded by Tom Ellis, inspired by
theoretical work on databases by David Spivak"_ ([`README.md`][readme]). Governance is unusually
centralised — _"The only person authorised to merge to `master` or upload this package to Hackage is
Tom Ellis"_ — mitigated by a written backup-maintainer succession policy (Oliver Charles → Shane
O'Brien → Ellie Hermaszewska). Commercial support is offered by Purely Agile.

It targets **PostgreSQL** and depends on `postgresql-simple`, `product-profunctors`, and `profunctors`
([`opaleye.cabal`][cabal]); a minimal `opaleye-sqlite` companion package lives in-repo. It is tested
across a wide GHC range (8.8 through 9.12). The pinned checkout is `0.10.8.0`, part of a stable,
slow-moving `0.10` line whose changelog reaches back to `0.3` ([`CHANGELOG.md`][changelog]); the first
release dates to ≈2014–2015 (web/soft).

The most consequential dependent is **`Rel8`** — a higher-level Haskell query library built directly on
Opaleye's internals; the `QueryArr` module carries explicit _"This is used by Rel8"_ seams
([`src/Opaleye/Internal/QueryArr.hs`][queryarr]). Opaleye thus also functions as a substrate other
libraries build on, not only an end-user API.

---

## Strengths

- **Compile-time-sound SQL.** The type of a `Select` records every field's SQL type; a mistyped
  comparison or a missing column is a compile error. The stated goal is that _"if your code compiles
  then the generated SQL query will not fail at runtime"_ ([`README.md`][readme]).
- **Fine-grained composability.** A query is a first-class arrow (`SelectArr a b`); sub-queries and
  even bare restrictions are named, reused, and combined in arrow- or `do`-notation — the same query
  factors many ways and generates identical SQL.
- **Type-safe aggregation.** Aggregators are profunctors composed to match the row shape; the count
  aggregator turns a `Field String` into a `Field SqlInt8` _in the type_, closing the hole where most
  typed SQL DSLs leak ([`Doc/Tutorial/TutorialBasic.lhs`][tutbasic]).
- **Nullability in the type system.** `FieldNullable a` decodes to `Maybe b`; `NULL` handling is a
  type distinction, not a convention.
- **Injection-safe by construction.** No string-building API exists; user values become escaped SQL
  literals and statements carry no interpolation. The only "unsafe" surface is type coercions, not
  text splicing.
- **Inspectable output.** `showSql` renders a `Select` to SQL without a database, and the tutorial
  shows the generated SQL is close to hand-written.
- **One uniform mechanism.** Schema mapping, encoding, decoding, joins, and unions are all the same
  `ProductProfunctor`/`Default` pattern — learn it once, apply it everywhere.

## Weaknesses

- **`Default`/`ProductProfunctor` type errors.** The convenience that hides the plumbing produces
  notoriously opaque errors when an instance can't be resolved; the docs repeatedly advise adding type
  signatures (`runSelect` _"means that the compiler will have trouble inferring types … strongly
  recommended that you provide full type signatures"_, [`src/Opaleye/RunSelect.hs`][runselect]).
- **Blocking `IO` only.** No effect value, no async, no typed error channel — Opaleye is a rung below
  the effect-system mappers (`doobie`, `skunk`, `Effect TS`) this survey centres on.
- **No transaction/pool/resource story of its own.** Connection lifetime, pooling, and transactions
  are all delegated to postgresql-simple and the caller; a leaked connection is not Opaleye's concern.
- **No migrations, DDL, or codegen.** Strictly database-first: you hand-write `Table` descriptions to
  match a schema you evolve elsewhere.
- **PostgreSQL-only.** The AST and printer target Postgres; the `opaleye-sqlite` companion is minimal.
- **Manipulation is constant-values-only.** INSERT/UPDATE cannot take the result of a `SELECT`
  ([`src/Opaleye/Manipulation.hs`][manipulation]).
- **Template Haskell for records.** Ergonomic record queries lean on a TH adaptor splice
  (`makeAdaptorAndInstanceInferrable`), though explicit `pN`/`Default` dictionaries are always available.

## Key design decisions and trade-offs

| Decision                                                          | Rationale                                                                                           | Trade-off                                                                                                 |
| ----------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| Query = `SelectArr a b` **arrow** (a `Category`/`Arrow`/`Monad`)  | First-class, composable query values; arrow _and_ `do`-notation; sub-queries reusable at fine grain | Arrow/profunctor vocabulary to learn; the composition machinery is heavy for simple queries               |
| `Field_ (n :: Nullability) sqlType` phantom-typed expressions     | Column references and SQL types checked at compile time; nullability tracked; `newtype` safety      | Rich type-level constraints; errors can be cryptic when a `Default` instance is missing                   |
| `Default` + `ProductProfunctor` as the one universal mechanism    | Schema map, encode, decode, join, union all derive automatically; minimal boilerplate               | A whole tutorial to explain it; opaque inference failures; type signatures required "everywhere in sight" |
| Injection safety via **non-interpolation + escaped literals**     | No string API to inject into; values render as inert escaped SQL literals                           | Relies on correct escaping, not protocol channel separation; statements carry no bind params (`$n`)       |
| Execution = **blocking `IO`** on a postgresql-simple `Connection` | Small, focused query layer; reuses a battle-tested driver                                           | No effect value / async / typed errors; a rung below the survey's effect-system mappers                   |
| **No** transaction / pool / resource abstraction                  | Stay minimal; let postgresql-simple and the caller own connection lifetime                          | Transactions, savepoints, isolation, pooling, leak-safety are all the user's problem                      |
| **Database-first**, no migrations / DDL / codegen                 | Do one thing (query an existing schema); keep the surface small                                     | Hand-written `Table` descriptions can drift from the live schema; no schema-evolution tooling             |
| PostgreSQL-only AST + printer                                     | A tight, well-optimized target; readable Postgres SQL                                               | Not portable across dialects (contrast Slick's multi-dialect compiler)                                    |
| Errors as **exceptions in `IO`**                                  | Simple; interops with postgresql-simple's exception model                                           | No enumerated/typed error set; type-safety narrows _which_ errors remain but does not make them values    |

---

## Sources

- [tomjaguarpaw/haskell-opaleye — GitHub repository][repo] · [Hackage haddocks][hackage] · in-repo [`Doc/Tutorial/`][docdir]
- [`README.md` — positioning, typesafe/composable pitch, HaskellDB lineage, maintainer policy][readme]
- [`opaleye.cabal` — synopsis, BSD3 licence, dependencies, GHC range, version][cabal] · [`CHANGELOG.md`][changelog] · [`LICENSE`][license]
- [`Doc/Design/DESIGN.md` — problems with SQL; `Select`/`Field` as the core types][design]
- [`Doc/Tutorial/TutorialBasic.lhs` — tables, restriction, joins, nullability, aggregation, newtypes, running][tutbasic]
- [`Doc/Tutorial/TutorialManipulation.lhs` — INSERT/UPDATE/DELETE records, `RETURNING`, `toFields`][tutmanip]
- [`Doc/Tutorial/DefaultExplanation.lhs` — the `Default`/`ProductProfunctor` machinery, `FromFields`][defaultexpl]
- [`src/Opaleye/Select.hs`][select] · [`src/Opaleye/Internal/QueryArr.hs` — `SelectArr`, arrow instances][queryarr]
- [`src/Opaleye/Operators.hs` — `restrict`/`where_`, `.==` and the typed operators][operators] · [`src/Opaleye/Internal/Column.hs` — `Field_`, `binOp`][column]
- [`src/Opaleye/Table.hs`][table] · [`src/Opaleye/Internal/Table.hs` — `TableFields`, write/view split][inttable]
- [`src/Opaleye/ToFields.hs`][tofields] · [`src/Opaleye/Internal/Constant.hs` — `ToFields`][constant] · [`src/Opaleye/SqlTypes.hs` — SQL types + value constructors][sqltypes]
- [`src/Opaleye/RunSelect.hs`][runselect] · [`src/Opaleye/Internal/RunQuery.hs` — `FromFields`, `DefaultFromField`][runquery] · [`src/Opaleye/Manipulation.hs`][manipulation]
- [`src/Opaleye/Sql.hs` — `showSql`][sql] · [`src/Opaleye/Internal/PrimQuery.hs` — the relational-algebra AST][primquery] · [`src/Opaleye/Internal/HaskellDB/Sql/Default.hs` — literal escaping][sqldefault]
- [`postgresql-simple`][pgsimple] · [`product-profunctors`][productprof] — the driver and profunctor machinery Opaleye builds on
- Concepts: [abstraction ladder][ladder] · [query construction models][qmodels] · [statements & injection][injection] · [type mapping & decoding][typemap] · [schema, migrations & codegen][schemamig] · [effects, transactions & errors][effects] · [connections & pools][pools]

<!-- References -->

[repo]: https://github.com/tomjaguarpaw/haskell-opaleye
[hackage]: https://hackage.haskell.org/package/opaleye
[docdir]: https://github.com/tomjaguarpaw/haskell-opaleye/tree/eaf094271c29ca562cc2605c84e50f10b0e3845e/Doc/Tutorial
[readme]: https://github.com/tomjaguarpaw/haskell-opaleye/blob/eaf094271c29ca562cc2605c84e50f10b0e3845e/README.md
[cabal]: https://github.com/tomjaguarpaw/haskell-opaleye/blob/eaf094271c29ca562cc2605c84e50f10b0e3845e/opaleye.cabal
[changelog]: https://github.com/tomjaguarpaw/haskell-opaleye/blob/eaf094271c29ca562cc2605c84e50f10b0e3845e/CHANGELOG.md
[license]: https://github.com/tomjaguarpaw/haskell-opaleye/blob/eaf094271c29ca562cc2605c84e50f10b0e3845e/LICENSE
[design]: https://github.com/tomjaguarpaw/haskell-opaleye/blob/eaf094271c29ca562cc2605c84e50f10b0e3845e/Doc/Design/DESIGN.md
[tutbasic]: https://github.com/tomjaguarpaw/haskell-opaleye/blob/eaf094271c29ca562cc2605c84e50f10b0e3845e/Doc/Tutorial/TutorialBasic.lhs
[tutmanip]: https://github.com/tomjaguarpaw/haskell-opaleye/blob/eaf094271c29ca562cc2605c84e50f10b0e3845e/Doc/Tutorial/TutorialManipulation.lhs
[defaultexpl]: https://github.com/tomjaguarpaw/haskell-opaleye/blob/eaf094271c29ca562cc2605c84e50f10b0e3845e/Doc/Tutorial/DefaultExplanation.lhs
[select]: https://github.com/tomjaguarpaw/haskell-opaleye/blob/eaf094271c29ca562cc2605c84e50f10b0e3845e/src/Opaleye/Select.hs
[queryarr]: https://github.com/tomjaguarpaw/haskell-opaleye/blob/eaf094271c29ca562cc2605c84e50f10b0e3845e/src/Opaleye/Internal/QueryArr.hs
[operators]: https://github.com/tomjaguarpaw/haskell-opaleye/blob/eaf094271c29ca562cc2605c84e50f10b0e3845e/src/Opaleye/Operators.hs
[column]: https://github.com/tomjaguarpaw/haskell-opaleye/blob/eaf094271c29ca562cc2605c84e50f10b0e3845e/src/Opaleye/Internal/Column.hs
[table]: https://github.com/tomjaguarpaw/haskell-opaleye/blob/eaf094271c29ca562cc2605c84e50f10b0e3845e/src/Opaleye/Table.hs
[inttable]: https://github.com/tomjaguarpaw/haskell-opaleye/blob/eaf094271c29ca562cc2605c84e50f10b0e3845e/src/Opaleye/Internal/Table.hs
[tofields]: https://github.com/tomjaguarpaw/haskell-opaleye/blob/eaf094271c29ca562cc2605c84e50f10b0e3845e/src/Opaleye/ToFields.hs
[constant]: https://github.com/tomjaguarpaw/haskell-opaleye/blob/eaf094271c29ca562cc2605c84e50f10b0e3845e/src/Opaleye/Internal/Constant.hs
[sqltypes]: https://github.com/tomjaguarpaw/haskell-opaleye/blob/eaf094271c29ca562cc2605c84e50f10b0e3845e/src/Opaleye/SqlTypes.hs
[runselect]: https://github.com/tomjaguarpaw/haskell-opaleye/blob/eaf094271c29ca562cc2605c84e50f10b0e3845e/src/Opaleye/RunSelect.hs
[runquery]: https://github.com/tomjaguarpaw/haskell-opaleye/blob/eaf094271c29ca562cc2605c84e50f10b0e3845e/src/Opaleye/Internal/RunQuery.hs
[runqueryext]: https://github.com/tomjaguarpaw/haskell-opaleye/blob/eaf094271c29ca562cc2605c84e50f10b0e3845e/src/Opaleye/Internal/RunQueryExternal.hs
[manipulation]: https://github.com/tomjaguarpaw/haskell-opaleye/blob/eaf094271c29ca562cc2605c84e50f10b0e3845e/src/Opaleye/Manipulation.hs
[sql]: https://github.com/tomjaguarpaw/haskell-opaleye/blob/eaf094271c29ca562cc2605c84e50f10b0e3845e/src/Opaleye/Sql.hs
[primquery]: https://github.com/tomjaguarpaw/haskell-opaleye/blob/eaf094271c29ca562cc2605c84e50f10b0e3845e/src/Opaleye/Internal/PrimQuery.hs
[sqldefault]: https://github.com/tomjaguarpaw/haskell-opaleye/blob/eaf094271c29ca562cc2605c84e50f10b0e3845e/src/Opaleye/Internal/HaskellDB/Sql/Default.hs
[pgsimple]: https://hackage.haskell.org/package/postgresql-simple
[productprof]: https://hackage.haskell.org/package/product-profunctors
[concepts]: ./concepts.md
[ladder]: ./concepts.md#the-abstraction-ladder
[qmodels]: ./concepts.md#query-construction-models
[injection]: ./concepts.md#statements-parameters-and-sql-injection
[typemap]: ./concepts.md#type-mapping-and-result-decoding
[schemamig]: ./concepts.md#schema-migrations-code-generation
[effects]: ./concepts.md#effects-transactions-and-error-handling
[pools]: ./concepts.md#connections-pools-and-sessions
[index]: ./index.md
