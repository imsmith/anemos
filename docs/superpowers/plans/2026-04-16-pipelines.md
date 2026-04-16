# Pipe Operator & Pipeline Built-ins Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the `|>` pipe operator (compile-time first-arg insertion) and four built-in collection-processing functions (filter, map, reduce, emit).

**Architecture:** `|>` is a binary operator at precedence 0 that rewrites `a |> f(b)` to `f(a, b)` at compile time. The built-in functions (filter, map, reduce, emit) are parsed as `%AST.BuiltinCall{}` nodes in expression position and evaluated by `Anemos.Runtime.Builtins` — a pure-function module called directly by the compiler. No module registration needed.

**Tech Stack:** Elixir/OTP, NimbleParsec, ExUnit

---

## File Map

**New files:**
- `lib/anemos/runtime/builtins.ex` — Pure functions for filter/map/reduce/emit
- `test/anemos/pipe_test.exs` — End-to-end pipe and pipeline tests

**Modified files:**
- `lib/anemos/ast.ex` — Add `BuiltinCall` struct
- `lib/anemos/parser.ex` — Add `|>` to precedence table, add `parse_atom_expression` clauses for filter/map/reduce/emit
- `lib/anemos/compiler.ex` — Handle `:|>` in `eval_condition`, handle `%AST.BuiltinCall{}` in `resolve_expr`
- `test/anemos/parser_test.exs` — Parse tests for pipe and built-in syntax
- `test/anemos/compiler_test.exs` — Compile tests for pipe rewrite and built-in evaluation

---

### Task 1: AST Node — BuiltinCall

**Files:**
- Modify: `lib/anemos/ast.ex`
- Test: `test/anemos/ast_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/anemos/ast_test.exs`:

```elixir
test "BuiltinCall struct has all fields" do
  node = %Anemos.AST.BuiltinCall{
    name: :filter,
    args: ["x", %Anemos.AST.BinaryOp{op: :>, left: nil, right: nil}],
    line: 1
  }

  assert node.name == :filter
  assert length(node.args) == 2
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/imsmith/github/anemos && mix test test/anemos/ast_test.exs 2>&1 | tail -5`
Expected: FAIL — `Anemos.AST.BuiltinCall` not defined

- [ ] **Step 3: Write minimal implementation**

Add to `lib/anemos/ast.ex` before the closing `end` of the `Anemos.AST` module (before line 247):

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

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /home/imsmith/github/anemos && mix test test/anemos/ast_test.exs 2>&1 | tail -5`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/anemos/ast.ex test/anemos/ast_test.exs
git commit -m "feat: add BuiltinCall AST node"
```

---

### Task 2: Parser — Pipe Operator in Precedence Table

**Files:**
- Modify: `lib/anemos/parser.ex`
- Test: `test/anemos/parser_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/anemos/parser_test.exs`:

```elixir
test "parses pipe operator" do
  input = """
  rule r {
    when EV {
      let x = ?items |> ?items
    }
  }
  """

  assert {:ok, %{declarations: [rule]}} = Anemos.Parser.parse(input)
  when_block = Enum.find(rule.body, &match?(%Anemos.AST.When{}, &1))
  let_stmt = hd(when_block.body)
  assert %Anemos.AST.BinaryOp{op: :|>} = let_stmt.value
end

test "pipe operator has lowest precedence" do
  input = """
  rule r {
    when EV {
      let x = ?a + 1 |> ?b
    }
  }
  """

  assert {:ok, %{declarations: [rule]}} = Anemos.Parser.parse(input)
  when_block = Enum.find(rule.body, &match?(%Anemos.AST.When{}, &1))
  let_stmt = hd(when_block.body)
  # |> binds looser than +, so it's (?a + 1) |> ?b
  assert %Anemos.AST.BinaryOp{op: :|>, left: %Anemos.AST.BinaryOp{op: :+}} = let_stmt.value
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/imsmith/github/anemos && mix test test/anemos/parser_test.exs 2>&1 | tail -10`
Expected: FAIL — `|>` not recognized as an operator by `peek_binary_op`

- [ ] **Step 3: Add `|>` to precedence table**

