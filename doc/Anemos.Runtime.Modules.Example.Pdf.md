# `Anemos.Runtime.Modules.Example.Pdf`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/runtime/modules/example.ex#L69)

`PDF` double distinguishing document content from stored metadata.

`normalize-pdfs.rule` exists to demonstrate that the two can disagree,
so this double keeps them in separate keys: `title` is the title the
document *content* implies (defaulting to a human-readable form of the
filename), while `metadata title` is what is *recorded*. Supply
`--context-data meta_title=...` to make them differ and drive the
example's inner branch.

# `__anemos_name__`

Returns the module name as registered in Anemos (e.g., `"SECRET"`).

# `__anemos_verbs__`

Returns the list of verb names this module handles.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
