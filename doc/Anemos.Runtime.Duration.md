# `Anemos.Runtime.Duration`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/runtime/duration.ex#L1)

Converts duration tuples (e.g., `{5, :min}`) to milliseconds.

Supported units: `:ms`, `:s`, `:seconds`, `:min`, `:minutes`,
`:h`, `:hours`, `:d`, `:days`.

`to_ms/1` never raises: an unrecognised unit or a malformed term yields an
error tuple. This matters because callers run inside long-lived processes —
a `FunctionClauseError` here would take the scheduler down rather than
reject one bad schedule. Use `to_ms!/1` where a bad unit should abort the
caller instead (compile time, say).

# `to_ms`

```elixir
@spec to_ms(term()) :: non_neg_integer() | {:error, Comn.Errors.ErrorStruct.t()}
```

Converts a duration tuple to milliseconds.

Returns the millisecond count, or `{:error, %Comn.Errors.ErrorStruct{}}` with
code `anemos.duration/unknown_unit` for an unrecognised unit, or
`anemos.duration/invalid` for anything that is not a `{amount, unit}` pair.

## Examples

    iex> Anemos.Runtime.Duration.to_ms({5, :min})
    300_000

    iex> Anemos.Runtime.Duration.to_ms({2, :s})
    2_000

    iex> {:error, %Comn.Errors.ErrorStruct{code: code}} = Anemos.Runtime.Duration.to_ms({2, :fortnights})
    iex> code
    "anemos.duration/unknown_unit"

# `to_ms!`

```elixir
@spec to_ms!(term()) :: non_neg_integer()
```

Converts a duration tuple to milliseconds, raising on anything unrecognised.

## Examples

    iex> Anemos.Runtime.Duration.to_ms!({5, :min})
    300_000

---

*Consult [api-reference.md](api-reference.md) for complete listing*