In `lib/anemos/parser.ex`, update the `@precedence` map (line 23) to add `:|>` at level 0:

```elixir
@precedence %{
  |>: 0,
  in: 1, notin: 1, contains: 1, starts_with: 1, ends_with: 1, matches_glob: 1, matches_regex: 1, memberof: 1,
  ||: 2, or: 2,
  &&: 3, and: 3,
  |: 4,
  ^: 5,
  &: 6,
  ==: 7, !=: 7, ===: 7, !==: 7, eq: 7, ne: 7,
  <: 8, <=: 8, >: 8, >=: 8, lt: 8, le: 8, gt: 8, ge: 8,
  "<<": 9, ">>": 9,
  +: 10, -: 10,
  *: 11, /: 11, %: 11
}
```

The `|>` token is already produced by the lexer as `{:operator, _, :|>}`, so `peek_binary_op` will pick it up from the existing `{:operator, _, op}` clause (line 1258) and find it in the precedence map.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /home/imsmith/github/anemos && mix test test/anemos/parser_test.exs 2>&1 | tail -5`
Expected: PASS

- [ ] **Step 5: Run full test suite**

Run: `cd /home/imsmith/github/anemos && mix test 2>&1 | tail -3`
Expected: All tests pass

- [ ] **Step 6: Commit**

```bash
git add lib/anemos/parser.ex test/anemos/parser_test.exs
git commit -m "feat: add pipe operator to precedence table"
```

---

### Task 3: Parser — Built-in Function Expressions

**Files:**
- Modify: `lib/anemos/parser.ex`
- Test: `test/anemos/parser_test.exs`

- [ ] **Step 1: Write the failing tests**

Add to `test/anemos/parser_test.exs`:

```elixir
test "parses filter built-in" do
  input = """
  rule r {
    when EV {
      let x = ?items |> filter ?x (?x > 10)
    }
  }
  """

  assert {:ok, %{declarations: [rule]}} = Anemos.Parser.parse(input)
  when_block = Enum.find(rule.body, &match?(%Anemos.AST.When{}, &1))
  let_stmt = hd(when_block.body)
  assert %Anemos.AST.BinaryOp{op: :|>, right: %Anemos.AST.BuiltinCall{name: :filter}} = let_stmt.value
end

test "parses map built-in" do
  input = """
  rule r {
    when EV {
      let x = ?items |> map ?x (?x * 2)
    }
  }
  """

  assert {:ok, %{declarations: [rule]}} = Anemos.Parser.parse(input)
  when_block = Enum.find(rule.body, &match?(%Anemos.AST.When{}, &1))
  let_stmt = hd(when_block.body)
  assert %Anemos.AST.BinaryOp{op: :|>, right: %Anemos.AST.BuiltinCall{name: :map}} = let_stmt.value
end

test "parses reduce built-in" do
  input = """
  rule r {
    when EV {
      let x = ?items |> reduce total 0 ?x ($total + ?x)
    }
  }
  """

  assert {:ok, %{declarations: [rule]}} = Anemos.Parser.parse(input)
  when_block = Enum.find(rule.body, &match?(%Anemos.AST.When{}, &1))
  let_stmt = hd(when_block.body)
  assert %Anemos.AST.BinaryOp{op: :|>, right: %Anemos.AST.BuiltinCall{name: :reduce}} = let_stmt.value
  builtin = let_stmt.value.right
  # args: [acc_name, initial_expr, var_name, body_expr]
  assert length(builtin.args) == 4
end

test "parses emit built-in" do
  input = """
  rule r {
    when EV {
      let x = ?items |> emit [LOG::write "done"]
    }
  }
  """

  assert {:ok, %{declarations: [rule]}} = Anemos.Parser.parse(input)
  when_block = Enum.find(rule.body, &match?(%Anemos.AST.When{}, &1))
  let_stmt = hd(when_block.body)
  assert %Anemos.AST.BinaryOp{op: :|>, right: %Anemos.AST.BuiltinCall{name: :emit}} = let_stmt.value
end

