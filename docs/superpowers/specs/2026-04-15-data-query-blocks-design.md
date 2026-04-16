# Data Blocks & Query Blocks — Design Spec

## Overview

Data blocks and query blocks are new top-level declaration types (peers of `rule`, `condition`, `capability`) that bring external and inline data into the Anemos runtime. Data blocks hold data passively. Query blocks define parameterized lookups against data or external engines. Both can also appear inline within rules, lexically scoped to the enclosing rule.

Neither construct is captured in the current language specification — they emerged from practical examples in policy and knowledge-management use cases.

## Data Blocks

### Syntax

```
<data-decl>      ::= "data" ["global"] <identifier> "{" <data-body> "}"
<data-body>       ::= <source-stmt>? <data-content> <transclude-stmt>?
<source-stmt>     ::= "source" <dotted-identifier>
<data-content>    ::= <simple-list> | <format-block> | <dynamic-block>
<simple-list>     ::= ( <value> <comment>? )*
<format-block>    ::= <identifier> "{" <raw-content> "}"
<dynamic-block>   ::= "dynamic" "{" <subscribe-stmt> <periodic-stmt>? "}"
<subscribe-stmt>  ::= "subscribe" <identifier> <uri>
<periodic-stmt>   ::= "periodic" <identifier>
<transclude-stmt> ::= "transclude" "to" "shape(" <dotted-identifier> ")"
                      "with" <dotted-identifier> "as" <identifier>
```

### Five Content Shapes

1. **Simple list** — bare values, one per line, optional `//` comments. No format keyword. This is the default shape. The resulting dataset is a flat set of values.

2. **Structured inline** — data in a declared format (`edn {}`, `xml {}`, etc.). The format keyword is a registered identifier, not hardcoded. The content between braces is opaque to the Anemos parser — it is captured as raw text and handed to the registered format handler for parsing. The parser uses brace-depth counting to capture the raw content: it tracks nested `{`/`}` pairs and captures everything until the depth returns to zero. This allows format content that itself contains braces (EDN maps, code blocks, etc.) to be captured correctly.

3. **Dynamic subscription** — `dynamic { subscribe <protocol> <uri> }` with optional `periodic <interval>`. The protocol identifier is a registered subscribable handler. Subscription updates are silent — no events are emitted. The data block simply stays current.

4. **Import** — `sqlite { import /path/*.sql }` or `elixir { import /path/*.exs }`. A format block where the content is an import directive rather than inline data. The format handler resolves the import.

5. **Function/eval** — a format block containing executable code rather than data. Example: `elixir { :rand.uniform(100) }`. The format handler's `eval/2` callback executes the content and returns the result. The runtime distinguishes data-vs-code based on the handler's parsing of the content.

### source

Optional provenance metadata. A dotted identifier, URL, FQDN, coordinate, or any value that describes where the data came from. The runtime does not interpret it, but modules or transducers may inspect it and act on it if the value is actionable.

### transclude

Optional transformation directive. Maps the data into a target shape via a named transducer function and binds the result with `as`.

```
transclude to shape(resource.schema.knowledge#20250707) with resource.transducer.edn-to-kb as fact
```

- `to shape(...)` — the target schema/shape identifier
- `with <dotted-identifier>` — the transducer function
- `as <identifier>` — what the result is bound as in the program

Without `transclude`, the shape is "blobs in a list" and `memberof()` is the primary accessor.

### Scoping

- **Top-level** data blocks are globally scoped by default.
- **Inline** data blocks (inside a rule body) are lexically scoped to the enclosing rule. Local shadows global when names collide.
- **Scope escape:** `data global my-name { ... }` promotes an inline data block to global scope. The `global` keyword appears between `data` and the identifier.

### Dynamic Inline Warning

Dynamic data blocks inside rules are allowed but the compiler emits a warning:

```
warning: data block 'botnet-ips' is dynamic and inline-scoped to rule 'check-connections' —
subscription lifecycle is tied to rule process (will reconnect on rule restart)
```

The subscription tears down and re-establishes on every rule process restart. This is by design — some use cases want subscription only while the rule is active — but it has implications for push-based sources (data gaps during restarts, reconnection overhead, timer resets for periodic sources).

## Query Blocks

### Syntax

```
<query-decl>  ::= "query" ["global"] <identifier> "{" <query-body> "}"
<query-body>  ::= <expect-stmt>? <format-block> <return-stmt>
<expect-stmt> ::= "expect" <atom> ( "," <atom> )*
<return-stmt> ::= "return" <query-var>
```

### Semantics

- `expect` declares required input bindings as a list of atoms. The caller must provide all of them. Any number of atoms is valid (zero, one, many). Validated at compile time when possible, at runtime otherwise.
- The format block uses a registered engine keyword (same registration mechanism as data block formats). The query body is opaque to the Anemos parser.
- `return` declares which bound variable comes back to the calling scope.

### Scoping

Same rules as data blocks: top-level is global, inline is local to the enclosing rule, `query global name { ... }` escapes to global scope.

### Execution Model

Query blocks compile to functions, not long-lived processes:

1. Validate that all `expect` bindings are present in the caller's scope
2. Resolve the engine keyword against the DataModel registry
3. Call the engine handler's `parse/1` on the raw body (cacheable after first call)
4. Call the engine handler's `eval/2` with the parsed query and a context map containing current bindings and the DataStore pid
5. Extract the `return` binding from the result
6. Return the value to the calling scope

