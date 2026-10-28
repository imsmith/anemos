# `Anemos.AST.DataDecl`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/ast.ex#L322)

A named data declaration with content, optional source/transclude, scope, and source line.

# `t`

```elixir
@type t() :: %Anemos.AST.DataDecl{
  content:
    {:simple_list, list()}
    | {:format_block, String.t(), String.t()}
    | {:dynamic, tuple(), String.t() | nil},
  line: non_neg_integer() | nil,
  name: String.t() | nil,
  scope: :local | :global,
  source: String.t() | nil,
  transclude: {:transclude, String.t(), String.t(), String.t()} | nil
}
```

---

*Consult [api-reference.md](api-reference.md) for complete listing*