test "parses chained pipe with multiple built-ins" do
  input = """
  rule r {
    when EV {
      let x = ?items |> filter ?x (?x > 0) |> map ?x (?x * 100)
    }
  }
  """

  assert {:ok, %{declarations: [rule]}} = Anemos.Parser.parse(input)
  when_block = Enum.find(rule.body, &match?(%Anemos.AST.When{}, &1))
  let_stmt = hd(when_block.body)
  # Chained: (items |> filter) |> map — left-associative
  assert %Anemos.AST.BinaryOp{
    op: :|>,
    left: %Anemos.AST.BinaryOp{op: :|>, right: %Anemos.AST.BuiltinCall{name: :filter}},
    right: %Anemos.AST.BuiltinCall{name: :map}
  } = let_stmt.value
end
```

- [ ] **Step 2: Run test to verify they fail**

Run: `cd /home/imsmith/github/anemos && mix test test/anemos/parser_test.exs 2>&1 | tail -10`
Expected: FAIL — filter/map/reduce/emit not recognized in expression position (they parse as keyword literals or cause errors)

- [ ] **Step 3: Add parse_atom_expression clauses for built-ins**

In `lib/anemos/parser.ex`, add these clauses to `parse_atom_expression` BEFORE the catch-all keyword clause (which is at line ~1325 `defp parse_atom_expression([{:keyword, meta, kw} | rest])`):

```elixir
# --- Built-in pipeline functions ---

defp parse_atom_expression([{:keyword, meta, :filter}, {:query_var, _, var_name} | rest]) do
  case parse_expression(rest) do
    {:ok, predicate, rest} ->
      {:ok, %AST.BuiltinCall{name: :filter, args: [var_name, predicate], line: meta[:line]}, rest}
    {:error, _} = err -> err
  end
end

defp parse_atom_expression([{:keyword, meta, :map}, {:query_var, _, var_name} | rest]) do
  case parse_expression(rest) do
    {:ok, transform, rest} ->
      {:ok, %AST.BuiltinCall{name: :map, args: [var_name, transform], line: meta[:line]}, rest}
    {:error, _} = err -> err
  end
end

defp parse_atom_expression([{:keyword, meta, :reduce}, {:identifier, _, acc_name} | rest]) do
  case parse_expression(rest) do
    {:ok, initial, [{:query_var, _, var_name} | rest2]} ->
      case parse_expression(rest2) do
        {:ok, body, rest3} ->
          {:ok, %AST.BuiltinCall{
            name: :reduce,
            args: [acc_name, initial, var_name, body],
            line: meta[:line]
          }, rest3}
        {:error, _} = err -> err
      end
    {:ok, _, _} -> {:error, "Expected query variable after reduce initial value on line #{meta[:line]}"}
    {:error, _} = err -> err
  end
end

defp parse_atom_expression([{:keyword, meta, :emit} | rest]) do
  case parse_expression(rest) do
    {:ok, command, rest} ->
      {:ok, %AST.BuiltinCall{name: :emit, args: [command], line: meta[:line]}, rest}
    {:error, _} = err -> err
  end
end
```

**Important:** These clauses match `{:keyword, _, :filter}` followed by `{:query_var, _, _}`. This means `filter` as a bare keyword (not followed by a `?var`) still falls through to the existing keyword catch-all clause, preserving backward compatibility. The `emit` clause is more general — it takes any expression — so its ordering matters. Place `emit` before the general keyword catch-all but after more specific keyword matchers.

The `reduce` clause parses: `reduce <identifier> <expression> <query_var> <expression>`. The initial value expression will consume tokens until it hits the `?var`, which is the next `{:query_var, _, _}` token. Since `parse_expression` stops at tokens it doesn't recognize as part of an expression, the `?var` after the initial value should remain unconsumed. However, if the initial value is a complex expression, there could be ambiguity. Using parenthesized expressions for the body (`reduce total 0 ?x ($total + ?x)`) ensures clean parsing since `(...)` is self-delimiting.

The initial value for `reduce` is typically a simple literal (`0`, `""`, `[]`), so in practice the `parse_expression` call will consume just that literal and leave the `?var` token.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /home/imsmith/github/anemos && mix test test/anemos/parser_test.exs 2>&1 | tail -5`
Expected: PASS

