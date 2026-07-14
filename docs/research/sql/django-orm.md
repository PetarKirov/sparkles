# Django ORM (Python)

A batteries-included, [active-record-flavored][ladder] ORM built into the Django web framework: a `Model` subclass maps 1:1 to a table and carries its own persistence methods (`instance.save()` / `instance.delete()`), while a lazy, chainable `QuerySet` on the `objects` manager builds SQL without a session, identity map, or unit of work.

| Field              | Value                                                                                                                                                                      |
| ------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language           | Python (`requires-python >= 3.12`, `pyproject.toml`)                                                                                                                       |
| License            | BSD-3-Clause (`LICENSE`: "Redistribution and use in source and binary forms … 3. Neither the name of Django …")                                                            |
| Repository         | [django/django][repo]                                                                                                                                                      |
| Documentation      | [docs.djangoproject.com][docs] · in-tree `docs/topics/db/` + `docs/ref/models/`                                                                                            |
| Category           | [Full ORM, active-record-flavored][ladder] (model = table + persistence methods; but a data-mapper-ish `Manager`/`QuerySet` split, and **no** identity map / unit of work) |
| Abstraction level  | [Full ORM][ladder] — the top rung of the abstraction ladder                                                                                                                |
| Query model        | [`QuerySet` method chains][models] (`.filter()`/`.exclude()`/`.annotate()`), **lazy**, reified to a `sql.Query` AST → SQL                                                  |
| Effect/async model | Blocking / synchronous, with a **growing async mirror** (`aget`/`acreate`/`adelete`, `async for`) delegating via `sync_to_async`                                           |
| Backends           | PostgreSQL, MySQL/MariaDB, SQLite, Oracle (`django/db/backends/{postgresql,mysql,sqlite3,oracle}`)                                                                         |
| First release      | 2005 (web-attested; open-sourced by the Lawrence Journal-World)                                                                                                            |
| Latest version     | `6.2` in the pinned tree (`django/__init__.py`: `VERSION = (6, 2, 0, "alpha", 0)`); latest stable web-attested                                                             |

> [!NOTE]
> Django ORM is this survey's data point for the **active-record-flavored, framework-integrated full ORM** — the top of the [abstraction ladder][ladder], and the opposite pole from the effect-system libraries the survey is built to inform. Its object model is active-record (persistence lives on the instance: `user.save()`), but it separates querying into a `Manager`/`QuerySet` layer and — unlike `SQLAlchemy`, `EF Core`, or `Hibernate` — carries **no [unit of work][orm], no [identity map][orm], no implicit flush**: every `save()` is its own statement. Its `QuerySet` is famously [**lazy**][models] and chainable, and related-object access is [lazy by default → N+1][nplusone], mitigated with `select_related`/`prefetch_related`. Terms below link to [concepts][concepts].

---

## Overview

### What it solves

Django ORM removes hand-written SQL and connection plumbing from a Django application: you declare Python classes, and Django gives you _"an automatically-generated database-access API"_ plus the DDL to create the tables. The framework's own `docs/topics/db/models.txt` opens with the thesis ([`docs/topics/db/models.txt`][modelsdoc]):

> _"A model is the single, definitive source of information about your data. It contains the essential fields and behaviors of the data you're storing. Generally, each model maps to a single database table."_

That one-model-one-table mapping is the [active-record][orm] premise, and the whole ORM hangs off it: each attribute is a column, the class metaclass (`ModelBase`) synthesizes an `_meta` (`Options`) descriptor and an `objects` [`Manager`][managersdoc], and the instance grows `save()`/`delete()` persistence methods. A model definition is minimal ([`docs/topics/db/models.txt`][modelsdoc]):

```python
from django.db import models


class Person(models.Model):
    first_name = models.CharField(max_length=30)
    last_name = models.CharField(max_length=30)
```

which Django maps to `CREATE TABLE myapp_person (…)` with an auto-added `id` primary key and a table name _"automatically derived from some model metadata"_ ([`docs/topics/db/models.txt`][modelsdoc]).

### Design philosophy

Django's guiding principle is **DRY** — the models _are_ the schema, and everything else (queries, admin, forms, migrations) is derived from them. The design-philosophies document states it directly ([`docs/misc/design-philosophies.txt`][philosophy]):

> _"Every distinct concept and/or piece of data should live in one, and only one, place. Redundancy is bad. Normalization is good. … The framework, within reason, should deduce as much as possible from as little as possible."_

The second half is the ORM's engine: from one model class Django _deduces_ the table DDL, the query API, the migration operations, and the admin UI. That is why Django is **code-first** — the schema is a projection of the model, not the other way around (contrast the schema-first `Prisma` or the db-first `jOOQ`).

