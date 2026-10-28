# `Anemos.DataModel`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/data_model.ex#L1)

Behaviour for pluggable data format and query engine handlers.

Implementations register a keyword (e.g., "edn", "xml", "sql")
that becomes valid inside data and query block bodies. The runtime
delegates parsing, evaluation, and transduction to the registered handler.

## `transclude` and `transduce` are not the same word

They are two halves of one feature and both spellings are deliberate:

  * `transclude` is the *language* construct — the optional clause in a data
    block, `transclude to shape(<shape>) with <transducer> as <binding>`. It
    survives as the `:transclude` field on `Anemos.AST.DataDecl` and
    `Anemos.CompiledData`, and as `:transcluded` (the computed result) on a
    `Anemos.Runtime.DataStore` entry.

  * `transduce/3` is the *handler operation* that carries the clause out. The
    runtime hands the parsed data plus the clause's shape and transducer to
    the handler; what comes back is the transcluded value.

So a data block declares a transclusion, and the handler performs a
transduction to satisfy it. Handlers with no transformation support return
`{:error, :not_supported}`.

# `eval`

```elixir
@callback eval(parsed :: map() | list() | String.t(), context :: map()) ::
  {:ok, map() | list() | String.t()} | {:error, :eval_failed}
```

Evaluates a parsed value against the dispatch context. Returns `{:ok, result}` or `{:error, :eval_failed}`.

# `keyword`

```elixir
@callback keyword() :: String.t()
```

Returns the keyword string identifying this data format (e.g., `"edn"`, `"xml"`).

# `parse`

```elixir
@callback parse(raw :: String.t()) ::
  {:ok, map() | list() | String.t()} | {:error, :parse_failed}
```

Parses a raw string body into an internal representation. Returns `{:ok, parsed}` or `{:error, :parse_failed}`.

# `transduce`

```elixir
@callback transduce(
  data :: map() | list() | String.t(),
  shape :: String.t(),
  transducer :: String.t()
) ::
  {:ok, map() | list() | String.t()}
  | {:error, :not_supported}
  | {:error, :transduce_failed}
```

Transduces data into a new shape. Returns `{:ok, result}`, `{:error, :not_supported}`, or `{:error, :transduce_failed}`.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