- [ ] **Step 5: Run full test suite**

Run: `cd /home/imsmith/github/anemos && mix test 2>&1 | tail -3`
Expected: All tests pass

- [ ] **Step 6: Commit**

```bash
git add lib/anemos/parser.ex test/anemos/parser_test.exs
git commit -m "feat: parse filter/map/reduce/emit built-in expressions"
```

---

### Task 4: Builtins Module

**Files:**
- Create: `lib/anemos/runtime/builtins.ex`
- Test: `test/anemos/builtins_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/anemos/builtins_test.exs`:

```elixir
defmodule Anemos.Runtime.BuiltinsTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Anemos.Runtime.Builtins

  test "filter keeps elements where predicate is truthy" do
    collection = [1, 2, 3, 4, 5]
    predicate_fn = fn _ctx, bindings -> Map.get(bindings, {:let, "x"}) > 3 end

    result = Builtins.filter(collection, "x", predicate_fn, %{}, %{})
    assert result == [4, 5]
  end

  test "filter with empty collection returns empty" do
    result = Builtins.filter([], "x", fn _, _ -> true end, %{}, %{})
    assert result == []
  end

  test "map transforms each element" do
    collection = [1, 2, 3]
    transform_fn = fn _ctx, bindings -> Map.get(bindings, {:let, "x"}) * 10 end

    result = Builtins.map(collection, "x", transform_fn, %{}, %{})
    assert result == [10, 20, 30]
  end

  test "reduce accumulates over collection" do
    collection = [1, 2, 3, 4]
    body_fn = fn _ctx, bindings ->
      Map.get(bindings, {:set, "total"}) + Map.get(bindings, {:let, "x"})
    end

    result = Builtins.reduce(collection, "total", 0, "x", body_fn, %{}, %{})
    assert result == 10
  end

  test "reduce with empty collection returns initial value" do
    result = Builtins.reduce([], "acc", 42, "x", fn _, _ -> 0 end, %{}, %{})
    assert result == 42
  end

  test "emit calls command function for each element and returns collection" do
    collection = [1, 2, 3]
    test_pid = self()
    command_fn = fn element, _ctx, _bindings ->
      send(test_pid, {:emitted, element})
    end

    result = Builtins.emit(collection, command_fn, %{}, %{})
    assert result == [1, 2, 3]

    assert_received {:emitted, 1}
    assert_received {:emitted, 2}
    assert_received {:emitted, 3}
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/imsmith/github/anemos && mix test test/anemos/builtins_test.exs 2>&1 | tail -5`
Expected: FAIL — module not defined

- [ ] **Step 3: Write the Builtins implementation**

Create `lib/anemos/runtime/builtins.ex`:

