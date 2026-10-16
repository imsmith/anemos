# 8. Datasets, queries, and facts

Payloads are convenient for values that arrive with an event. Reusable
reference data belongs in a dataset. Computed lookups belong in a query.
Subject–predicate–object facts belong in the triple store. Each has a
different access model; this chapter keeps those models explicit.

## A named dataset

```anemos
data allowed_users {
  alice
  bob
  "Grace Hopper"
}

rule check-user {
  when LOGIN {
    if ?user memberof(allowed_users) {
      log "Allowed"
    } else {
      log "Denied"
    }
  }
}
```

The simple data block creates a set. Duplicate entries collapse. Membership
is exact; there is no case folding or substring matching. Quoted strings can
contain spaces. The simple-list parser represents numeric entries as strings,
so an entry `42` matches host `"42"`, not integer `42`.

`memberof(first, second)` tests the union of named datasets. A value need be
in only one. A referenced dataset that was never registered is an error,
`anemos.runtime/unknown_dataset`, rather than an empty set. This matters for
policies whose decisions depend on successful data loading.

Bare address/CIDR entries are accepted, but membership remains exact. A set
containing `192.0.2.0/24` does not automatically contain `192.0.2.7`. Supply
a host network-membership verb if you need subnet semantics.

## Scope and name resolution

A top-level data block is global within this runtime. A data block directly
inside a rule or its context wrapper is local to that named rule:

```anemos
rule restricted-login {
  data allowed_users {
    alice
  }
  when LOGIN {
    if ?user memberof(allowed_users) {
      log "Local member"
    }
    log ?allowed_users
  }
}
```

Another rule cannot read this local block. A local definition wins over a
global definition of the same name when looked up from its rule. Inside a
rule, `data global allowed_users { ... }` explicitly installs global data.
Queries use the same local/global convention.

These declarations are extracted and registered when the policy loads.
Putting a data declaration inside a runtime branch does not make it
conditional data creation. Keep declarations directly in the rule body or
context wrapper, where extraction is supported.

`?allowed_users` reads the visible stored dataset if context data and a query
of that name do not take precedence. A simple list dataset is a host
`MapSet`, not necessarily a list suitable for a `for` loop. Have a host
module return a list when enumeration is needed.

## Structured data belongs to a handler

Anemos supplies a plug-in boundary for formats. It does not bundle parsers
for every format named in design sketches. The host registers a handler
implementing `Anemos.DataModel`:

```elixir
Anemos.Runtime.register_data_model(:anemos, MyApp.Words)
```

After registration, its keyword can appear in a format block:

```anemos
data crew {
  words { alice bob }
}

rule check-crew {
  when LOGIN {
    if ?user memberof(crew) { log "Crew member" }
  }
}
```

This policy requires a host handler registered under `"words"`. The runtime
asks the handler to parse the block body, evaluate the parsed representation,
and optionally transform it. A missing or failed handler makes the data
declaration inert and appears in the load's partial failures.

Format and query engine bodies are reconstructed from DSL tokens, not passed
through as arbitrary byte-for-byte source. Whitespace, comments, and quoting
can change. Do not assume an arbitrary JSON, SQL, XML, or EDN document can be
pasted unchanged merely because you registered a handler with that name.
The handler must accept the representation Anemos delivers. Chapter 9 supplies
a complete deliberately simple handler.

An optional `source resource.path` records provenance metadata. It is not an
automatic fetch. A `transclude` clause requests a handler transformation:

```anemos
data crew {
  words { alice bob }
  transclude to shape(resource.schema.crew)
    with resource.transducer.upcase as loud_crew
}
```

The original dataset remains `crew`; the transformed result is registered
as `loud_crew`. The language keyword is `transclude`; the handler callback is
`transduce/3`. A handler must explicitly implement the requested transformation.

## Queries name a computation

```anemos
query greet {
  expect :name
  greeter { hello }
  return ?line
}

rule welcome {
  when ARRIVAL {
    let name = ?visitor
    log ?greet
  }
}
```

The host must register a `greeter` data-model handler. Reading `?greet`
executes the query. For each `expect` name, Anemos looks for a local `let`,
then a persistent `set`, then event/context data, using string keys. Several
expectations are comma-separated: `expect :name, :tenant`.

The engine's evaluated result must be a map binding the returned name, here
`"line"`. That field becomes the value of `?greet`. Reading the query again
executes it again; it is not an automatic cache. Missing input, missing engine,
failed evaluation, and missing return binding are errors that abort the
calling handler's evaluation.

Queries do not make arbitrary dataset or condition names into query engines.
The engine keyword identifies registered host code, and its syntax and answer
shape are part of that host's contract. Event data called `greet` shadows
this query, so avoid colliding field names.

## Live datasets

A dynamic data block subscribes through a host-supplied protocol adapter:

```anemos
data live_users {
  dynamic {
    subscribe directory "directory://users"
  }
}
```

`directory` is a registered protocol string, not a built-in network service.
An adapter implements `Anemos.Subscribable`; the dispatcher API registers it:

```elixir
Anemos.Runtime.Dispatcher.register_subscribable(
  :"anemos.dispatcher", "directory", MyApp.DirectoryFeed)
```

The dataset starts empty after a successful subscription. Each pushed value
replaces it; a pushed list is converted to a set. Updates do not automatically
dispatch a policy event. If reacting immediately to changes matters, arrange
for your adapter/application to dispatch one as well.

The syntax also accepts `periodic <spec>`, but the current dispatcher does not
implement a general polling loop from that clause. Let the adapter own polling
and lifecycle. A missing protocol handler is reported as a partial load
failure. Unloading the owning policy cancels its live subscriptions.

## Facts and triple patterns

Anemos can accumulate triples: a subject, predicate, and object.

```anemos
rule record-facts {
  when SETUP {
    let [:alice -> :worksOn -> :project1]
    let [:bob -> :worksOn -> :project1]
    graph :alice
  }
}
```

`let [subject -> predicate -> object]` asserts a fact. It is a special
statement, not an ordinary named binding. Duplicate assertions do not create
duplicate facts. `graph :alice` inspects facts involving that identifier.
The triple store is shared within the runtime; context does not create
independent named graphs or access isolation for facts.

The parser also accepts query patterns such as:

```text
[?person :worksOn ?project]
[:alice :worksOn :project1]
```

Here `?person` and `?project` are pattern variables, not ordinary payload
lookups. However, ordinary DSL value evaluation currently produces a query
descriptor rather than a bound result collection. `log [?person :worksOn
?project]` logs the descriptor; it does not bind `?person` for subsequent
statements. Standalone triple AST statements are not a complete query path
either. Use `graph` for policy-level inspection or a host query/module for
programmatic fact matching. The lower-level `TripleStore.match/4` API returns
binding maps and can support such a host implementation.

Do not base a policy decision on a triple descriptor's truthiness: a map is
truthy even if the intended query would match no facts. The reference records
this as a partial feature rather than promising a full fact-query language.

[Next: Embedding and extending Anemos](09-embedding.md) · [Contents](README.md)
