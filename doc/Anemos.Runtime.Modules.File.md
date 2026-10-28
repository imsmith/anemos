# `Anemos.Runtime.Modules.File`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/runtime/modules/file.ex#L1)

Stub FILE module for development and testing.

All verbs echo back their inputs as `%{module: "FILE", verb: verb, args: args}`.
Replace with a real implementation for production use.

## Before you make this real

The schemas below bound *shape* — the argument is a string, and it is not
a megabyte long. That is all a stub can honestly claim, because a stub
touches no filesystem.

A real implementation must add `path: :some_root` to every path-taking
verb and configure the root:

    config :anemos, :path_roots, %{files: "/var/lib/anemos/files"}

    def arg_schema("read"), do: [[type: :string, max_bytes: 4096, path: :files]]

Without it, `[FILE::read "../../etc/shadow"]` is a working traversal the
moment this module calls `File.read/1` — the host repo layer this would
sit on does no normalization and no confinement of its own (A-11, C-4).
`Anemos.Runtime.PathGuard` is the check; the schema is how you ask the
dispatcher to apply it for you.

# `__anemos_name__`

Returns the module name as registered in Anemos (e.g., `"SECRET"`).

# `__anemos_verbs__`

Returns the list of verb names this module handles.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