```elixir
defmodule Anemos.Runtime.Builtins do
  @moduledoc """
  Built-in collection-processing functions for pipeline expressions.

  Called directly by the compiler when evaluating pipe expressions
  with filter/map/reduce/emit. Not user-facing — no module registration.
  """

  @doc """
  Keeps elements where `predicate_fn.(context, bindings_with_element)` is truthy.
  """
  def filter(collection, var_name, predicate_fn, context, bindings) do
    collection
    |> List.wrap()
    |> Enum.filter(fn element ->
      iter_bindings = Map.put(bindings, {:let, var_name}, element)
      predicate_fn.(context, iter_bindings)
    end)
  end

  @doc """
  Transforms each element via `transform_fn.(context, bindings_with_element)`.
  """
  def map(collection, var_name, transform_fn, context, bindings) do
    collection
    |> List.wrap()
    |> Enum.map(fn element ->
      iter_bindings = Map.put(bindings, {:let, var_name}, element)
      transform_fn.(context, iter_bindings)
    end)
  end

  @doc """
  Reduces the collection with an accumulator.

  The accumulator is stored as `{:set, acc_name}` in bindings and initialized
  to `initial`. Each iteration binds the element to `{:let, var_name}` and
  evaluates `body_fn` — the return value becomes the new accumulator.
  """
  def reduce(collection, acc_name, initial, var_name, body_fn, context, bindings) do
    collection
    |> List.wrap()
    |> Enum.reduce(initial, fn element, acc ->
      iter_bindings =
        bindings
        |> Map.put({:let, var_name}, element)
        |> Map.put({:set, acc_name}, acc)

      body_fn.(context, iter_bindings)
    end)
  end

  @doc """
  Calls `command_fn.(element, context, bindings)` for each element.

  Returns the original collection unchanged (side-effect only).
  """
  def emit(collection, command_fn, context, bindings) do
    wrapped = List.wrap(collection)

    Enum.each(wrapped, fn element ->
      command_fn.(element, context, bindings)
    end)

    wrapped
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /home/imsmith/github/anemos && mix test test/anemos/builtins_test.exs 2>&1 | tail -5`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/anemos/runtime/builtins.ex test/anemos/builtins_test.exs
git commit -m "feat: add Builtins module for filter/map/reduce/emit"
```

---

### Task 5: Compiler — Pipe Operator and BuiltinCall Evaluation

**Files:**
- Modify: `lib/anemos/compiler.ex`
- Test: `test/anemos/compiler_test.exs`

- [ ] **Step 1: Write the failing tests**

Add to `test/anemos/compiler_test.exs`:

```elixir
test "compiles pipe with filter" do
  input = """
  rule r {
    when EV {
      let result = ?items |> filter ?x (?x > 2)
      log @result
    }
  }
  """

  {:ok, ast} = Parser.parse(input)
  {:ok, %{rules: [compiled]}} = Compiler.compile(ast)

  context = %{context_data: %{"items" => [1, 2, 3, 4, 5]}}
  {:ok, ops, _} = compiled.handler.("EV", context, %{})

  log_op = Enum.find(ops, &(&1.type == :log))
  assert log_op.value == [3, 4, 5]
end

test "compiles pipe with map" do
  input = """
  rule r {
    when EV {
      let result = ?items |> map ?x (?x * 10)
      log @result
    }
  }
  """

  {:ok, ast} = Parser.parse(input)
  {:ok, %{rules: [compiled]}} = Compiler.compile(ast)

  context = %{context_data: %{"items" => [1, 2, 3]}}
  {:ok, ops, _} = compiled.handler.("EV", context, %{})

  log_op = Enum.find(ops, &(&1.type == :log))
  assert log_op.value == [10, 20, 30]
end

test "compiles pipe with reduce" do
  input = """
  rule r {
    when EV {
      let result = ?items |> reduce total 0 ?x ($total + ?x)
      log @result
    }
  }
  """

  {:ok, ast} = Parser.parse(input)
  {:ok, %{rules: [compiled]}} = Compiler.compile(ast)

  context = %{context_data: %{"items" => [1, 2, 3, 4]}}
  {:ok, ops, _} = compiled.handler.("EV", context, %{})

  log_op = Enum.find(ops, &(&1.type == :log))
  assert log_op.value == 10
end

test "compiles chained pipe: filter then map" do
  input = """
  rule r {
    when EV {
      let result = ?items |> filter ?x (?x > 2) |> map ?x (?x * 100)
      log @result
    }
  }
  """

  {:ok, ast} = Parser.parse(input)
  {:ok, %{rules: [compiled]}} = Compiler.compile(ast)

  context = %{context_data: %{"items" => [1, 2, 3, 4, 5]}}
  {:ok, ops, _} = compiled.handler.("EV", context, %{})

  log_op = Enum.find(ops, &(&1.type == :log))
  assert log_op.value == [300, 400, 500]
end
```

- [ ] **Step 2: Run test to verify they fail**

Run: `cd /home/imsmith/github/anemos && mix test test/anemos/compiler_test.exs 2>&1 | tail -10`
Expected: FAIL — `:|>` not handled in eval_condition, `%BuiltinCall{}` not handled in resolve_expr

- [ ] **Step 3: Add compiler support**

In `lib/anemos/compiler.ex`, add two things:

**A) Handle `:|>` in `eval_condition`** (in the `case op do` block, around line 772):

```elixir
:|> ->
  # Pipe: left is the collection, right is a BuiltinCall or Command
  # l is already resolved; r needs special handling since it's a BuiltinCall node
  # But wait — eval_condition resolves both sides before the case.
  # For |>, we need the RIGHT side as an AST node, not resolved.
  # This means |> can't use the standard resolve-both-then-match pattern.
