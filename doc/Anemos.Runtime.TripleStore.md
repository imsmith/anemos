# `Anemos.Runtime.TripleStore`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/runtime/triple_store.ex#L1)

Agent-based triple store for RDF-like facts.

Stores `{subject, predicate, object}` triples and supports
pattern matching with query variables (`?` bindings).

## Asserting facts

    TripleStore.assert(store, "p001", "knows", "p002")

## Querying facts

    TripleStore.query(store, :_, "knows", :_)
    # => [{"p001", "knows", "p002"}]

    TripleStore.match(store, :_, "worksOn", :_)
    # => [%{"?a" => "p001", "?p" => "proj1"}, ...]

Use `:_` as a wildcard in queries.

## Storage and result order

Triples are held in a `MapSet`. Assertion is a set insert, so building n
distinct triples costs O(n log n) rather than the O(n²) the previous
list-plus-`in`-check cost: every `assert_triple/4` used to scan the whole
store before prepending.

The consequence is that **result order is unspecified**. The list
implementation happened to return triples in reverse insertion order, and
nothing in the runtime relied on it — `query/4` results are returned to a
policy as an opaque result set and `match/4` results as unordered
bindings. Callers that need a stable order must sort.

## Retention

The store is still unbounded: nothing evicts. `retract_triple/4` exists as
a store primitive but no DSL verb reaches it, so a policy asserting one
triple per event grows the store without limit. Choosing a retention
policy is a language decision, not a storage one — see the report on A-23.

# `assert_triple`

```elixir
@spec assert_triple(pid() | atom(), term(), term(), term()) :: :ok
```

Asserts a triple (fact) into the store.

Idempotent: asserting the same triple twice leaves one fact.

# `child_spec`

Returns a specification to start this module under a supervisor.

See `Supervisor`.

# `match`

```elixir
@spec match(pid() | atom(), term(), term(), term()) :: [map()]
```

Matches triples against a pattern with named bindings.

Takes a pattern as `{subject, predicate, object}` where each element is
either a literal value (matches exactly) or a `{:var, name}` tuple
(binds the matched value to that name).

Returns a list of binding maps in unspecified order — sort if you need
a stable one, as this example does.

## Examples

    iex> {:ok, store} = Anemos.Runtime.TripleStore.start_link()
    iex> Anemos.Runtime.TripleStore.assert_triple(store, "p001", "worksOn", "proj1")
    iex> Anemos.Runtime.TripleStore.assert_triple(store, "p002", "worksOn", "proj1")
    iex> store |> Anemos.Runtime.TripleStore.match({:var, "a"}, "worksOn", {:var, "p"}) |> Enum.sort()
    [%{"a" => "p001", "p" => "proj1"}, %{"a" => "p002", "p" => "proj1"}]

# `query`

```elixir
@spec query(pid() | atom(), term(), term(), term()) :: [{term(), term(), term()}]
```

Queries the store for triples matching a pattern.

Use `:_` as a wildcard for any position. Returns matching triples in
unspecified order.

## Examples

    iex> {:ok, store} = Anemos.Runtime.TripleStore.start_link()
    iex> Anemos.Runtime.TripleStore.assert_triple(store, "p001", "knows", "p002")
    iex> Anemos.Runtime.TripleStore.query(store, "p001", "knows", :_)
    [{"p001", "knows", "p002"}]

    iex> {:ok, store} = Anemos.Runtime.TripleStore.start_link()
    iex> Anemos.Runtime.TripleStore.query(store, :_, :_, :_)
    []

# `retract_triple`

```elixir
@spec retract_triple(pid() | atom(), term(), term(), term()) :: :ok
```

Retracts a triple from the store.

Retracting a triple that was never asserted is not an error. No DSL verb
reaches this yet; it is the storage primitive an explicit `retract` would
be built on.

# `size`

```elixir
@spec size(pid() | atom()) :: non_neg_integer()
```

Returns the number of distinct triples held.

# `start_link`

Starts a triple store.

## Options

  * `:name` — process registration name (optional)

---

*Consult [api-reference.md](api-reference.md) for complete listing*
