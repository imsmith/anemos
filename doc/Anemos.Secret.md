# `Anemos.Secret`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/secret.ex#L1)

A wrapper for secret-bearing values that refuses to disclose itself.

Anemos routes module results into logs, envelopes, channel connectors and
error messages. Any of those paths will happily stringify whatever a host
module returned. A value wrapped in `Anemos.Secret` renders as
`#Anemos.Secret<redacted>` through `inspect/1`, `"#{}"` interpolation,
`to_string/1`, `to_charlist/1` and therefore `Logger` — there is exactly one
way to recover the plaintext, `expose/1`, and it is greppable.

Note: unrelated to `Comn.Secret`, which is a serialization protocol for
encrypting blobs. This struct is a disclosure control, not a crypto type.

## For host module authors

A verb that returns a credential should wrap it:

    defmodule MyApp.Anemos.Secret do
      use Anemos.Module, name: "SECRET"

      @impl true
      def handle_verb("unlock", [key_id], _context) do
        {:ok, Anemos.Secret.new(fetch_key(key_id), label: key_id)}
      end
    end

The wrapper then survives its trip through the runtime — emit, envelope,
channel connector, log line — without the plaintext appearing anywhere.
Whatever finally consumes it (an HTTP client, a config writer) calls
`expose/1` at the last possible moment.

Wrapping is opt-in: nothing in the runtime wraps values on your behalf,
because nothing in the runtime knows which values are sensitive.

## Label

The optional `:label` is rendered in place of the value, so it must be a
non-sensitive identifier ("ddns-key", "operator-did"), never the secret or
anything derived from it.

## What this does not protect against

`expose/1`, `Map.get(s, :__secret__)`, `inspect(s, structs: false)`,
`:erlang.term_to_binary/1` and a process-heap dump all still see the
plaintext. Each of those is an explicit request for the raw term —
`structs: false` in particular asks Elixir to bypass every `Inspect` impl in
the language, and no struct can defend against it. This type stops
accidental disclosure through ordinary formatting, which is how secrets
actually escape. It is not a sealed enclave.

# `t`

```elixir
@type t() :: %Anemos.Secret{__secret__: term(), label: String.t() | nil}
```

# `expose`

```elixir
@spec expose(t() | term()) :: term()
```

Recovers the plaintext. The only disclosure path — call it as late as possible.

Non-secret values pass through unchanged, so callers can unwrap
unconditionally.

## Examples

    iex> Anemos.Secret.expose(Anemos.Secret.new("hunter2"))
    "hunter2"

    iex> Anemos.Secret.expose("plain")
    "plain"

# `map`

```elixir
@spec map(t(), (term() -&gt; term())) :: t()
```

Applies `fun` to the plaintext and re-wraps the result, preserving the label.

Use this for derivations (encoding, signing) that must stay secret rather
than exposing and re-wrapping by hand.

## Examples

    iex> Anemos.Secret.new("abc") |> Anemos.Secret.map(&String.upcase/1) |> Anemos.Secret.expose()
    "ABC"

# `new`

```elixir
@spec new(term(), keyword()) :: t()
```

Wraps `value` so it cannot be disclosed by formatting.

Wrapping an existing `Anemos.Secret` returns it unchanged, so `new/1` is
safe to apply defensively.

## Options

  * `:label` — non-sensitive identifier shown in place of the value

## Examples

    iex> inspect(Anemos.Secret.new("hunter2"))
    "#Anemos.Secret<redacted>"

    iex> inspect(Anemos.Secret.new("hunter2", label: "ddns-key"))
    "#Anemos.Secret<redacted ddns-key>"

# `secret?`

```elixir
@spec secret?(term()) :: boolean()
```

Returns true if `term` is a wrapped secret.

## Examples

    iex> Anemos.Secret.secret?(Anemos.Secret.new("x"))
    true

    iex> Anemos.Secret.secret?("x")
    false

---

*Consult [api-reference.md](api-reference.md) for complete listing*
