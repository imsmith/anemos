# `Anemos.Runtime.NLD`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/runtime/nld.ex#L1)

Natural Language Date resolver.

Resolves `NLD_<text>` expressions to `NaiveDateTime` values.
All times are system-local.

## Supported expressions

| Expression | Resolves to |
|-----------|-------------|
| `tomorrow` | Next day at 00:00:01 |
| `yesterday` | Previous day at 00:00:01 |
| `today` | Current day at 00:00:01 |
| `next.monday` .. `next.sunday` | Next occurrence of that day at 00:00:01 |
| `next.week` | Next monday at 00:00:01 |
| `next.month` | First of next month at 00:00:01 |
| `next.year` | January 1 of next year at 00:00:01 |
| `end.of.month` | Last day of current month at 23:59:59 |
| `end.of.week` | Next sunday at 23:59:59 |

## Examples

    iex> {:ok, dt} = Anemos.Runtime.NLD.resolve("today")
    iex> dt.hour
    0

    iex> {:error, %Comn.Errors.ErrorStruct{code: "anemos.nld/unknown_expression"}} =
    ...>   Anemos.Runtime.NLD.resolve("gobbledygook")

# `resolve`

```elixir
@spec resolve(String.t()) ::
  {:ok, NaiveDateTime.t()} | {:error, Comn.Errors.ErrorStruct.t()}
```

Resolves a natural language date expression to a `NaiveDateTime`.

Returns `{:ok, naive_datetime}` or an `anemos.nld/unknown_expression` error.

# `resolve_ms`

```elixir
@spec resolve_ms(String.t()) ::
  {:ok, non_neg_integer()} | {:error, Comn.Errors.ErrorStruct.t()}
```

Resolves a natural language date to milliseconds from now.

Returns `{:ok, milliseconds}` or an `anemos.nld/unknown_expression` error.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