The consequential design choice — and the one that most distinguishes Django from the other full ORMs in this survey — is what Django **does not** do. There is no session object that snapshots loaded rows and computes a minimal diff on commit. `Manager`/`QuerySet` gives Django a data-mapper-ish separation between "the objects" and "how you query them," but persistence itself is active-record: you mutate an instance's attributes and call `instance.save()`, which emits one `UPDATE` (or `INSERT`) then and there. There is no [unit of work][orm], no [identity map][orm], and no change tracking — the machinery that `Hibernate`'s `Session`, `EF Core`'s `SaveChanges`, and `SQLAlchemy`'s `Session` provide, and that Django deliberately omits. This puts Django closer to Ruby's `ActiveRecord` (its active-record sibling) and to `Ecto` (which likewise rejects lazy loading and implicit flush) than to the data-mapper ORMs.

---

## Connection, pooling & resource lifetime

Django's connection object is **thread-local** and accessed through the `connections` handler by database alias (`"default"`, …); there is no user-visible acquire/release. Historically Django opened a fresh connection per HTTP request; **persistent connections** are the built-in pooling story ([`docs/ref/databases.txt`][databasesdoc]):

> _"Persistent connections avoid the overhead of reestablishing a connection to the database in each HTTP request. They're controlled by the `CONN_MAX_AGE` parameter which defines the maximum lifetime of a connection."_

`CONN_MAX_AGE` defaults to `0` — _"preserving the historical behavior of closing the database connection at the end of each request"_ ([`docs/ref/databases.txt`][databasesdoc]) — so Django reuses one long-lived connection per worker thread rather than leasing from a [pool][pool]. A true pool is delegated to the driver: since the psycopg3 era the PostgreSQL backend accepts `OPTIONS={"pool": True}` to use _"a connection pool with psycopg"_ ([`docs/ref/databases.txt`][databasesdoc]), and under ASGI the docs advise disabling persistent connections and using _"your database backend's built-in connection pooling if available."_ Resource lifetime is thus request-scoped and framework-managed, not a [scoped][pool] `acquire`/`release` combinator as in the effect systems — a leaked connection is a config/deployment concern, not a type error.

## Query construction & injection safety

The `QuerySet` is the heart of the ORM, and the source of both its ergonomics and its foot-guns. `django/db/models/query.py`'s module docstring calls it _"The main QuerySet implementation. This provides the public API for the ORM."_ ([`django/db/models/query.py`][querypy]).

**`QuerySet` is lazy.** Building a query touches nothing; only _evaluation_ runs SQL. The topic guide is emphatic ([`docs/topics/db/queries.txt`][queriesdoc]):

> _"`QuerySet` objects are lazy -- the act of creating a `QuerySet` doesn't involve any database activity. You can stack filters together all day long, and Django won't actually run the query until the `QuerySet` is *evaluated*."_

The reference guide enumerates the evaluation triggers ([`docs/ref/models/querysets.txt`][querysetsdoc]): _"Internally, a `QuerySet` can be constructed, filtered, sliced, and generally passed around without actually hitting the database. No database activity actually occurs until you do something to evaluate the queryset."_ — namely **iteration**, **`async for`**, **slicing with a step**, **`repr()`**, **`len()`**, **`list()`**, and **pickling**. Internally, `__len__` calls `_fetch_all`, which populates a per-`QuerySet` `_result_cache` exactly once ([`django/db/models/query.py`][querypy]):

```python
def _fetch_all(self):
    if self._result_cache is None:
        self._result_cache = list(self._iterable_class(self))
    if self._prefetch_related_lookups and not self._prefetch_done:
        self._prefetch_related_objects()
```

Note that `_result_cache` is a **query-local** cache, not a cross-query [identity map][orm]: two separate `QuerySet`s that load the same row return two distinct Python objects.

**Chaining returns fresh, immutable-ish clones.** `filter`/`exclude`/`annotate` each `_chain()` a clone and mutate the clone, so the original `QuerySet` is untouched ([`django/db/models/query.py`][querypy]):

```python
def filter(self, *args, **kwargs):
    """
    Return a new QuerySet instance with the args ANDed to the existing
    set.
    """
    self._not_support_combined_queries("filter")
    return self._filter_or_exclude(False, args, kwargs)
```

Each clause folds into the query's `where` tree as a `Q` node (`self._query.add_q(Q(*args, **kwargs))`), and `exclude` wraps it in `~Q(...)`. A chain composes freely:

```python
>>> q = Entry.objects.filter(headline__startswith="What")
>>> q = q.filter(pub_date__lte=datetime.date.today())
>>> q = q.exclude(body_text__icontains="food")
>>> print(q)
```

