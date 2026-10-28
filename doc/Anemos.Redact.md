# `Anemos.Redact`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/redact.ex#L1)

Shape summaries for values that must be observable without being disclosed.

Anemos emits are deliberately never silent, but "not silent" must not mean
"fully disclosed". `summarize/1` describes a term's type and size — enough
to see that an emit happened and roughly what it carried — while never
including the term's contents, keys, or any `Anemos.Secret` plaintext.

# `for_trace`

```elixir
@spec for_trace(term()) :: term()
```

A value as the trace may keep it: every `Anemos.Secret` replaced by
`"[REDACTED]"`, strings cut at 1000 bytes, lists and maps cut at
50 entries, nesting cut at depth 4, and anything that is none of
those described by `summarize/1`. The table the trace lives in is public
and the ring holds hundreds of entries; what goes in has to be safe to
read and small enough to keep.

# `summarize`

```elixir
@spec summarize(term()) :: String.t()
```

Describes a term by type and size, never by content.

## Examples

    iex> Anemos.Redact.summarize("hello")
    "binary(5 bytes)"

    iex> Anemos.Redact.summarize(%{a: 1, b: 2})
    "map(2 keys)"

    iex> Anemos.Redact.summarize(Anemos.Secret.new("hunter2"))
    "secret(redacted)"

---

*Consult [api-reference.md](api-reference.md) for complete listing*
