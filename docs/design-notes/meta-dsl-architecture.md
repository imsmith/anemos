# Meta-DSL Architecture — Pluggable Declaration Registry

## Problem

The Tcl design sketches (see `tcl-sketch-analysis.md`) use 8+ top-level declaration types across 6 different concerns, but they all share the same expression language, command syntax, sigils, control flow, and block structure. Building separate DSLs for each concern would duplicate the grammar core. A single project with a pluggable declaration registry gives one grammar, one runtime, multiple concerns.

## Architecture

Three layers:

### Layer 1: Core Grammar (shared, already built)

Everything that doesn't depend on what kind of declaration you're in:

- **Lexical structure** — sigils (`$`, `@`, `?`, `:`), identifiers, module IDs (`MODULE_ID`), strings, numbers, durations, operators
- **Expressions** — binary ops, comparisons, unary ops, command expressions (`[MODULE::verb args]`), variable references
- **Control flow** — `if`/`else`/`elseif`, `when`, `let`, `set`, `log`, `emit`, `demand`
- **Block structure** — `{ }` scoping, `context` paths
- **Pipelines** — `filter |> map |> reduce` (not yet implemented, highest-priority gap)

This is `Anemos.Lexer`, `Anemos.Parser` (expression/statement parsing), and `Anemos.Compiler` (expression evaluation) as they exist today.

### Layer 2: Declaration Registry (extensible)

The parser's `parse_declaration/1` currently hardcodes keyword dispatch:

```elixir
defp parse_declaration([{:keyword, _, :rule} | rest]), do: parse_rule(rest)
defp parse_declaration([{:keyword, _, :condition} | rest]), do: parse_condition_decl(rest)
```

Refactor to a registry:

```elixir
@declaration_parsers %{
  rule:       Anemos.Declarations.Rule,
  condition:  Anemos.Declarations.Condition,
  capability: Anemos.Declarations.Capability,
  policy:     Anemos.Declarations.Policy,
  data:       Anemos.Declarations.Data,
  # ...
}

defp parse_declaration([{:keyword, _, kw} | rest]) do
  case Map.get(@declaration_parsers, kw) do
    nil -> {:error, "Unknown declaration type: #{kw}"}
    mod -> mod.parse(rest)
  end
end
```

Each declaration module implements a behaviour:

```elixir
defmodule Anemos.Declaration do
  @callback parse(tokens :: list()) :: {:ok, ast_node, remaining_tokens} | {:error, String.t()}
  @callback compile(ast_node, context) :: {:ok, [compiled]} | {:error, String.t()}
end
```

Declaration families and their keywords:

| Family | Keywords | Concern |
|--------|----------|---------|
| Anemos (orchestration) | `rule`, `condition`, `capability`, `flow` | Event-driven automation |
| CommonRule (policy) | `policy`, `deny`, `permit` | Policy evaluation chains |
| DataDef | `data` | Static/dynamic data sources |
| Topology | `unit`, `node`, `link`, `service` | Infrastructure graphs |
| Query | `query` | Pattern matching against stores |
| Functions | `deffunc` | Reusable function definitions |

### Layer 3: Shared Runtime (already built)

- **Module Registry** — `[MODULE::verb]` dispatch. Already exists.
- **Event Dispatcher** — route events to subscribed handlers. Already exists.
- **Rule Supervisor** — DynamicSupervisor for rule processes. Skeleton exists.
- **PubSub** — Phoenix.PubSub for the messaging substrate. Dependency exists, not yet wired.

## Implementation Path

### Step 1: Extract declaration parsers into modules

Move `parse_rule`, `parse_condition_decl`, `parse_capability` out of `parser.ex` into `lib/anemos/declarations/rule.ex`, `condition.ex`, `capability.ex`. The core parser keeps expression/statement/block parsing. No behavior change — just reorganization.

### Step 2: Add the Declaration behaviour and registry

Replace hardcoded keyword dispatch with registry lookup. Compile-time registration via module attributes or a config module.

### Step 3: Add new declaration types incrementally

Each new declaration family is a new module implementing the behaviour:

- `policy` — PAM-style numbered match chains with `sufficient`/`requisite`
- `data` — static lists, dynamic subscriptions with `subscribe` sources
- `deffunc` — function definitions with typed parameters

### Step 4: Add pipeline support to the core grammar

`filter |> map |> reduce |> emit` is the most-requested feature across the Tcl sketches. It belongs in the core grammar (Layer 1), not in any single declaration type.

### Step 5: Extend destination types

Make the destination grammar extensible: `channel()`, `service()`, `webhook()`, `volume()`, `ipfs()`, etc. Each destination type could be a registered handler, similar to modules.

## What This Does NOT Mean

- Not a plugin system with dynamic loading. Declaration modules are compiled Elixir.
- Not separate projects. One repo, one lexer, one runtime.
- Not a rewrite. The current parser/compiler/runtime stay. Declaration parsing moves to modules.
- Not a framework for other people's DSLs. This serves the Orders of the System language family.

## File Structure

```
lib/anemos/
  lexer.ex                    # shared core
  parser.ex                   # shared core (expressions, statements, blocks)
  ast.ex                      # shared core nodes
  compiler.ex                 # shared core (expression eval)
  declaration.ex              # behaviour definition
  declarations/
    rule.ex                   # Anemos: rule, when blocks
    condition.ex              # Anemos: condition declarations
    capability.ex             # Anemos: capability, on demand
    policy.ex                 # CommonRule: policy evaluation chains
    data.ex                   # DataDef: static/dynamic data sources
    topology.ex               # Topology: unit/node/link/service (later)
    function.ex               # Functions: deffunc (later)
  runtime/
    dispatcher.ex             # shared core
    module_registry.ex        # shared core
    module.ex                 # shared core behaviour
    rule_supervisor.ex        # shared core
    modules/                  # module implementations
```

## Vault Sources

- Tcl sketches: `~/toolboxes/*.tcl`, `~/github/anemos/*.tcl`
- Language spec: `097 Orders of the System/96 Standards/Automation DSL - Language Specification.md`
- Triangle of Intent: `097 Orders of the System/99 Conversations/XAML vs XUL Comparison.md`
- Gap analysis: `docs/design-notes/tcl-sketch-analysis.md`
