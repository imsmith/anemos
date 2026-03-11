# Anemos

Event-driven automation DSL. Elixir/OTP on BEAM.

## Structure
- `lib/anemos/lexer.ex` — NimbleParsec tokenizer
- `lib/anemos/parser.ex` — recursive descent parser, AST output
- `lib/anemos/ast.ex` — AST node structs
- `lib/anemos/compiler.ex` — AST → executable rule modules
- `lib/anemos/runtime/` — event dispatcher, module registry, rule supervisor
- `priv/examples/` — example .rule files from the spec

## Conventions
- AGPL-3.0
- Tests: TDD, happy path + error path
- AST nodes are plain structs, not protocol-heavy
- Parser errors include line/col position
