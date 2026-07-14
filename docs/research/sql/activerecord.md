# Active Record (Ruby / Rails)

The archetypal [Active Record pattern][orm]: a model class maps 1:1 to a table and its _instances_ carry both the row's data and its own persistence (`user.save`, `User.create`, `user.destroy`), fronted by a lazy, chainable `Relation` query interface.

| Field              | Value                                                                                                                      |
| ------------------ | -------------------------------------------------------------------------------------------------------------------------- |
| Language           | Ruby (`activerecord.gemspec`: `required_ruby_version >= 3.3.1`)                                                            |
| License            | MIT (`activerecord/MIT-LICENSE`, © David Heinemeier Hansson; `gemspec` `license = "MIT"`)                                  |
| Repository         | [rails/rails][repo] (the `activerecord/` sub-directory)                                                                    |
| Documentation      | [api.rubyonrails.org][api] · [Active Record Basics guide][guide]                                                           |
| Category           | [Full ORM (active-record)][ladder] — the pattern's namesake reference implementation                                       |
| Abstraction level  | [Full ORM][ladder] — the top rung; change tracking, associations, lazy loading, migrations                                 |
| Query model        | [`Relation` method chains (lazy) + finder methods][qcm] delegating to `all`                                                |
| Effect/async model | Blocking, per-thread [connection pool][pool]; eager returns (raise on error) — plus an opt-in `load_async` background pool |
| Backends           | PostgreSQL, MySQL/MariaDB (`mysql2` + `trilogy`), SQLite — first-party adapters under `connection_adapters/`               |
| First release      | ≈2004 (shipped with the first public Rails; web-attested)                                                                  |
| Latest version     | `8.2.0.alpha` (pinned tree, `gem_version.rb`); 8.x stable line (web-attested)                                              |

> [!NOTE]
> Active Record is this survey's data point for the **full ORM built on Fowler's
> [Active Record pattern][orm]** — objects that _are_ their own persistence layer — and
> the baseline every other ORM here is measured against. It sits at the opposite pole
> from the effect-system libraries: persistence is a mutating _method call_ on a mutable
> object, not a first-class effect value; errors are _exceptions_, not a typed channel;
> and associations are _lazy by default_, the classic [N+1][nplusone] foot-gun. It shares
> the pattern with `Django ORM`, `GORM`, and TypeORM's active-record mode, and stands
> against the [data-mapper][orm] ORMs (`Hibernate`, `EF Core`, `SQLAlchemy`) and the
> functional data mappers (`Ecto`, `doobie`, `Quill`) that keep data and persistence
> apart. Terms below link to [concepts][concepts].

---

## Overview

### What it solves

