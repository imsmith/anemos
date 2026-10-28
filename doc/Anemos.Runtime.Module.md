# `Anemos.Runtime.Module`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/runtime/module.ex#L1)

Behaviour for Anemos runtime modules (DEVICE, FILE, etc.).

Each module handles verbs dispatched from compiled rule operations.

## Argument validation

`arg_schema/1` is optional. A module that implements it declares, per
verb, what shape of argument list it is willing to receive; the
dispatcher enforces that declaration *before* `handle_verb/3` is called,
so a malformed or hostile argument never reaches host code. Returning
`nil` for a verb — or not implementing the callback at all — leaves that
verb unvalidated, which is what keeps modules written before A-11 working
unchanged.

The check lives in the framework rather than in each module on purpose:
arguments come from untrusted policy text and untrusted event payloads,
and a boundary that every host module author has to remember to build for
themselves is a boundary that will be missing somewhere.

See `Anemos.Runtime.ArgSchema` for the schema vocabulary, and
`Anemos.Runtime.PathGuard` for confining a path-taking verb to a root.

    # in a module implementing this behaviour
    @impl true
    def arg_schema("read"), do: [[type: :string, path: :spool]]
    def arg_schema(_verb), do: nil

    @impl true
    def handle_verb("read", [path], _context), do: File.read(path)

# `verb_result`

```elixir
@type verb_result() :: {:ok, any()} | {:error, any()}
```

What a verb answers: a host value, or a reason the verb refused.

# `arg_schema`
*optional* 

```elixir
@callback arg_schema(verb :: String.t()) :: Anemos.Runtime.ArgSchema.t()
```

Returns the argument schema for `verb`, or `nil` to leave it unvalidated.

# `describe`
*optional* 

```elixir
@callback describe(name :: String.t()) :: %{
  look: String.t(),
  recon: map(),
  choices: map()
}
```

What a policy learns from `show NAME`, `explain NAME` and `list NAME`:
`%{look: String.t(), recon: map(), choices: map()}`, Comn's three
questions. For a module bound under several names — a bridge that serves
every discovered tool — this answers per name, which Comn's own
nullary callbacks cannot.

# `handle_verb`

```elixir
@callback handle_verb(verb :: String.t(), args :: list(), context :: map()) ::
  verb_result()
```

Executes `verb` with `args` already validated against `arg_schema/1`.

# `card`

```elixir
@spec card(module(), String.t()) :: %{look: String.t(), recon: map(), choices: map()}
```

A module's card for the name it is bound under: `describe/1` if it has
one, else its `Comn` callbacks, else what the runtime knows — the name,
the Elixir module, and the verbs declared with `use Anemos.Module`.

The module's own code runs in a process of its own with a deadline
(1000 ms): it is host code, called from inside the dispatcher on a
policy's say-so, and a card that raises, blocks or comes back in the
wrong shape is a card the runtime did not get, not a dead dispatcher.

# `schema_for`

```elixir
@spec schema_for(module(), String.t()) :: Anemos.Runtime.ArgSchema.t()
```

Returns `module`'s schema for `verb`, or `nil` when it declares none.

Answers `nil` for a module that does not implement the optional callback,
which is the pre-A-11 behaviour and is why old modules keep working.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