Top-level queries compile to a named function in a generated module. Inline queries compile to a closure in the rule's compiled handler that shares the rule's binding scope directly.

If `expect` bindings are missing at runtime, it is a runtime error through `Comn.Errors.Registry`. If the engine keyword is not registered, it is a compile-time error.

## DataModel Behaviour

Format/engine handlers implement the `Anemos.DataModel` behaviour. Same registration pattern as `Anemos.Module`.

```elixir
@callback keyword() :: String.t()
@callback parse(raw :: String.t()) :: {:ok, term()} | {:error, term()}
@callback eval(parsed :: term(), context :: map()) :: {:ok, term()} | {:error, term()}
@callback transduce(data :: term(), shape :: String.t(), transducer :: String.t()) ::
            {:ok, term()} | {:error, term()}
```

- `keyword/0` — the string that registers this handler (e.g., `"edn"`, `"xml"`, `"sql"`, `"wikidata"`)
- `parse/1` — takes raw content string, parses it in the handler's native format
- `eval/2` — evaluates the parsed content with context (bindings, DataStore pid). For static data, identity. For executable content or queries, runs the computation.
- `transduce/3` — applies the transclude transformation. Handlers that don't support it return `{:error, :not_supported}` and the compiler raises.

Registration: handlers `use Anemos.DataModel, keyword: "edn"` which injects callbacks and registers the keyword in `Anemos.Runtime.DataModelRegistry` at compile time.

## Subscribable Behaviour

Optional behaviour for handlers that support dynamic subscription. Separate from `Anemos.DataModel` — a handler may implement one or both.

```elixir
@callback subscribe(protocol :: String.t(), uri :: String.t(), callback :: fun()) ::
            {:ok, ref()} | {:error, term()}
@callback unsubscribe(ref()) :: :ok
@callback periodic?() :: boolean()
@callback interval(spec :: String.t()) :: pos_integer()
```

The protocol identifier in `subscribe <protocol> <uri>` is looked up in a separate subscribable registry. `periodic` is a sub-quality of subscribable — `periodic?/0` and `interval/1` are only called when the subscription spec includes a `periodic` directive.

## DataStore — Runtime Storage

`Anemos.Runtime.DataStore` is a GenServer that holds all data block entries and serves lookups. Mirrors the existing `Anemos.Runtime.TripleStore` pattern.

### State

```elixir
%{
  entries: %{
    {name, scope_tag} => %{
      dataset: term(),
      source: String.t() | nil,
      transcluded: term() | nil,
      subscription: ref() | nil
    }
  }
}
```

Where `scope_tag` is `:global` or `{:local, rule_pid}`.

### API

- `register(store, name, scope_tag, dataset, opts)` — insert or replace an entry
- `deregister(store, name, scope_tag)` — remove an entry
- `member?(store, name, value)` — the `memberof()` implementation. Checks `{name, {:local, self()}}` first, then `{name, :global}`. Returns boolean.
- `get(store, name)` — returns the full dataset for a named entry
- `update(store, name, scope_tag, dataset)` — called by subscription callbacks. Replaces the dataset silently, no events.

### Lifecycle

- Top-level data blocks register at startup when the runtime loads policies
- Inline data blocks register in the enclosing rule's `init/1`, deregister in `terminate/1`
- The DataStore monitors rule processes for cleanup of local entries on crash
- Dynamic entries: DataStore starts subscriptions on register, stops them on deregister

## memberof()

The primary accessor for data blocks.

- `memberof(name)` — true if the left-hand value is a member of the named dataset
- `memberof(name1, name2, ...)` — union check across multiple named datasets
- For simple list data: MapSet lookup, O(1)
- For structured/transcluded data: DataModel handlers can optionally implement `member?/2` to customize. Default falls back to `Enum.member?/2`.
- The compiler recognizes `memberof(...)` as a built-in and emits code that calls `DataStore.member?/3`
- The dispatcher passes the DataStore pid through the execution context (same pattern as TripleStore)
- `memberof()` is read-only. There is no write path from rules into data blocks.

## Compiler Integration

Two new top-level clause handlers: `compile_data/2` and `compile_query/2`.

### compile_data/2

1. `{:simple_list, values}` — build MapSet, register in DataStore
2. `{:format_block, keyword, raw}` — look up keyword in DataModelRegistry, call `handler.parse(raw)`, apply transclude if present, register result in DataStore
3. `{:dynamic, subscribe, periodic}` — look up protocol in Subscribable registry, register empty dataset, start subscription
4. If inline and dynamic — emit compiler warning

### compile_query/2

1. Validate engine keyword in DataModelRegistry
2. Pre-parse query body via `handler.parse(raw)` (fail fast on bad syntax)
3. Generate function module (top-level) or closure (inline)

### Inline Block Handling

When the compiler encounters `data` or `query` inside a rule body, it compiles data registration into the rule's `init/1` and query as a local closure. The rule's `terminate/1` gets `DataStore.deregister` calls for locally-scoped data entries.

### Scope Escape

`data global name { ... }` or `query global name { ... }` — the `global` keyword between the declaration keyword and the identifier compiles the block as if it were top-level, regardless of nesting.
