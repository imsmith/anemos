# `Anemos.Runtime.Modules.Example.String`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/runtime/modules/example.ex#L112)

`STRING` double. `slugify` is a genuine pure function, not a stand-in —
there is nothing to fake about lowercasing and hyphenating a string.

# `__anemos_name__`

Returns the module name as registered in Anemos (e.g., `"SECRET"`).

# `__anemos_verbs__`

Returns the list of verb names this module handles.

# `slugify`

Lowercases, strips anything that is not alphanumeric or a separator,
and collapses separators into single hyphens.

## Examples

    iex> Anemos.Runtime.Modules.Example.String.slugify(["Draft Report (v2)"])
    "draft-report-v2"

    iex> Anemos.Runtime.Modules.Example.String.slugify([])
    ""

---

*Consult [api-reference.md](api-reference.md) for complete listing*
