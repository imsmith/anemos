# `Anemos.Runtime.ArgSchema`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/runtime/arg_schema.ex#L1)

Validates the arguments of a `[MODULE::verb ...]` command before they
reach a host module.

Arguments arrive from two untrusted places — policy literals and event
payloads — and used to be handed to `handle_verb/3` verbatim (A-11). This
module is the check, and the dispatcher is the only caller, so a host
module cannot be reached by a path that skipped it.

## The schema format, and why it is this small

A schema is a **list of positional argument specs**, one per argument.
Each spec is a keyword list drawn from a fixed five-key vocabulary:

  * `:type` — `:string`, `:integer`, `:float`, `:number`, `:boolean`,
    `:atom` or `:any` (default `:any`)
  * `:max_bytes` — upper bound on a string argument's byte size
  * `:in` — allow-list of permitted values
  * `:path` — the name of a root from `config :anemos, :path_roots`; the
    argument is confined to it by `Anemos.Runtime.PathGuard`
  * `:optional` — the argument may be absent (only meaningful on a
    trailing run of specs)

Plus one whole-schema form: a trailing spec carrying `rest: true` applies
to every remaining argument, for genuinely variadic verbs.

    def arg_schema("read"),  do: [[type: :string, path: :spool]]
    def arg_schema("set"),   do: [[type: :string, max_bytes: 128], [type: :any]]
    def arg_schema("mode"),  do: [[type: :string, in: ["on", "off"]]]
    def arg_schema("log"),   do: [[type: :string, max_bytes: 4096, rest: true]]
    def arg_schema(_verb),   do: nil

There is no nesting, no predicate function, no cross-argument
dependency and no custom error text. That is deliberate: the vocabulary
is exactly what an untrusted-input boundary needs — *is it the right
shape, is it bounded, is it one of the values I allow, and if it names a
file does it stay in its root* — and nothing beyond it. A schema
expressive enough to encode business rules would be a second policy
language inside the policy engine, and every key added to it is another
key a reviewer has to reason about when auditing whether a verb is safe.
Anything a host module needs past this vocabulary belongs in that host
module's own body, where it can return a domain error.

Arity is `length(schema)` less any trailing `optional: true` specs; a
`rest: true` tail makes the upper bound unlimited.

## Validation is normalizing for paths only

`validate/3` returns the argument list to pass onward. For every spec but
`:path` that list is the input unchanged. A `:path` argument is replaced
by its expanded, confined absolute path, because passing the original
string on would let the host module re-resolve it and undo the check.

## Messages never quote the value

A rejection names the position and the rule it broke, and describes the
offending value only through `Anemos.Redact.summarize/1`. The value is
attacker-controlled and the error text ends up in logs.

# `spec`

```elixir
@type spec() :: keyword()
```

One positional argument spec.

# `t`

```elixir
@type t() :: [spec()] | nil
```

A verb's argument schema, or `nil` for an unvalidated verb.

# `validate`

```elixir
@spec validate(t(), list(), String.t()) ::
  {:ok, list()} | {:error, Comn.Errors.ErrorStruct.t()}
```

Checks `args` against `schema`, returning the arguments to pass onward.

`nil` means the verb declared no schema and the arguments pass through
unchanged — that is what keeps existing modules working.

## Examples

    iex> Anemos.Runtime.ArgSchema.validate(nil, ["anything", 5], "v")
    {:ok, ["anything", 5]}

    iex> Anemos.Runtime.ArgSchema.validate([[type: :string]], ["ok"], "v")
    {:ok, ["ok"]}

    iex> {:error, error} = Anemos.Runtime.ArgSchema.validate([[type: :integer]], ["nope"], "v")
    iex> {error.code, error.message}
    {"anemos.runtime/invalid_argument", "verb 'v' argument 1: expected integer, got binary(4 bytes)"}

---

*Consult [api-reference.md](api-reference.md) for complete listing*