```

Actually, the standard `eval_condition` resolves both `left` and `right` before the case statement (lines 769-770). For `|>`, we need the right side as an unresolved AST node (a `%BuiltinCall{}`). This means `|>` needs special handling BEFORE the standard resolve path.

Add a new clause to `eval_condition` that matches `:|>` specifically, BEFORE the general `%BinaryOp{}` clause:

```elixir
defp eval_condition(%AST.BinaryOp{op: :|>, left: left, right: right}, context, bindings) do
  collection = resolve_expr(left, context, bindings)
  eval_pipe(collection, right, context, bindings)
end
```

Add `eval_pipe/4`:

```elixir
defp eval_pipe(collection, %AST.BuiltinCall{name: :filter, args: [var_name, predicate]}, context, bindings) do
  predicate_fn = fn ctx, bnd -> eval_condition(predicate, ctx, bnd) end
  Anemos.Runtime.Builtins.filter(collection, var_name, predicate_fn, context, bindings)
end

defp eval_pipe(collection, %AST.BuiltinCall{name: :map, args: [var_name, transform]}, context, bindings) do
  transform_fn = fn ctx, bnd -> resolve_expr(transform, ctx, bnd) end
  Anemos.Runtime.Builtins.map(collection, var_name, transform_fn, context, bindings)
end

defp eval_pipe(collection, %AST.BuiltinCall{name: :reduce, args: [acc_name, initial_expr, var_name, body]}, context, bindings) do
  initial = resolve_expr(initial_expr, context, bindings)
  body_fn = fn ctx, bnd -> resolve_expr(body, ctx, bnd) end
  Anemos.Runtime.Builtins.reduce(collection, acc_name, initial, var_name, body_fn, context, bindings)
end

defp eval_pipe(collection, %AST.BuiltinCall{name: :emit, args: [command]}, context, bindings) do
  command_fn = fn element, ctx, bnd ->
    case command do
      %AST.Command{module: mod, verb: verb, args: args} ->
        resolved_args = [element | Enum.map(args, &resolve_expr(&1, ctx, bnd))]
        %{type: :command, module: mod, verb: verb, args: resolved_args}
      other ->
        resolve_expr(other, ctx, bnd)
    end
  end
  Anemos.Runtime.Builtins.emit(collection, command_fn, context, bindings)
end

# Pipe with a command: prepend collection to args
defp eval_pipe(collection, %AST.Command{module: mod, verb: verb, args: args}, context, bindings) do
  resolved_args = [collection | Enum.map(args, &resolve_expr(&1, context, bindings))]
  %{type: :command, module: mod, verb: verb, args: resolved_args}
end

# Pipe with any other expression: treat as function call (future extensibility)
defp eval_pipe(collection, other, context, bindings) do
  resolve_expr(other, context, bindings)
end
```

**B) Handle `%AST.BuiltinCall{}` in `resolve_expr`** — this handles cases where a built-in appears without a pipe (standalone call). It would need the collection as a separate argument, but without a pipe there's no collection. For now, just pass through — built-ins are only meaningful as the right side of `|>`:

```elixir
defp resolve_expr(%AST.BuiltinCall{} = call, _context, _bindings), do: call
```

This keeps the AST node unresolved so `eval_pipe` can handle it.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /home/imsmith/github/anemos && mix test test/anemos/compiler_test.exs 2>&1 | tail -5`
Expected: PASS

- [ ] **Step 5: Run full test suite**

Run: `cd /home/imsmith/github/anemos && mix test 2>&1 | tail -3`
Expected: All tests pass

- [ ] **Step 6: Commit**

```bash
git add lib/anemos/compiler.ex test/anemos/compiler_test.exs
git commit -m "feat: compile pipe operator and built-in function evaluation"
```

---

### Task 6: End-to-End Integration Tests

**Files:**
- Create: `test/anemos/pipe_test.exs`

