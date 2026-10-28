# `Anemos.Runtime.LoadRequest`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/runtime/load_authority.ex#L1)

Everything an `Anemos.Runtime.LoadAuthority` gets to decide on.

Deliberately a closed struct rather than a bare map: an authority is a
security decision point, and a decision point that pattern-matches on a
map is one field rename away from matching nothing and — depending on how
it was written — failing open.

`signers` is the seam for A-05, and it is now filled: an authority
implementation checks these names against a keyring, and neither this
struct nor `Anemos.Runtime.load/3` had to change to let it. See
`Anemos.Runtime.LoadAuthority.Signed`.

# `t`

```elixir
@type t() :: %Anemos.Runtime.LoadRequest{
  authorization: term(),
  byte_size: non_neg_integer(),
  policy: String.t() | nil,
  runtime: atom(),
  signers: [atom() | String.t()],
  source: String.t()
}
```

---

*Consult [api-reference.md](api-reference.md) for complete listing*
