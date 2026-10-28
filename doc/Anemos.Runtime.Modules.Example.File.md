# `Anemos.Runtime.Modules.Example.File`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/runtime/modules/example.ex#L35)

`FILE` double that answers `extension` from the path under evaluation.

Overrides `Anemos.Runtime.Modules.File`, which echoes every verb. That
echo is what made `normalize-pdfs.rule`'s outer guard
(`if [FILE::extension] eq "pdf"`) permanently false: a map never equals
`"pdf"`. Here `extension` is real string computation over a path taken
from the argument list or, when called with no arguments, from
`context_data["file"]`.

# `__anemos_name__`

Returns the module name as registered in Anemos (e.g., `"SECRET"`).

# `__anemos_verbs__`

Returns the list of verb names this module handles.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