which _"looks like three database hits, in fact it hits the database only once, at the last line (`print(q)`)"_ ([`docs/topics/db/queries.txt`][queriesdoc]). `filter` always returns a `QuerySet`; `get()` runs the query immediately and returns one object, raising `DoesNotExist` on zero rows or `MultipleObjectsReturned` on more than one ([`django/db/models/query.py`][querypy]).

**Injection safety comes from parameterization, not escaping.** Field-lookup values are never spliced into SQL text; they become bound parameters carried alongside the compiled query and handed to the driver's `cursor.execute(sql, params)` ([`django/db/models/sql/compiler.py`][compiler]). The security guide states the guarantee ([`docs/topics/security.txt`][security]):

> _"Django's querysets are protected from SQL injection since their queries are constructed using query parameterization. A query's SQL code is defined separately from the query's parameters. Since parameters may be user-provided and therefore unsafe, they are escaped by the underlying database driver."_

The query compiler builds `(sql, params)` pairs at every level and executes them out-of-band ([`django/db/models/sql/compiler.py`][compiler]):

```python
sql, params = self.as_sql()
...
cursor.execute(sql, params)
```

so a hostile `name__startswith` value can only ever be _data_, never query structure — the [bind-parameter][inject] safety mechanism, applied by default across the entire `QuerySet` surface.

**`F()` and `Q()`: DB-side expressions and boolean algebra.** Two expression objects let you push logic into SQL. An `F()` references a column so an operation runs _"at the database level"_ without a round-trip ([`docs/ref/models/expressions.txt`][expressionsdoc]):

> _"An `F()` object represents the value of a model field … It makes it possible to refer to model field values and perform database operations using them without actually having to pull them out of the database into Python memory."_

```python
from django.db.models import F

reporter.stories_filed = F("stories_filed") + 1
reporter.save()  # emits: UPDATE ... SET stories_filed = stories_filed + 1
```

This _"looks like a normal Python assignment … in fact it's an SQL construct describing an operation on the database"_ ([`docs/ref/models/expressions.txt`][expressionsdoc]) — and, because the increment happens in the database, it sidesteps the read-modify-write race. `F`'s own docstring is terse: _"An object capable of resolving references to existing query objects."_ ([`django/db/models/expressions.py`][expressions]). A `Q` object encapsulates a filter predicate so complex boolean logic (`OR`, `XOR`, negation) is expressible ([`django/db/models/query_utils.py`][queryutils]):

> _"Encapsulate filters as objects that can then be combined logically (using `&` and `|`)."_

```python
from django.db.models import Q

Entry.objects.filter(Q(headline__startswith="Who") | Q(headline__startswith="What"))
```

`Q` overloads `__and__`/`__or__`/`__xor__`/`__invert__` over a tree node ([`django/db/models/query_utils.py`][queryutils]); the values inside a `Q` are parameterized exactly like keyword-`filter` values.

**Beyond filtering: the query is reified as an AST.** A `QuerySet` wraps a mutable `sql.Query` object (imported as `sql` in `query.py`); every clause method mutates it, and the `sql.compiler` renders it to the backend's dialect at evaluation. On top of `filter`/`exclude`, `annotate(*args, **kwargs)` attaches DB-side expressions/aggregations to each returned object, `aggregate(*args, **kwargs)` collapses the set into a _"dictionary containing the calculations (aggregation) over the current queryset"_ ([`django/db/models/query.py`][querypy]), and `values()`/`values_list()` swap object hydration for dict/tuple rows. All of them thread the same parameterization, so the injection guarantee is uniform across the entire builder surface — the reified-AST property that lets one query target four SQL dialects.

**Escape hatches: `raw()` and `extra()`.** When the DSL is insufficient, `QuerySet.raw(raw_query, params=())` runs a raw `SELECT` and maps rows back to model instances, and `extra()` splices raw SQL fragments ([`django/db/models/query.py`][querypy]). Both are explicitly flagged in the security guide as the point where safety becomes the developer's responsibility ([`docs/topics/security.txt`][security]): _"These capabilities should be used sparingly and you should always be careful to properly escape any parameters that the user can control. In addition, you should exercise caution when using `extra()` and `RawSQL`."_ `raw()` still accepts a `params` argument for safe binding; the danger is string-building the `raw_query` yourself. `extra()` is additionally soft-deprecated in the docs in favor of expression APIs.

## Schema, migrations & code generation

Migrations are a **built-in, code-first** strength — a headline feature no other Python ORM shipped as standard when Django introduced them (Django 1.7, web-attested). The models are the source of truth; `makemigrations` diffs model state and emits migration files. The topic guide frames it as version control ([`docs/topics/migrations.txt`][migrationsdoc]):

