# `Anemos.Runtime.Modules.Example`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/runtime/modules/example.ex#L1)

Demonstration doubles for the module verbs used by `priv/examples/`.

These exist for one reason: the shipped examples referenced `PDF`,
`STRING`, `INFRA`, `SECRET` and `EVENT`, nothing registered them, and so
two of the three examples could not run at all. They are doubles, not
implementations — every verb here computes from its arguments and from
the `:context_data` the caller supplied, and none of them opens a file,
a socket, or a keystore.

They are **not** registered by default. `Anemos.example_modules/0`
returns them and `mix anemos.run --stub-modules` opts into them, because
a `SECRET` handler that answers plausibly is precisely the thing that
should never be ambient. `Example.Secret.unlock/2` therefore returns a
self-identifying marker rather than anything secret-shaped: a rule that
depends on real key material will visibly get a stub, not a value it can
mistake for one.

## Supplying inputs

Read verbs resolve against `:context_data` — the same map `?var` reads —
so an example is driven entirely from the command line:

    mix anemos.run priv/examples/normalize-pdfs.rule \
      --event FILE_CREATED --context /papers --stub-modules \
      --context-data file=/papers/Draft_Report.pdf

Write verbs echo the operation they *would* perform, as the shipped
`DEVICE` and `FILE` stubs already do. An echo is the honest answer for a
double: it reports the decision the rule reached without pretending the
effect happened.

# `datum`

```elixir
@spec datum(map(), String.t(), term()) :: term()
```

Reads one key from the dispatch context's `:context_data`, or `default`.

## Examples

    iex> Anemos.Runtime.Modules.Example.datum(%{context_data: %{"file" => "a.pdf"}}, "file", "")
    "a.pdf"

    iex> Anemos.Runtime.Modules.Example.datum(%{}, "file", "none")
    "none"

---

*Consult [api-reference.md](api-reference.md) for complete listing*
