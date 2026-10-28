# `Anemos.AST.SignedBy`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/ast.ex#L16)

A source-level `signed_by` declaration (A-60).

A detached signature covers the whole source, so provenance is a property
of the file rather than of any one declaration in it. This is the placement
that says so, and the only one under which a source carrying no `rule` —
conditions, capabilities, data blocks — can make a provenance claim at all.

# `t`

```elixir
@type t() :: %Anemos.AST.SignedBy{
  line: non_neg_integer() | nil,
  signer: String.t() | nil
}
```

---

*Consult [api-reference.md](api-reference.md) for complete listing*