> _"You should think of migrations as a version control system for your database schema. `makemigrations` is responsible for packaging up your model changes into individual migration files - analogous to commits - and `migrate` is responsible for applying those to your database."_

The autodetector is a literal state diff ([`django/db/migrations/autodetector.py`][autodetector]):

> _"Take a pair of ProjectStates and compare them to see what the first would need doing to make it match the second (the second usually being the project's current state)."_

Each migration is a `Migration` subclass carrying an ordered `operations` list plus `dependencies`, `run_before`, and `replaces` attributes ([`django/db/migrations/migration.py`][migration]). Those dependencies form a directed graph the executor walks ([`django/db/migrations/graph.py`][graph]):

> _"Represent the digraph of all migrations in a project. Each migration is a node, and each dependency is an edge. There are no implicit dependencies between numbered migrations - the numbering is merely a convention to aid file listing. Every new numbered migration has a declared dependency to the previous number, meaning that VCS branch merges can be detected and resolved."_

The graph node is a `(app_label, migration_name)` tuple; a `recorder` bookkeeping table records which migrations are applied; a `RunPython` operation carries data migrations. Migrations are _"supported on all backends that Django ships with"_ ([`docs/topics/migrations.txt`][migrationsdoc]) and are meant to be committed to VCS and replayed across environments. Django does **not** do db-first codegen: the model is authoritative, and `inspectdb` (introspecting an existing DB into models) is a one-shot scaffold, not a maintained sync.

## Type mapping & result decoding

**Field → column mapping.** Each `Field` subclass (`django/db/models/fields/`: `CharField`, `IntegerField`, `DateTimeField`, `BooleanField`, `DecimalField`, `UUIDField`, `JSONField`, `BinaryField`, `ForeignKey`, `ManyToManyField`, …) knows its DDL type through `db_type(connection)`, which resolves via `get_internal_type()` against a backend's `data_types` dictionary ([`django/db/models/fields/__init__.py`][fields]):

> _"Return the database column data type for this field, for the provided connection. … The default implementation of this method looks at the backend-specific `data_types` dictionary, looking up the field by its 'internal type'."_

The same backend-parameterized approach is why one `CharField(max_length=30)` becomes `varchar(30)` on PostgreSQL but a different spelling on Oracle. Value round-tripping goes through `get_prep_value`/`to_python`/`from_db_value` on the field (the seam a custom field overrides); row **hydration** builds a `Model` instance positionally from `_meta.concrete_fields` in `Model.__init__` (an iteration-optimized fast path skips `kwargs`). **Nullability** is Python `None` mapping to SQL `NULL`, controlled by the field's `null=` flag — there is no `Option`/`Maybe` wrapper, so a nullable FK reads back as either an instance or `None`.

**Relations are fields too.** A `ForeignKey` stores a scalar column: `ForeignKey.get_attname` returns `"%s_id" % self.name` ([`django/db/models/fields/related.py`][relatedfk]), so a `blog = ForeignKey(Blog, …)` field materializes a `blog_id` column and a `blog` descriptor. A `ManyToManyField` has no column at all — Django synthesizes an intermediary join table via `create_many_to_many_intermediary_model` ([`django/db/models/fields/related.py`][relatedfk]) (or uses a user-supplied `through=` model). Relation traversal in lookups uses the `__` separator (`Entry.objects.filter(blog__name="…")`), which the compiler turns into SQL joins.

**Active-record persistence, no unit of work.** The instance carries its own writes. `Model.save()` is documented minimally ([`django/db/models/base.py`][basepy]):

> _"Save the current instance. Override this in a subclass if you want to control the saving process. … The 'force_insert' and 'force_update' parameters can be used to insist that the 'save' must be an SQL insert or update … Normally, they should not be set."_

`save()` decides `INSERT` vs `UPDATE` (by primary-key presence and `update_fields`), then `save_base` emits exactly one statement; `Model.delete()` collects dependents and issues the `DELETE` immediately; `Manager.create(**kwargs)` is sugar for `model(**kwargs)` + `obj.save(force_insert=True)` ([`django/db/models/query.py`][querypy]). Each call is its own round-trip — there is no pending-changes buffer that a later `flush()`/`commit()` reconciles. `objects` is the auto-added `Manager` (_"the interface through which database query operations are provided to Django models,"_ [`docs/topics/db/managers.txt`][managersdoc]), synthesized by the metaclass unless the model defines its own ([`django/db/models/base.py`][basepy]).

**Lazy related-object loading is the N+1 default.** Accessing a foreign-key attribute fires a query on demand. The descriptor `ForwardManyToOneDescriptor.__get__` loads the related instance from the database and caches it on the instance's `_state` ([`django/db/models/fields/related_descriptors.py`][related]); the docs make the round-trip visible ([`docs/ref/models/querysets.txt`][querysetsdoc]):