Active Record is the `activerecord` gem inside Rails — in its own `gemspec`, an _"Object-relational mapper framework (part of Rails)"_ whose job is to _"Build a persistent domain model by mapping database tables to Ruby classes"_ ([`activerecord.gemspec`][gemspec]). The `README.rdoc` (which is literally spliced in as the `ActiveRecord` module's own documentation — `active_record.rb` opens with `# :include: ../README.rdoc`) states the goal as near-zero configuration ([`README.rdoc`][readme]):

> _"Active Record connects classes to relational database tables to establish an almost
> zero-configuration persistence layer for applications. The library provides a base
> class that, when subclassed, sets up a mapping between the new class and an existing
> table in the database. In the context of an application, these classes are commonly
> referred to as *models*."_

A model is a subclass of `ActiveRecord::Base` (or `ApplicationRecord`) with **no attribute declarations at all** — the columns are read from the table itself ([`base.rb`][base]):

> _"Active Record objects don't specify their attributes directly, but rather infer them
> from the table definition with which they're linked. Adding, removing, and changing
> attributes and their type is done directly in the database. Any change is instantly
> reflected in the Active Record objects."_

```ruby
# The table is the source of truth; the class declares almost nothing.
class Product < ActiveRecord::Base
end
# maps to the `products` table, exposing Product#name / Product#name=(...) accessors
```

This is a **db-first-ish** posture unusual among code-first ORMs: the live table shapes the class, and a checked-in `db/schema.rb` (dumped after each migration) records the current structure (see [Schema, migrations & code generation](#schema-migrations-code-generation)).

### Design philosophy

Active Record is the implementation _named after_ the pattern it implements. The `README.rdoc` cites Fowler directly ([`README.rdoc`][readme]):

> _"Active Record is an implementation of the object-relational mapping (ORM) pattern by
> the same name described by Martin Fowler: 'An object that wraps a row in a database
> table or view, encapsulates the database access, and adds domain logic on that data.'"_

That one sentence is the whole thesis of this deep-dive: **data and behaviour live in the
same object**, and each instance _encapsulates the database access_ for its own row. The
design bet that makes it ergonomic is **convention over configuration** ([`README.rdoc`][readme]):

> _"The prime directive for this mapping has been to minimize the amount of code needed to
> build a real-world domain model. This is made possible by relying on a number of
> conventions that make it easy for Active Record to infer complex relations and
> structures from a minimal amount of explicit direction._
>
> _Convention over Configuration:_
>
> - _No XML files!_
> - _Lots of reflection and run-time extension_
> - _Magic is not inherently a bad word"_

The conventions do a lot of silent work: a class `Product` maps to table `products`
(pluralized, snake-cased); the primary key is `id`; `created_at` / `updated_at` are
maintained automatically; a `belongs_to :author` implies an `author_id` foreign key. The
README is explicit that these are inferences you _can_ override but are encouraged not to:
_"Active Record relies heavily on naming in that it uses class and association names to
establish mappings between respective database tables and foreign key columns"_
([`README.rdoc`][readme]).

The second half of the philosophy is a deliberate refusal to fully abstract SQL away
([`README.rdoc`][readme]):

> _"Admit the Database:_
>
> - _Lets you drop down to SQL for odd cases and performance_
> - _Doesn't attempt to duplicate or replace data definitions"_

## Connection, pooling & resource lifetime

Active Record is **blocking** over a **per-thread connection pool**. A connection is
leased for the duration of a unit of work (in Rails, one web request) and returned
afterward; the pool serializes thread access to a bounded set of real connections
([`connection_adapters/abstract/connection_pool.rb`][pool_rb]):

> _"A connection pool synchronizes thread access to a limited number of database
> connections. The basic idea is that each thread checks out a database connection from
> the pool, uses that connection, and checks the connection back in. ConnectionPool is
> completely thread-safe, and will ensure that a connection cannot be used by two threads
> at the same time … if all connections have been checked out, and a thread tries to
> checkout a connection anyway, then ConnectionPool will wait until some other thread has
> checked in a connection, or the `checkout_timeout` has expired."_

The lifetime model is **ambient, not scoped**: rather than threading an explicit
connection handle through every call (a [scoped acquire/release][pool] à la Effect's
`Acquirer` or ZIO's `Scope`), Active Record binds the checked-out connection to the
_current thread_, so any model query on that thread implicitly uses it
([`connection_adapters/abstract/connection_pool.rb`][pool_rb]): _"While a thread has a
connection checked out from the pool … that connection will automatically be the one used
by ActiveRecord queries executing on that thread. It is not required to explicitly pass
the checked out connection to Rails models or queries."_ You establish the pool with
`ActiveRecord::Base.establish_connection(adapter: 'postgresql', …)` ([`README.rdoc`][readme]);
`with_connection { |c| … }` yields a connection for a block and returns it to the pool
afterward. Because concurrency is thread-per-request and the pool is finite, pool sizing
(`pool_size`, `checkout_timeout`) is the central resource-lifetime knob.

## Query construction & injection safety

This is the heart of Active Record and the section this survey weighs most. Two related
mechanisms sit here: the **lazy `Relation`** (how a query is _built_) and **parameter
binding / sanitization** (why it is _safe_).

**Class-level finders delegate to a lazy `Relation`.** Every query method a model exposes
(`where`, `order`, `joins`, `includes`, `limit`, `find_by`, `count`, …) is defined once as
a delegation to `all` ([`querying.rb`][querying]):

```ruby
# activerecord/lib/active_record/querying.rb
QUERYING_METHODS = [
  :find, :find_by, :find_by!, :take, :first, :last, # …
  :where, :rewhere, :order, :group, :limit, :offset, :joins, :includes, :eager_load,
  :count, :average, :minimum, :maximum, :sum, :pluck, # …
].freeze
delegate(*QUERYING_METHODS, to: :all)
```

`all` returns an `ActiveRecord::Relation` — an inert query object that does **not** touch
the database until it is enumerated ([`scoping/named.rb`][named]):

```ruby
# activerecord/lib/active_record/scoping/named.rb  (doc for `all`)
#   posts = Post.all
#   posts.size # Fires "select count(*) from  posts" and returns the count
#   posts.each {|p| puts p.name } # Fires "select * from posts" and loads post objects
#
#   fruits = Fruit.all
#   fruits = fruits.where(color: 'red') if options[:red_only]
#   fruits = fruits.limit(10) if limited?
```

The example shows both defining properties: the SQL fires only on `size` / `each` (lazy),
and a `Relation` is **composable** — `where`/`limit` each return a new `Relation`, so a
query is assembled clause-by-clause, conditionally, before any round-trip. `Relation#load`
forces the load explicitly and returns the relation itself, not the rows
([`relation.rb`][relation]). A canonical chain:

```ruby
User.where(active: true).order(:name).limit(10)   # builds SQL, runs nothing
     .each { |u| puts u.name }                    # NOW the SELECT fires
```

**Parameter binding — three `where` forms, three safety stories.** The `where` docstring
enumerates the accepted condition formats and warns precisely where injection enters
([`relation/query_methods.rb`][querymethods]):

- **Hash form** `where(name: "Joe")` — the safe default. It is turned into an Arel bind
  parameter: the predicate builder wraps the value in a `Relation::QueryAttribute` bound
  node ([`relation/predicate_builder.rb`][predicate]), which the adapter sends as an
  **out-of-band placeholder** in a prepared statement, so the value is never SQL text.

  ```ruby
  # activerecord/lib/active_record/relation/predicate_builder.rb
  def build_bind_attribute(column_name, value)
    Relation::QueryAttribute.new(column_name, value, table.type(column_name))
  end
  ```

- **Array form** `where("age > ?", x)` / `where("name = :n", n: x)` — also injection-safe,
  but by a _different_ mechanism: the `?`/named placeholders are filled by
  `sanitize_sql_array`, which routes each value through the adapter's `quote`
  ([`sanitization.rb`][sanitization]). The docstring is explicit ([`relation/query_methods.rb`][querymethods]):
  _"If an array is passed, then the first element of the array is treated as a template …
  Active Record takes care of building the query to avoid injection attacks, and will
  convert from the ruby type to the database type where needed."_ Note the subtlety: this
  is **server-side escaping interpolated at build time**, not an out-of-band bind — safe,
  but a different guarantee from the hash form.

- **Bare string form** `where("age > '#{x}'")` — **the classic Rails SQLi foot-gun.** A
  single string is passed through as a raw SQL fragment, and the docstring says so
  ([`relation/query_methods.rb`][querymethods]): _"Note that building your own string from
  user input may expose your application to injection attacks if not done properly."_

The `base.rb` moduledoc has carried the canonical worked example of this fork for two
decades ([`base.rb`][base]):

```ruby
# activerecord/lib/active_record/base.rb  (moduledoc)
class User < ActiveRecord::Base
  def self.authenticate_unsafely(user_name, password)
    where("user_name = '#{user_name}' AND password = '#{password}'").first
  end

  def self.authenticate_safely(user_name, password)
    where("user_name = ? AND password = ?", user_name, password).first
  end

  def self.authenticate_safely_simply(user_name, password)
    where(user_name: user_name, password: password).first
  end
end
```

The doc spells out the difference ([`base.rb`][base]): _"The `authenticate_unsafely` method
inserts the parameters directly into the query and is thus susceptible to SQL-injection
attacks if the `user_name` and `password` parameters come directly from an HTTP request.
The `authenticate_safely` and `authenticate_safely_simply` both will sanitize the
`user_name` and `password` before inserting them in the query."_

**The `sanitize_sql` family and the `Arel.sql()` guard.** The `Sanitization` module (mixed
into every model) exposes `sanitize_sql_for_conditions` / `sanitize_sql_for_assignment` /
`sanitize_sql_for_order`, which quote-escape values into a SQL fragment
([`sanitization.rb`][sanitization]); these back the array-form `where`, `update_all`,
`order`, and friends. To stop a raw string sneaking into a "dangerous" method (`order`,
`pluck`, `group`, …), Active Record raises unless the caller opts in by wrapping a
known-safe fragment in `Arel.sql()` ([`sanitization.rb`][sanitization]):

> _"Dangerous query method (method whose arguments are used as raw SQL) called with
> non-attribute argument(s): … This method should not be called with user-provided values,
> such as request parameters or model attributes. Known-safe values can be passed by
> wrapping them in `Arel.sql()`."_

The genuinely raw escape hatch is `find_by_sql` (and `Model.connection.execute`), and it,
too, carries the warning ([`querying.rb`][querying]): _"Note that building your own SQL
query string from user input may expose your application to injection attacks."_ Its
positional/named `?` / `:key` placeholders remain sanitized, so the door is narrow and
loudly labelled — the same posture as `Ecto`'s `fragment`, reached through a method rather
than a macro.

## Schema, migrations & code generation

Active Record is **code-first for the schema's evolution** but **db-first for the model's
attributes**: migrations (Ruby DSL) drive the DDL, the live database is the source of
truth for a model's columns, and `db/schema.rb` is a _dumped_ record of the result.

**Migrations are a code DSL.** A migration is a class with `up`/`down` (or a reversible
`change`) built from schema-transformation methods ([`migration.rb`][migration]):

> _"Migrations can manage the evolution of a schema used by several physical databases …
> With migrations, you can describe the transformations in self-contained classes that can
> be checked into version control systems and executed against another database that might
> be one, two, or five versions behind."_

```ruby
# activerecord/lib/active_record/migration.rb  (moduledoc)
class AddSystemSettings < ActiveRecord::Migration[8.2]
  def up
    create_table :system_settings do |t|
      t.string  :name
      t.string  :label
      t.text    :value
      t.integer :position
    end
  end

  def down
    drop_table :system_settings
  end
end
```

The DSL vocabulary is broad — `create_table`, `add_column`, `add_index`, `add_reference`,
`add_foreign_key`, `add_timestamps`, `change_column`, `rename_column`, `drop_table`, … —
each documented in the `migration.rb` "Available transformations" list ([`migration.rb`][migration]).
A migration may also run ordinary Ruby (even the models themselves) to seed or backfill
data.

**A version table + a dumped schema.** `bin/rails db:migrate` runs the pending migrations
in order, recording which have run in a bookkeeping table ([`migration.rb`][migration]):

> _"This will update the database by running all of the pending migrations, creating the
> `schema_migrations` table … if missing. It will also invoke the db:schema:dump command,
> which will update your db/schema.rb file to match the structure of your database."_

So the pipeline is: hand-written migrations → applied and tracked in `schema_migrations`
→ the resulting structure dumped to `db/schema.rb` (defaulting to `schema_format = :ruby`,
per `active_record.rb`). The dumped schema is what a fresh checkout loads to build the
database, and what the models introspect at boot — a **db-first attribute model layered on
code-first DDL**. There is **no db-first codegen** in the `jOOQ`/`sqlc` sense: no typed
structs or column constants are generated; the "code" derived from the schema is the
runtime accessors Active Record synthesizes by reflection, not a source artifact.

## Type mapping & result decoding

Row hydration is by convention and reflection. A finder loads each row into a **new model
instance**, decoding cells to Ruby types via the column's registered type; the persistence
docstring is explicit that finders build a fresh object per row ([`persistence.rb`][persistence]):
_"By calling `instantiate` instead of `new`, finder methods ensure they get new instances
of the appropriate class for each record."_ (That "new instance per record" is also why
there is no [identity map][orm] — see below.) Single-table inheritance uses a `type`
column to pick the subclass for each row.

Attribute access is generated: every column gets a reader, a writer, and a `?` query
method — `user.name`, `user.name = "…"`, `user.name?` ([`base.rb`][base]). Nullability is
plain Ruby `nil` (no `Option`/`Maybe` wrapper). Custom mappings are declared with the
`attribute` API / `serialize` (YAML/JSON into a text column), and value objects can be
`composed_of` several columns ([`README.rdoc`][readme]). The decoding is **runtime and
schema-driven**, not compile-time — a column typo surfaces as a `NoMethodError` /
`StatementInvalid` at runtime, the expected trade-off for a dynamically-typed ORM (as with
`Ecto`, and unlike `Diesel` / `Slick`).

**Validations** sit on top of type mapping as a per-model, runtime concern
([`README.rdoc`][readme]): `validates :subdomain, uniqueness: true`,
`validates :terms_of_service, acceptance: true, on: :create`. They run inside `save` and,
on failure, populate `record.errors` and make `save` return `false` (or `save!` raise
`RecordInvalid`).

## Effect model, transactions & error handling

This is the dimension on which Active Record differs most sharply from the effect-system
libraries this survey is designed around.

**The Active Record pattern: persistence is a method on a mutable object.** There is no
effect value and no repository boundary — the _object saves itself_. A model instance is
constructed, mutated, and told to persist ([`persistence.rb`][persistence]):

```ruby
user = User.new(name: "David")   # in-memory, new_record? == true
user.name = "Dave"
user.save                        # INSERT (or UPDATE if persisted?)

User.create(name: "Jamie")       # new + save in one call
user.update(name: "Dave")        # assign + save
user.destroy                     # DELETE this row
```

`save` decides INSERT vs UPDATE from the instance's own state ([`persistence.rb`][persistence]):
_"Saves the model. If the model is new, a record gets created in the database, otherwise
the existing record gets updated."_ `create` is literally `new` then `save`
([`persistence.rb`][persistence]); `destroy` _"Deletes the record in the database and
freezes this instance."_ The failure convention is split by method suffix: `save` /
`create` **return `false`** on a validation failure, while `save!` / `create!` **raise
`ActiveRecord::RecordInvalid`** ([`persistence.rb`][persistence]) — errors are
**exceptions**, not a typed channel, exactly the mainstream JDBC/ADO.NET posture the
effect-system pages contrast against.

**Dirty tracking — per-instance change tracking, but no unit of work.** Each instance
snapshots its attributes and tracks which changed ([`attribute_methods/dirty.rb`][dirty]):

```ruby
# activerecord/lib/active_record/attribute_methods/dirty.rb  (moduledoc)
person = Person.create(name: "Allison")
person.changed?                   # => false
person.name = 'Alice'
person.will_save_change_to_name?  # => true
person.changes_to_save            # => {"name"=>["Allison", "Alice"]}
person.save
person.saved_change_to_name       # => ["Allison", "Alice"]
```

Dirty tracking is a genuine efficiency feature — `partial_updates` and `partial_inserts`
default to `true` ([`attribute_methods/dirty.rb`][dirty]), so `save` writes **only the
changed columns**, not the whole row. But note what it is _not_: this is **per-instance**
tracking, scoped to one object. There is **no session, no [identity map][orm], and no
[unit of work][orm]** — no ambient context that collects every dirty object and flushes a
minimal, correctly-ordered batch of statements on commit. Each `save` is its own
statement, fired immediately; loading the same row twice yields two independent objects
whose edits can silently diverge. This is the defining architectural gap versus the
data-mapper ORMs (`Hibernate`'s `Session`, `EF Core`'s `SaveChanges`, `SQLAlchemy`'s
`Session`) — and the reason `Ecto` positions its explicit `Changeset` against exactly this
"mutable self-persisting entity" model.

**Associations are lazy by default — the N+1 foot-gun.** Associations are declared with
macro-like class methods and traversed as ordinary accessors ([`associations.rb`][associations]):

```ruby
class Project < ActiveRecord::Base
  belongs_to              :portfolio
  has_one                 :project_manager
  has_many                :milestones
  has_and_belongs_to_many :categories
end
```

The accessor fires its query the _first time it is touched_ ([`associations.rb`][associations]):
_"Active Record accesses associations lazily, when used."_ Iterating a collection and
touching an association per element is therefore the textbook [N+1][nplusone]
([`associations.rb`][associations]):

> _"Eager loading … is one of the easiest ways to prevent the dreaded N+1 problem in which
> fetching 100 posts that each need to display their author triggers 101 database queries.
> Through the use of eager loading, the number of queries will be reduced from 101 to 2."_

The fix is `includes`, which eager-loads the named associations up front
([`relation/query_methods.rb`][querymethods]): _"Specify associations `args` to be eager
loaded to prevent N + 1 queries."_

```ruby
Post.includes(:author, :comments).each do |post|   # 3 queries total, not 201
  puts post.author.name
end
# SELECT * FROM posts
# SELECT * FROM authors  WHERE id      IN (…)
# SELECT * FROM comments WHERE post_id IN (…)
```

`includes` issues one extra query per association (or falls back to a `LEFT OUTER JOIN`
when a `where` references the joined table via `references`); `eager_load` forces the join,
`preload` forces the separate query ([`relation/query_methods.rb`][querymethods]). Lazy-by
default plus an opt-in eager escape hatch is precisely the shape `Ecto` rejects (no lazy
loading at all) and that data-mapper ORMs share.

**Transactions: a block that commits or rolls back, with savepoint-emulated nesting.**
A transaction is a class (or instance) method taking a block ([`transactions.rb`][transactions]):

> _"Transactions are protective blocks where SQL statements are only permanent if they can
> all succeed as one atomic action."_

```ruby
ActiveRecord::Base.transaction do
  david.withdrawal(100)
  mary.deposit(100)
end
```

The block commits on normal exit and **rolls back on any raised exception**, which is then
re-raised — except `ActiveRecord::Rollback`, which triggers the ROLLBACK but is swallowed
by the block ([`transactions.rb`][transactions]). Because transactions are **per
connection, not per model**, objects of different classes freely share one
([`transactions.rb`][transactions]). `save` and `destroy` are themselves _"automatically
wrapped in a transaction"_ so validations and callbacks run under its cover
([`transactions.rb`][transactions]).

**Nesting** is flattened unless you ask for a real sub-transaction ([`transactions.rb`][transactions]):
by default an inner `transaction` block joins the parent (an inner `ActiveRecord::Rollback`
does _not_ roll back the outer work — _"the following behavior may be surprising … creates
both 'Kotori' and 'Nemu'"_). Passing `requires_new: true` opens a real sub-transaction that
rolls back independently, and Active Record implements this with **savepoints**
([`transactions.rb`][transactions]):

> _"Most databases don't support true nested transactions … Because of this, Active Record
> emulates nested transactions by using savepoints."_

```ruby
User.transaction do
  User.create(username: 'Kotori')
  User.transaction(requires_new: true) do   # SAVEPOINT
    User.create(username: 'Nemu')
    raise ActiveRecord::Rollback             # rolls back to the savepoint only
  end
end
# only "Kotori" is created
```

**Lifecycle callbacks wrap every write.** Active Record threads user hooks through the
whole persistence life cycle ([`callbacks.rb`][callbacks]): saving a new record runs, in
order, `before_validation`, `after_validation`, `before_save`, `before_create`,
`after_create`, `after_save`, and (post-commit) `after_commit` — with the docstring
counting _"nineteen callbacks in total"_ across create/update/destroy/find/touch and the
transactional `after_commit` / `after_rollback` ([`callbacks.rb`][callbacks]). This is what
makes Active Record "fat model" ergonomics possible and, taken to excess, the "callback
hell" its critics cite.

**Async is an opt-in escape hatch, not the model.** The base model is blocking, but a
`Relation` can be scheduled on a background thread pool with `load_async`
([`relation.rb`][relation]): _"Schedule the query to be performed from a background thread
pool … When the `Relation` is iterated, if the background query wasn't executed yet, it
will be performed by the foreground thread."_ There are `async_count` / `async_sum` /
`async_find_by_sql` siblings. This is concurrency of _independent queries_, not an async
API surface — the return of a synchronous call is still a materialized object, and errors
still raise.

## Ecosystem & maturity

Active Record is the most widely deployed ORM in the Ruby world and the persistence layer
of Ruby on Rails; it is released under the permissive **MIT** license
([`activerecord/MIT-LICENSE`][license], © David Heinemeier Hansson), and the `Arel`
SQL-AST layer it builds on carries its own historical copyright in the same file. The
pinned tree is `8.2.0.alpha` (`gem_version.rb`); the stable 8.x line and the ≈2004 first
release (with the original public Rails) are web-attested. First-party database support is
**PostgreSQL, MySQL/MariaDB, and SQLite**, each a concrete adapter under
`connection_adapters/` (`postgresql_adapter.rb`, `mysql2_adapter.rb`, `trilogy_adapter.rb`,
`sqlite3_adapter.rb`), reachable by `establish_connection(adapter: 'postgresql', …)`
([`README.rdoc`][readme]); third-party gems register further adapters through
`ConnectionAdapters.register` ([`connection_adapters.rb`][adapters]). As the pattern's
reference implementation it is the yardstick the other ORMs in this survey — `Django ORM`,
`GORM`, `TypeORM`, `SQLAlchemy`, `Hibernate`, `EF Core`, `Prisma`, `Ecto` — position
themselves relative to.

## Strengths

- **Minimal ceremony.** A model is an empty subclass; columns, accessors, primary key, and
  timestamps come from convention. `User.create(name: "…")` is the whole write path.
- **The Active Record pattern, fully realized.** Data and behaviour in one object; the
  record persists, validates, and tracks its own changes — extremely productive for
  CRUD-shaped domains.
- **Lazy, composable `Relation`.** Queries are inert, chainable objects assembled
  clause-by-clause and run on enumeration; the same delegation powers finders, scopes, and
  associations.
- **Injection-safe defaults.** Hash conditions bind out-of-band; array conditions quote via
  the adapter; the raw-string and "dangerous method" paths raise or are loudly documented
  ([`sanitization.rb`][sanitization]).
- **Dirty tracking → partial writes.** `save` writes only changed columns
  (`partial_updates`), for free, per instance ([`attribute_methods/dirty.rb`][dirty]).
- **Batteries-included lifecycle.** Migrations, validations, callbacks, associations,
  savepoint-nested transactions, STI, and multi-database support ship in one gem.
- **Mature and ubiquitous.** Two decades of production use; the archetype the ecosystem
  standardizes on.

## Weaknesses

- **No unit of work / identity map.** Each `save` is its own immediate statement; there is
  no session that batches a minimal, ordered flush, and two loads of one row are two
  objects that can diverge — unlike `Hibernate` / `EF Core` / `SQLAlchemy`.
- **Lazy associations → N+1.** Convenient `user.posts` access silently fans out to one
  query per parent; the fix (`includes`) is opt-in and easy to forget ([`associations.rb`][associations]).
- **Exceptions, not typed errors.** Failures raise (`RecordInvalid`, `StatementInvalid`);
  the `save`-returns-`false` vs `save!`-raises split is a convention, and there is no
  type-level error channel like the effect-system libraries carry.
- **Blocking model.** Per-thread pool; concurrency is thread-per-request, not an effect or
  async value. `load_async` is a targeted escape hatch, not the API's shape.
- **No compile-time query typing.** Ruby is dynamic; a bad column or shape mismatch is a
  runtime error, unlike `Diesel` / `Slick` / `jOOQ`.
- **Fat models & callback-heavy lifecycles.** Putting data, persistence, validation, and
  lifecycle logic in one class scales poorly; implicit `after_save` side-effects are a
  well-known testability and coupling critique of the pattern.
- **The string-interpolation SQLi foot-gun persists.** Nothing stops
  `where("… '#{params[:x]}'")`; safety is a matter of using the hash/array forms, which the
  docs urge but the language does not enforce ([`base.rb`][base]).

## Key design decisions and trade-offs

| Decision                                                         | Rationale                                                                                              | Trade-off                                                                                                                        |
| ---------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------- |
| Active Record pattern: data + persistence in the model instance  | Minimal code; the object encapsulates its own row's DB access ([`README.rdoc`][readme])                | Fat models, persistence-coupled domain logic, harder unit testing; the pattern's canonical critique                              |
| Convention over configuration (table/`id`/timestamps inferred)   | Near-zero boilerplate; "infer complex relations from minimal direction" ([`README.rdoc`][readme])      | "Magic" is implicit; overrides fight the conventions; the mapping is db-shaped, so a schema drift surprises the model at runtime |
| Lazy, chainable `Relation` delegated from `all`                  | Inert, composable queries; one code path for finders/scopes/associations                               | Enumeration triggers I/O at a distance; accidental early enumeration re-queries                                                  |
| Hash binds out-of-band; array quotes via adapter; string is raw  | Safe by default with an ergonomic surface; raw SQL stays reachable ([`sanitization.rb`][sanitization]) | Three mechanisms with three guarantees; the bare-string form re-opens injection                                                  |
| Per-instance dirty tracking, **no** unit of work / identity map  | Simple, predictable, partial-column writes; no hidden flush ordering                                   | No minimal-diff batch flush; no one-object-per-row guarantee; multi-entity writes are manual                                     |
| Associations lazy by default, eager via `includes`               | Convenient traversal; eager loading is a one-word opt-in ([`associations.rb`][associations])           | The [N+1][nplusone] default is a silent performance foot-gun                                                                     |
| Blocking, per-thread connection pool; exceptions for errors      | Simple mental model; rides Ruby threads + Rails request cycle                                          | No effect value / typed error channel; async is a bolt-on (`load_async`)                                                         |
| Migrations (code DSL) + `schema_migrations` + dumped `schema.rb` | Versioned, reviewable, reversible DDL in Ruby; schema tracked in VCS ([`migration.rb`][migration])     | No typed db-first codegen; models still introspect the live schema, coupling code to DB shape                                    |

---

## Sources

- [rails/rails — GitHub repository][repo] (the `activerecord/` sub-directory) · [api.rubyonrails.org][api] · [Active Record Basics guide][guide]
- [`activerecord/README.rdoc` — zero-config positioning, the Fowler quote, convention-over-configuration, "Admit the Database", adapters, migration/association/transaction examples][readme]
- [`lib/active_record.rb` — the module doc is `# :include: ../README.rdoc`][armod] · [`lib/active_record/base.rb` — attributes inferred from the table; the `authenticate_unsafely`/`authenticate_safely` injection example; the `Base` mixin list][base]
- [`lib/active_record/persistence.rb` — `save`/`create`/`update`/`destroy`, `new_record?`/`persisted?`, `instantiate` (new object per row)][persistence]
- [`lib/active_record/querying.rb` — `QUERYING_METHODS` + `delegate(*, to: :all)`; `find_by_sql` raw escape hatch + injection warning][querying]
- [`lib/active_record/scoping/named.rb` — `all` returns a `Relation`; lazy "fires on `each`/`size`"][named] · [`lib/active_record/relation.rb` — `Relation`, `load`, `load_async`][relation]
- [`lib/active_record/relation/query_methods.rb` — `where` forms + injection notes; `includes` (N+1); `eager_load`/`preload`][querymethods] · [`lib/active_record/relation/predicate_builder.rb` — hash form → `QueryAttribute` bind param][predicate]
- [`lib/active_record/sanitization.rb` — `sanitize_sql_*`, `replace_bind_variables` → adapter `quote`, the `Arel.sql()` "dangerous method" guard][sanitization]
- [`lib/active_record/associations.rb` — association macros; "accesses associations lazily"; the "dreaded N+1 problem" eager-loading doc][associations]
- [`lib/active_record/attribute_methods/dirty.rb` — `changed?`/`changes_to_save`/`saved_change_to_*`; `partial_updates`/`partial_inserts` default `true`][dirty]
- [`lib/active_record/migration.rb` — migration DSL, transformations, `schema_migrations` + `db/schema.rb` dump][migration] · [`lib/active_record/callbacks.rb` — the 19-callback lifecycle sequence][callbacks]
- [`lib/active_record/transactions.rb` — `transaction` block, `Rollback`, nested `requires_new: true` savepoints, auto-wrapped `save`/`destroy`][transactions]
- [`lib/active_record/connection_adapters/abstract/connection_pool.rb` — per-thread checkout/checkin pool][pool_rb] · [`lib/active_record/connection_adapters.rb` — adapter registry][adapters]
- [`activerecord/MIT-LICENSE`][license] · [`activerecord.gemspec` — "Object-relational mapper framework", MIT, Ruby ≥ 3.3.1][gemspec] · [`lib/active_record/gem_version.rb` — `8.2.0.alpha`][gemver]
- Shared vocabulary: [SQL & ORM concepts][concepts] ([abstraction ladder][ladder] · [query models][qcm] · [injection][inject] · [ORM patterns][orm] · [N+1][nplusone] · [effects & transactions][effects] · [pools][pool])
- Related deep-dives in this survey: `Ecto` · `Django ORM` · `GORM` · `Hibernate` · `EF Core` · `SQLAlchemy` · `Prisma`

<!-- References -->

[repo]: https://github.com/rails/rails/tree/f956777962d286cc5c9aa8a3ae25ee7eaadaf43a/activerecord
[api]: https://api.rubyonrails.org/classes/ActiveRecord/Base.html
[guide]: https://guides.rubyonrails.org/active_record_basics.html
[readme]: https://github.com/rails/rails/blob/f956777962d286cc5c9aa8a3ae25ee7eaadaf43a/activerecord/README.rdoc
[armod]: https://github.com/rails/rails/blob/f956777962d286cc5c9aa8a3ae25ee7eaadaf43a/activerecord/lib/active_record.rb
[base]: https://github.com/rails/rails/blob/f956777962d286cc5c9aa8a3ae25ee7eaadaf43a/activerecord/lib/active_record/base.rb
[persistence]: https://github.com/rails/rails/blob/f956777962d286cc5c9aa8a3ae25ee7eaadaf43a/activerecord/lib/active_record/persistence.rb
[querying]: https://github.com/rails/rails/blob/f956777962d286cc5c9aa8a3ae25ee7eaadaf43a/activerecord/lib/active_record/querying.rb
[named]: https://github.com/rails/rails/blob/f956777962d286cc5c9aa8a3ae25ee7eaadaf43a/activerecord/lib/active_record/scoping/named.rb
[relation]: https://github.com/rails/rails/blob/f956777962d286cc5c9aa8a3ae25ee7eaadaf43a/activerecord/lib/active_record/relation.rb
[querymethods]: https://github.com/rails/rails/blob/f956777962d286cc5c9aa8a3ae25ee7eaadaf43a/activerecord/lib/active_record/relation/query_methods.rb
[predicate]: https://github.com/rails/rails/blob/f956777962d286cc5c9aa8a3ae25ee7eaadaf43a/activerecord/lib/active_record/relation/predicate_builder.rb
[sanitization]: https://github.com/rails/rails/blob/f956777962d286cc5c9aa8a3ae25ee7eaadaf43a/activerecord/lib/active_record/sanitization.rb
[associations]: https://github.com/rails/rails/blob/f956777962d286cc5c9aa8a3ae25ee7eaadaf43a/activerecord/lib/active_record/associations.rb
[dirty]: https://github.com/rails/rails/blob/f956777962d286cc5c9aa8a3ae25ee7eaadaf43a/activerecord/lib/active_record/attribute_methods/dirty.rb
[migration]: https://github.com/rails/rails/blob/f956777962d286cc5c9aa8a3ae25ee7eaadaf43a/activerecord/lib/active_record/migration.rb
[callbacks]: https://github.com/rails/rails/blob/f956777962d286cc5c9aa8a3ae25ee7eaadaf43a/activerecord/lib/active_record/callbacks.rb
[transactions]: https://github.com/rails/rails/blob/f956777962d286cc5c9aa8a3ae25ee7eaadaf43a/activerecord/lib/active_record/transactions.rb
[pool_rb]: https://github.com/rails/rails/blob/f956777962d286cc5c9aa8a3ae25ee7eaadaf43a/activerecord/lib/active_record/connection_adapters/abstract/connection_pool.rb
[adapters]: https://github.com/rails/rails/blob/f956777962d286cc5c9aa8a3ae25ee7eaadaf43a/activerecord/lib/active_record/connection_adapters.rb
[license]: https://github.com/rails/rails/blob/f956777962d286cc5c9aa8a3ae25ee7eaadaf43a/activerecord/MIT-LICENSE
[gemspec]: https://github.com/rails/rails/blob/f956777962d286cc5c9aa8a3ae25ee7eaadaf43a/activerecord/activerecord.gemspec
[gemver]: https://github.com/rails/rails/blob/f956777962d286cc5c9aa8a3ae25ee7eaadaf43a/activerecord/lib/active_record/gem_version.rb
[concepts]: ./concepts.md
[ladder]: ./concepts.md#the-abstraction-ladder
[qcm]: ./concepts.md#query-construction-models
[inject]: ./concepts.md#statements-parameters-and-sql-injection
[orm]: ./concepts.md#orm-patterns
[nplusone]: ./concepts.md#loading-strategies-and-the-n1-problem
[effects]: ./concepts.md#effects-transactions-and-error-handling
[pool]: ./concepts.md#connections-pools-and-sessions
