# Used by "mix format"
[
  inputs: [
    "{mix,.formatter}.exs",
    "{config,lib,test}/**/*.{ex,exs}",
    "docs/manual/examples/*.exs"
  ],

  # `verb/2` is Anemos.Module's DSL macro (lib/anemos/module.ex:64). Without this
  # the formatter adds parens to every `verb :name, fn ... end` declaration in
  # lib/anemos/runtime/modules/ and in the module tests.
  locals_without_parens: [verb: 2]
]