```python
# Hits the database.
e = Entry.objects.get(id=5)

# Hits the database again to get the related Blog object.
b = e.blog
```

Loop over N `Entry` rows touching `e.blog` each time and you get [N+1][nplusone] queries. Django's two mitigations map to the two [loading strategies][nplusone]:

- **`select_related(*fields)`** — a **join**. It _"works by creating an SQL join and including the fields of the related object in the `SELECT` statement … `select_related` gets the related objects in the same database query"_ ([`docs/ref/models/querysets.txt`][querysetsdoc]), so `Entry.objects.select_related("blog").get(id=5)` then reads `e.blog` with no further hit. Limited to single-valued (FK / one-to-one) relations to avoid a row explosion.
- **`prefetch_related(*lookups)`** — a **separate query joined in Python**. It _"does a separate lookup for each relationship, and does the 'joining' in Python,"_ so it handles many-to-many and reverse many-to-one ([`docs/ref/models/querysets.txt`][querysetsdoc]). The additional queries run _"after the `QuerySet` has begun to be evaluated and the primary query has been executed."_

This is the classic ORM tension: lazy loading is convenient but silently multiplies round-trips — the exact foot-gun `Ecto` avoids by refusing lazy loading outright, and that the functional data mappers avoid by making the join explicit. Django keeps lazy loading and asks you to opt into `select_related`/`prefetch_related`.

## Effect model, transactions & error handling

**Primarily blocking, with a growing async mirror.** A `QuerySet` evaluation blocks the calling thread until rows arrive; there is no `IO`/`ZIO`/`Effect`/`ConnectionIO` [effect value][effects]. Django has grown an **async query API** that mirrors the blocking one: every blocking method has an `a`-prefixed variant, and iteration has `async for` ([`docs/topics/db/queries.txt`][queriesdoc]):

> _"Every method that might block - such as `get()` or `delete()` - has an asynchronous variant (`aget()` or `adelete()`), and when you iterate over results, you can use asynchronous iteration (`async for`) instead."_

The async variants are thin wrappers — `aget`, `acreate`, `asave`, `adelete` delegate to their sync bodies through `asgiref`'s `sync_to_async` ([`django/db/models/query.py`][querypy], [`django/db/models/base.py`][basepy]):

```python
async def aget(self, *args, **kwargs):
    return await sync_to_async(self.get)(*args, **kwargs)
```

so the query still runs on a thread; the async surface is about not blocking the event loop from an async view, not a native async driver protocol. Calling a blocking ORM method from async code raises `SynchronousOnlyOperation` ([`docs/topics/db/queries.txt`][queriesdoc]). Because `filter()`/`exclude()` _"do not actually run the query,"_ they are safe to call in async code; only evaluation must go through the async surface.

**Transactions: `atomic()`, nesting → savepoints.** Django runs in **autocommit** by default — _"Each query is immediately committed to the database, unless a transaction is active"_ ([`docs/topics/db/transactions.txt`][transactionsdoc]). `transaction.atomic()` is the single transaction API, usable as a decorator or context manager; its `Atomic` class docstring describes the nesting behavior precisely ([`django/db/transaction.py`][transaction]):

> _"When it's used as a context manager, **enter** creates a transaction or a savepoint, depending on whether a transaction is already in progress, and **exit** commits the transaction or releases the savepoint on normal exit, and rolls back the transaction or to the savepoint on exceptions."_

`atomic` works as a `decorator` or a `context manager`, and wrapping it in `try/except` gives natural integrity-error handling ([`docs/topics/db/transactions.txt`][transactionsdoc]):

```python
from django.db import IntegrityError, transaction


@transaction.atomic  # this whole view runs in one transaction
def viewfunc(request):
    do_stuff()
    with transaction.atomic():  # a nested block → a SAVEPOINT
        do_more_stuff()

# integrity errors can be caught and the block rolled back:
try:
    with transaction.atomic():
        generate_relationships()
except IntegrityError:
    handle_exception()
```

The topic guide restates the mechanism as an ordered protocol ([`docs/topics/db/transactions.txt`][transactionsdoc]):

> _"Under the hood, Django's transaction management code: opens a transaction when entering the outermost `atomic` block; creates a savepoint when entering an inner `atomic` block; releases or rolls back to the savepoint when exiting an inner block; commits or rolls back the transaction when exiting the outermost block."_