- [ ] **Step 1: Write end-to-end tests**

Create `test/anemos/pipe_test.exs`:

```elixir
defmodule Anemos.PipeIntegrationTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Anemos.Runtime.{Dispatcher, ModuleRegistry}

  test "pipe with filter dispatches correctly" do
    input = """
    rule process {
      when BATCH {
        let filtered = ?scores |> filter ?s (?s > 50)
        log @filtered
      }
    }
    """

    {:ok, ast} = Anemos.Parser.parse(input)
    {:ok, compiled} = Anemos.Compiler.compile(ast)
    {:ok, registry} = ModuleRegistry.start_link([])

    {:ok, dispatcher} =
      Dispatcher.start_link(rules: compiled.rules, registry: registry)

    results = Dispatcher.dispatch(dispatcher, "BATCH", %{context_data: %{"scores" => [10, 60, 30, 80, 45]}})
    ops = for {:ok, op} <- List.flatten(results), do: op
    log_op = Enum.find(ops, &(&1.type == :log))
    assert log_op.value == [60, 80]
  end

  test "chained pipeline: filter → map → reduce" do
    input = """
    rule analyze {
      when DATA {
        let result = ?values |> filter ?x (?x > 0) |> map ?x (?x * 2) |> reduce sum 0 ?x ($sum + ?x)
        log @result
      }
    }
    """

    {:ok, ast} = Anemos.Parser.parse(input)
    {:ok, compiled} = Anemos.Compiler.compile(ast)
    {:ok, registry} = ModuleRegistry.start_link([])

    {:ok, dispatcher} =
      Dispatcher.start_link(rules: compiled.rules, registry: registry)

    results = Dispatcher.dispatch(dispatcher, "DATA", %{context_data: %{"values" => [-1, 2, -3, 4, 5]}})
    ops = for {:ok, op} <- List.flatten(results), do: op
    log_op = Enum.find(ops, &(&1.type == :log))
    # filter: [2, 4, 5], map: [4, 8, 10], reduce: 22
    assert log_op.value == 22
  end

  test "pipe with non-list wraps single value" do
    input = """
    rule wrap {
      when EV {
        let result = ?single |> filter ?x (?x > 0)
        log @result
      }
    }
    """

    {:ok, ast} = Anemos.Parser.parse(input)
    {:ok, compiled} = Anemos.Compiler.compile(ast)
    {:ok, registry} = ModuleRegistry.start_link([])

    {:ok, dispatcher} =
      Dispatcher.start_link(rules: compiled.rules, registry: registry)

    results = Dispatcher.dispatch(dispatcher, "EV", %{context_data: %{"single" => 5}})
    ops = for {:ok, op} <- List.flatten(results), do: op
    log_op = Enum.find(ops, &(&1.type == :log))
    assert log_op.value == [5]
  end

  test "pipe with empty collection" do
    input = """
    rule empty {
      when EV {
        let result = ?items |> filter ?x (?x > 0) |> map ?x (?x * 10)
        log @result
      }
    }
    """

    {:ok, ast} = Anemos.Parser.parse(input)
    {:ok, compiled} = Anemos.Compiler.compile(ast)
    {:ok, registry} = ModuleRegistry.start_link([])

    {:ok, dispatcher} =
      Dispatcher.start_link(rules: compiled.rules, registry: registry)

    results = Dispatcher.dispatch(dispatcher, "EV", %{context_data: %{"items" => []}})
    ops = for {:ok, op} <- List.flatten(results), do: op
    log_op = Enum.find(ops, &(&1.type == :log))
    assert log_op.value == []
  end
end
```

- [ ] **Step 2: Run tests**

Run: `cd /home/imsmith/github/anemos && mix test test/anemos/pipe_test.exs 2>&1 | tail -10`
Expected: PASS (should work if prior tasks are complete)

- [ ] **Step 3: Run full test suite**

Run: `cd /home/imsmith/github/anemos && mix test 2>&1 | tail -3`
Expected: All tests pass

- [ ] **Step 4: Commit**

```bash
git add test/anemos/pipe_test.exs
git commit -m "test: end-to-end pipe and pipeline integration tests"
```
