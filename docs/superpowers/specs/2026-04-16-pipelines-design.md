# Pipe Operator and Pipeline Built-ins — Design Spec

## Overview

Two separate constructs that work together:

1. **Pipe operator `|>`** — a general-purpose binary operator that inserts the left-hand value as the first argument of the right-hand expression. Compile-time rewrite, like Elixir's `|>`.

2. **Pipeline built-in functions** — `filter`, `map`, `reduce`, `emit` — collection-processing functions that are always available in the language. They happen to chain naturally with `|>` but are conceptually independent. Implemented as an internal builtins module but invoked without module qualification.

## Pipe Operator `|>`

### Syntax

`|>` is already tokenized by the lexer. It becomes a binary operator at precedence level 0 — the lowest, binding after all other operators. Left-associative.

```
a |> b |> c   →   (a |> b) |> c
?x + 1 |> f   →   (?x + 1) |> f
```

### Semantics

Compile-time first-argument insertion. The left-hand value is prepended to the right-hand side's argument list:

- **With built-in calls:** `?items |> filter ?x (?x > 10)` → `filter(?items, ?x, ?x > 10)`
- **With commands:** `?data |> [MODULE::sort "asc"]` → `[MODULE::sort ?data "asc"]`
- **Chaining:** Each `|>` resolves independently — resolve left, apply right. The result of each stage is the input to the next.

### Parser

Add `:|>` to `@precedence` at level 0. The existing precedence climbing produces `%BinaryOp{op: :|>, left: expr, right: expr}` automatically. No new AST nodes needed for the pipe itself.

### Compiler

In `resolve_expr` for `%BinaryOp{op: :|>}`:

1. Resolve the left side to get the value
2. Dispatch on the right side:
   - `%AST.BuiltinCall{}` — evaluate the built-in with the value as collection input
   - `%AST.Command{}` — prepend the value to the command's args, evaluate as normal command
   - Other expression — prepend value as first arg

## Pipeline Built-in Functions

### Syntax

Four built-in functions, each with a specific argument shape. Invoked bare (no module prefix). When used with `|>`, the collection argument comes from the pipe. They can also be used standalone.

```
filter <var> (<predicate>)
map <var> (<transform>)
reduce <acc-name> <initial-value> <var> (<body>)
emit <command>
```

### Examples

```
?items |> filter ?x (?x > 10)
?items |> map ?x (?x * 2)
?items |> reduce total 0 ?x ($total + ?x)
?items |> emit [LOG::write ?x]

; chained
?scores |> filter ?s (?s > 0) |> map ?s (?s * 100) |> reduce sum 0 ?s ($sum + ?s)
```

### Semantics

- **filter** — iterates the collection, binds each element to `?var`, evaluates the predicate, keeps elements where predicate is truthy. Returns a new list.
- **map** — iterates the collection, binds each element to `?var`, evaluates the transform expression, collects results. Returns a new list.
- **reduce** — iterates the collection with an accumulator. The accumulator is initialized to the explicit initial value and stored as `$acc-name` (set binding). Each iteration binds the element to `?var` and evaluates the body — the body's return value becomes the new accumulator. Returns the final accumulated value.
- **emit** — iterates the collection, pipes each element as the first argument to the command expression. Side effect. Returns the original collection unchanged.

### AST Node

```elixir
defmodule BuiltinCall do
  @moduledoc "A built-in function call (filter, map, reduce, emit)."
  @enforce_keys []
  @type t :: %__MODULE__{
    name: :filter | :map | :reduce | :emit,
    args: list(),
    line: non_neg_integer() | nil
  }
  defstruct [:name, :args, :line]
end
```

The `args` field holds the parsed arguments specific to each built-in:
- filter: `[var_name :: String.t(), predicate :: AST node]`
- map: `[var_name :: String.t(), transform :: AST node]`
- reduce: `[acc_name :: String.t(), initial :: AST node, var_name :: String.t(), body :: AST node]`
- emit: `[command :: AST node]`

### Parser

`filter`, `map`, `reduce`, `emit` are already keywords. Add `parse_atom_expression` clauses that recognize them in expression position and dispatch to argument-shape-specific parsers:

```elixir
defp parse_atom_expression([{:keyword, meta, :filter} | rest]) -> parse_builtin_filter(meta, rest)
defp parse_atom_expression([{:keyword, meta, :map} | rest]) -> parse_builtin_map(meta, rest)
defp parse_atom_expression([{:keyword, meta, :reduce} | rest]) -> parse_builtin_reduce(meta, rest)
defp parse_atom_expression([{:keyword, meta, :emit} | rest]) -> parse_builtin_emit(meta, rest)
```

Each parser reads its specific argument shape and produces a `%AST.BuiltinCall{}`.

These clauses must be placed carefully — `filter`, `map`, `reduce`, `emit` as keywords could appear in other contexts (identifiers, data block content). They only parse as built-in calls when encountered in expression position (inside `parse_atom_expression`), which is the right scope.

**`emit` disambiguation:** The `emit` keyword already exists as a statement type (channel publishing). Pipeline `emit` is a different construct — it appears in expression position (right side of `|>`), not statement position. The parser naturally disambiguates: `parse_statement` matches `emit` as a channel publish statement, `parse_atom_expression` matches `emit` as a pipeline built-in. No conflict.

### Compiler — Built-in Evaluation

An internal `Anemos.Runtime.Builtins` module with pure functions. The compiler calls these directly when resolving `%BinaryOp{op: :|>}` with a `%BuiltinCall{}` on the right side.

```elixir
defmodule Anemos.Runtime.Builtins do
  @moduledoc """
  Internal built-in functions for collection processing.

  Called by the compiler when evaluating pipe expressions with
  filter/map/reduce/emit stages. Not user-facing.
  """

  def filter(collection, var_name, predicate_fn, context, bindings)
  def map(collection, var_name, transform_fn, context, bindings)
  def reduce(collection, acc_name, initial, var_name, body_fn, context, bindings)
  def emit(collection, command_fn, context, bindings)
end
```

The compiler builds closures from the predicate/transform/body expressions (same pattern as `while`/`for` loops) and passes them to the builtins functions.

**filter:** `Enum.filter(collection, fn element -> bind element to ?var, eval predicate end)`

**map:** `Enum.map(collection, fn element -> bind element to ?var, eval transform end)`

**reduce:** `Enum.reduce(collection, initial, fn element, acc -> bind element to ?var, bind acc to $acc_name, eval body end)`

**emit:** `Enum.each(collection, fn element -> prepend element to command args, eval command end)`. Returns original collection.

### Pipe with Commands

When the right side of `|>` is a command (`%AST.Command{}`), the compiler prepends the piped value to the command's resolved args:

```
?data |> [MODULE::transform "option"]
→ MODULE::transform(?data, "option")
```

This is straightforward — resolve the left value, cons it onto the args list, evaluate the command normally.

### Error Handling

- Piping a non-collection into filter/map/reduce — the built-in functions call `List.wrap/1` on the input, so a single value becomes `[value]`. This is forgiving rather than crashing.
- Reduce with empty collection — returns the initial value.
- Filter/map with empty collection — returns `[]`.
- Emit with empty collection — no-op, returns `[]`.