So a nested `atomic()` is a [savepoint][effects], not a nested `BEGIN` — the same top-level-`BEGIN` + inner-`SAVEPOINT` shape the effect systems implement, exposed here as a re-entrant context manager. `atomic(savepoint=False)` suppresses inner savepoints for overhead-sensitive blocks; `atomic(durable=True)` asserts the block is outermost and raises `RuntimeError` if nested ([`django/db/transaction.py`][transaction]). Django also _"uses transactions or savepoints automatically to guarantee the integrity of ORM operations that require multiple queries,"_ notably cascading `delete()` and multi-row `update()` ([`docs/topics/db/transactions.txt`][transactionsdoc]).

**Errors are exceptions, not a typed channel.** Failures raise Python exceptions from `django.db` — `IntegrityError`, `DataError`, `DatabaseError`, `NotSupportedError` (wrapping the driver's PEP-249 exceptions), plus ORM-level `DoesNotExist`/`MultipleObjectsReturned` on `get()`. The idiom is `try/except` around an `atomic()` block, where an `IntegrityError` inside the block leaves the transaction ready to roll back ([`docs/topics/db/transactions.txt`][transactionsdoc]). There is no type-level [error channel][effects] as in the effect-system libraries; the failure set is discovered from docs and runtime, not the type — the mainstream exception model, and a deliberate contrast with the survey's effects-first target.

## Ecosystem & maturity

Django is one of the most widely deployed web frameworks in any language, and its ORM is the default persistence layer for the entire Django ecosystem (Django REST Framework, the admin, `django-allauth`, and the bulk of Python web apps depend on it). It is licensed **BSD-3-Clause** (`LICENSE`), governed by the Django Software Foundation, and released on a strict time-based cadence with designated LTS versions (web-attested). The pinned tree is a `6.2` development checkout (`django/__init__.py`: `VERSION = (6, 2, 0, "alpha", 0)`); the framework first shipped in 2005 (web-attested), making the ORM roughly contemporary with Rails `ActiveRecord` and `SQLAlchemy`.

Backends are first-party for **PostgreSQL, MySQL/MariaDB, SQLite, and Oracle** (`django/db/backends/`, each backend's `DatabaseWrapper.display_name`), with third-party backends (CockroachDB, SQL Server via `mssql-django`) maintained out of tree. The dependency footprint is tiny — the ORM's only hard runtime dependency is `asgiref` (for `sync_to_async`); database drivers (`psycopg`, `mysqlclient`, `oracledb`) are the user's choice. `django/db/models/__init__.py` is the single public import surface, re-exporting `Model`, `Manager`, `F`, `Q`, `QuerySet`, `Prefetch`, and the field zoo under `__all__`.

## Strengths

- **One model, everything derived (DRY).** From a single `Model` class Django produces the table DDL, migrations, the query API, forms, and the admin — the _"single, definitive source of information about your data"_ ([`docs/topics/db/models.txt`][modelsdoc]).
- **Built-in, code-first migrations.** `makemigrations` diffs model state into an ordered, dependency-graphed, VCS-committable migration history — a first-party feature, not a bolt-on ([`docs/topics/migrations.txt`][migrationsdoc]).
- **Injection-safe by construction.** Every `QuerySet` value is a bound parameter; SQL code and parameters travel separately ([`docs/topics/security.txt`][security]).
- **Lazy, composable queries.** `QuerySet`s build without touching the DB and chain freely; the SQL fires once, at evaluation ([`docs/topics/db/queries.txt`][queriesdoc]).
- **Expressive DB-side computation.** `F()` pushes arithmetic/updates into SQL (race-free increments); `Q()` gives full boolean algebra; `annotate`/aggregates cover analytical queries.
- **Batteries-included and battle-tested.** Four first-party backends, a huge ecosystem, exhaustive documentation, and a decades-long track record.

## Weaknesses

- **Tightly coupled to Django.** The ORM assumes Django settings, apps, and the connection registry; using it outside a Django project is awkward (contrast `SQLAlchemy`, a standalone library).
- **Active-record instance methods; no unit of work.** Each `save()`/`delete()` is its own statement with no automatic minimal-diff flush or [identity map][orm]; batching multi-object writes is manual (`bulk_create`/`bulk_update`).
- **Lazy loading → N+1.** Related-object access silently fires a query; forgetting `select_related`/`prefetch_related` is the classic performance foot-gun ([`docs/ref/models/querysets.txt`][querysetsdoc]).
- **Lazy-`QuerySet` re-evaluation surprises.** A `QuerySet` re-runs its SQL when a chained method implies a different query, and slicing/`len()`/iteration each trigger evaluation — easy to fire duplicate or unexpected queries.
- **No compile-time query checking.** Field-lookup strings (`"blog__author__name"`) and column typos surface at runtime, not at type-check time — no static guarantee like `Diesel`/`sqlx`.
- **No typed error channel.** Failures are thrown `django.db` exceptions, not values in a type — the opposite of the effects-first model.
- **Async is a mirror, not native.** `aget`/`async for` delegate to sync bodies via `sync_to_async` (thread offloading), not an async wire protocol.

## Key design decisions and trade-offs

| Decision                                                            | Rationale                                                                                    | Trade-off                                                                                                    |
| ------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| Model = table + persistence methods (active-record)                 | One definitive source of data (DRY); `user.save()` is intuitive; minimal ceremony            | Persistence-aware objects; couples domain model to the DB; harder to unit-test in isolation                  |
| `Manager`/`QuerySet` split for querying                             | Data-mapper-ish separation of "objects" from "how to query"; chainable, reusable query logic | Two concepts (`objects` + `QuerySet`) to learn; still not a full data mapper (persistence stays on instance) |
| **No unit of work / identity map / change tracking**                | Predictable, explicit persistence — each `save()` is one obvious statement                   | No automatic minimal-diff flush; two loads of a row are two objects; batching is manual                      |
| **Lazy `QuerySet`** (build freely, evaluate once)                   | Compose filters without DB hits; one SQL round-trip; queries are reusable inert values       | Re-evaluation surprises; slicing/`len()`/iteration trigger hidden queries; easy to fire duplicates           |
| **Lazy related-object loading** by default                          | Convenient attribute access (`e.blog`); no upfront join cost                                 | [N+1][nplusone] by default; must remember `select_related` (join) / `prefetch_related` (separate query)      |
| Values are bound parameters; `raw()`/`extra()` are the escape hatch | Injection impossible for DSL values; SQL and params separate ([`security.txt`][security])    | Raw hatches re-expose injection if you string-build; `extra()` is soft-deprecated                            |
| Built-in code-first migrations (`makemigrations`)                   | Schema derived from models (DRY); versioned, graphed, replayable history                     | Autodetector can guess wrong on ambiguous renames; no maintained db-first sync (`inspectdb` is a scaffold)   |
| Blocking by default; async via `sync_to_async` mirror               | Simple synchronous mental model; async views supported without a rewrite                     | Async is thread-offloaded, not a native async driver; two API surfaces (`get`/`aget`) to keep in sync        |
| Exceptions, not typed errors                                        | Idiomatic Python; `try/except` around `atomic()`                                             | Failure set not in the type; no `isRetryable`-style flags on the error value                                 |

---

## Sources

- [django/django — GitHub repository][repo] · [docs.djangoproject.com][docs]
- [`django/db/models/base.py` — `ModelBase` metaclass builds `_meta`/`objects`; `Model.save()`/`delete()`/`asave`/`adelete` (active-record persistence)][basepy]
- [`django/db/models/query.py` — `QuerySet`: lazy `_fetch_all`/`_result_cache`, `filter`/`exclude`/`annotate` clone-and-chain, `get`/`create`/`aget`, `select_related`/`prefetch_related`, `raw`/`extra`][querypy]
- [`django/db/models/manager.py` + `docs/topics/db/managers.txt` — `Manager`/`objects` as the query interface][managersdoc]
- [`django/db/models/expressions.py` — `F()` (DB-side expressions)][expressions] · [`django/db/models/query_utils.py` — `Q` (boolean filter algebra)][queryutils]
- [`django/db/models/fields/__init__.py` — `Field.db_type()` / `get_internal_type()` (type mapping); the field zoo][fields]
- [`django/db/models/fields/related_descriptors.py` — `ForwardManyToOneDescriptor.__get__` (lazy related load → N+1)][related] · [`django/db/models/fields/related.py` — `ForeignKey.get_attname` (`_id` column), `create_many_to_many_intermediary_model` (M2M through table)][relatedfk]
- [`django/db/models/sql/compiler.py` — `(sql, params)` compilation; `cursor.execute(sql, params)` (parameterization)][compiler]
- [`django/db/transaction.py` — `atomic()` / `Atomic` (transactions, nesting → savepoints, `durable`)][transaction]
- [`django/db/migrations/{autodetector,graph,migration}.py` — model-state diff, migration digraph, `Migration` base class][autodetector]
- [`docs/topics/db/models.txt` — "single, definitive source of information"; 1:1 model↔table][modelsdoc] · [`docs/misc/design-philosophies.txt` — DRY / "deduce as much as possible"][philosophy]
- [`docs/topics/db/queries.txt` — "QuerySets are lazy"; async queries (`aget`/`async for`)][queriesdoc] · [`docs/ref/models/querysets.txt` — when evaluated; `select_related`/`prefetch_related`][querysetsdoc]
- [`docs/ref/models/expressions.txt` — `F()` expressions][expressionsdoc] · [`docs/topics/security.txt` — SQL injection protection via parameterization][security]
- [`docs/topics/migrations.txt` — migrations as "version control for your schema"][migrationsdoc] · [`docs/topics/db/transactions.txt` — autocommit, `atomic`, savepoints][transactionsdoc] · [`docs/ref/databases.txt` — persistent connections / pooling][databasesdoc]
- Shared vocabulary: [SQL & ORM concepts][concepts] ([abstraction ladder][ladder] · [query models][models] · [injection][inject] · [ORM patterns][orm] · [N+1][nplusone] · [effects & transactions][effects] · [pools][pool])
- Related deep-dives in this survey: `SQLAlchemy` (the unit-of-work Python alternative) · `ActiveRecord` (the Ruby active-record sibling) · [Ecto][ecto] (rejects lazy loading) · `EF Core` · `Hibernate` · `Prisma`

<!-- References -->

[repo]: https://github.com/django/django
[docs]: https://docs.djangoproject.com/en/stable/
[basepy]: https://github.com/django/django/blob/2e48636c54910e435eb31e1b7d8a8089c84233ad/django/db/models/base.py
[querypy]: https://github.com/django/django/blob/2e48636c54910e435eb31e1b7d8a8089c84233ad/django/db/models/query.py
[managersdoc]: https://github.com/django/django/blob/2e48636c54910e435eb31e1b7d8a8089c84233ad/docs/topics/db/managers.txt
[expressions]: https://github.com/django/django/blob/2e48636c54910e435eb31e1b7d8a8089c84233ad/django/db/models/expressions.py
[queryutils]: https://github.com/django/django/blob/2e48636c54910e435eb31e1b7d8a8089c84233ad/django/db/models/query_utils.py
[fields]: https://github.com/django/django/blob/2e48636c54910e435eb31e1b7d8a8089c84233ad/django/db/models/fields/__init__.py
[related]: https://github.com/django/django/blob/2e48636c54910e435eb31e1b7d8a8089c84233ad/django/db/models/fields/related_descriptors.py
[relatedfk]: https://github.com/django/django/blob/2e48636c54910e435eb31e1b7d8a8089c84233ad/django/db/models/fields/related.py
[compiler]: https://github.com/django/django/blob/2e48636c54910e435eb31e1b7d8a8089c84233ad/django/db/models/sql/compiler.py
[transaction]: https://github.com/django/django/blob/2e48636c54910e435eb31e1b7d8a8089c84233ad/django/db/transaction.py
[autodetector]: https://github.com/django/django/blob/2e48636c54910e435eb31e1b7d8a8089c84233ad/django/db/migrations/autodetector.py
[graph]: https://github.com/django/django/blob/2e48636c54910e435eb31e1b7d8a8089c84233ad/django/db/migrations/graph.py
[migration]: https://github.com/django/django/blob/2e48636c54910e435eb31e1b7d8a8089c84233ad/django/db/migrations/migration.py
[modelsdoc]: https://github.com/django/django/blob/2e48636c54910e435eb31e1b7d8a8089c84233ad/docs/topics/db/models.txt
[philosophy]: https://github.com/django/django/blob/2e48636c54910e435eb31e1b7d8a8089c84233ad/docs/misc/design-philosophies.txt
[queriesdoc]: https://github.com/django/django/blob/2e48636c54910e435eb31e1b7d8a8089c84233ad/docs/topics/db/queries.txt
[querysetsdoc]: https://github.com/django/django/blob/2e48636c54910e435eb31e1b7d8a8089c84233ad/docs/ref/models/querysets.txt
[expressionsdoc]: https://github.com/django/django/blob/2e48636c54910e435eb31e1b7d8a8089c84233ad/docs/ref/models/expressions.txt
[security]: https://github.com/django/django/blob/2e48636c54910e435eb31e1b7d8a8089c84233ad/docs/topics/security.txt
[migrationsdoc]: https://github.com/django/django/blob/2e48636c54910e435eb31e1b7d8a8089c84233ad/docs/topics/migrations.txt
[transactionsdoc]: https://github.com/django/django/blob/2e48636c54910e435eb31e1b7d8a8089c84233ad/docs/topics/db/transactions.txt
[databasesdoc]: https://github.com/django/django/blob/2e48636c54910e435eb31e1b7d8a8089c84233ad/docs/ref/databases.txt
[concepts]: ./concepts.md
[ladder]: ./concepts.md#the-abstraction-ladder
[models]: ./concepts.md#query-construction-models
[inject]: ./concepts.md#statements-parameters-and-sql-injection
[orm]: ./concepts.md#orm-patterns
[nplusone]: ./concepts.md#loading-strategies-and-the-n1-problem
[effects]: ./concepts.md#effects-transactions-and-error-handling
[pool]: ./concepts.md#connections-pools-and-sessions
[ecto]: ./ecto.md
