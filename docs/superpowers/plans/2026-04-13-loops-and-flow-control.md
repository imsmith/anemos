# Loops and Flow Control Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement loops (`while`, `for`, `each`, `every`, `foreach`) and flow control (`return`, `done`, `nextevent`, `nextrule`) from spec sections 5.5 and 5.6.

**Architecture:** Loops compile to inline iteration within handler closures using `Enum.reduce_while` for early exit support. Flow control uses throw/catch within the handler closure boundary — `return` and `done` throw tagged tuples caught by `build_handler`, `nextevent` and `nextrule` produce operations that the dispatcher interprets. All new constructs follow the existing pattern: AST node struct, parser function, compiler eval_statement clause.

**Tech Stack:** Elixir/OTP, ExUnit, existing Anemos lexer/parser/compiler/dispatcher pipeline.

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `lib/anemos/ast.ex` | Modify | Add `While`, `For`, `Return`, `Done`, `NextEvent`, `NextRule` struct definitions |
| `lib/anemos/parser.ex` | Modify | Add `parse_while`, `parse_for`, `parse_return`, `parse_done`, `parse_nextevent`, `parse_nextrule` functions and wire into `parse_statement` dispatch |
| `lib/anemos/compiler.ex` | Modify | Add `eval_statement` clauses for all 6 new AST nodes; refactor `eval_body` and `build_handler` to support early exit via throw/catch |
| `lib/anemos/runtime/dispatcher.ex` | Modify | Handle `:nextevent` and `:nextrule` operation types in `execute_op` and `dispatch_to_rules` |
| `test/anemos/loop_test.exs` | Create | Tests for while, for, each, every, foreach — parsing, compilation, end-to-end |
| `test/anemos/flow_control_test.exs` | Create | Tests for return, done, nextevent, nextrule — parsing, compilation, end-to-end |

---

### Task 1: AST nodes for loops and flow control

**Files:**
- Modify: `lib/anemos/ast.ex:168-176` (after `BlockArgs`)

- [ ] **Step 1: Write the test — AST struct construction**

Create `test/anemos/loop_test.exs`:

```elixir
defmodule Anemos.LoopTest do
  @moduledoc false
  use ExUnit.Case

  alias Anemos.AST

  # --- AST struct tests ---

  test "While struct has condition and body" do
    node = %AST.While{condition: :cond, body: [:stmt], line: 1}
    assert node.condition == :cond
    assert node.body == [:stmt]
    assert node.line == 1
  end

  test "For struct has var, iterable, and body" do
    node = %AST.For{var: "x", iterable: :list, body: [:stmt], line: 1}
    assert node.var == "x"
    assert node.iterable == :list
    assert node.body == [:stmt]
  end
end
```

Create `test/anemos/flow_control_test.exs`:

```elixir
defmodule Anemos.FlowControlTest do
  @moduledoc false
  use ExUnit.Case

  alias Anemos.AST

  # --- AST struct tests ---

  test "Return struct has optional value" do
    node = %AST.Return{value: :expr, line: 1}
    assert node.value == :expr
  end

  test "Return struct defaults value to nil" do
    node = %AST.Return{line: 1}
    assert node.value == nil
  end

  test "Done struct has line" do
    node = %AST.Done{line: 1}
    assert node.line == 1
  end

  test "NextEvent struct has target and optional args" do
    node = %AST.NextEvent{target: "other-handler", args: %{}, line: 1}
    assert node.target == "other-handler"
  end

  test "NextRule struct has target and optional args" do
    node = %AST.NextRule{target: "other-rule", args: %{}, line: 1}
    assert node.target == "other-rule"
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/anemos/loop_test.exs test/anemos/flow_control_test.exs --trace`
Expected: compilation errors — `AST.While`, `AST.For`, `AST.Return`, `AST.Done`, `AST.NextEvent`, `AST.NextRule` not defined.

- [ ] **Step 3: Add AST node structs**

Add to `lib/anemos/ast.ex` before the closing `end` of the `Anemos.AST` module (after `BlockArgs`):

```elixir
  defmodule While do
    @moduledoc "A `while` loop: repeats body while condition is truthy."
    @enforce_keys []
    @type t :: %__MODULE__{condition: term(), body: list(), line: non_neg_integer() | nil}
    defstruct [:condition, :body, :line]
  end

  defmodule For do
    @moduledoc "A `for` loop: iterates `var` over `iterable`, executing body each time. Covers `for`, `each`, `every`, `foreach`."
    @enforce_keys []
    @type t :: %__MODULE__{var: String.t() | nil, iterable: term(), body: list(), keyword: atom() | nil, line: non_neg_integer() | nil}
    defstruct [:var, :iterable, :body, :keyword, :line]
  end

  defmodule Return do
    @moduledoc "A `return` statement: exits the current handler, optionally with a value."
    @enforce_keys []
    @type t :: %__MODULE__{value: term(), line: non_neg_integer() | nil}
    defstruct [:value, :line]
  end

  defmodule Done do
    @moduledoc "A `done` statement: exits the current handler with no value."
    @enforce_keys []
    @type t :: %__MODULE__{line: non_neg_integer() | nil}
    defstruct [:line]
  end

  defmodule NextEvent do
    @moduledoc "A `nextevent` statement: transitions to another `when` block within the same rule."
    @enforce_keys []
    @type t :: %__MODULE__{target: String.t() | nil, args: map() | nil, line: non_neg_integer() | nil}
    defstruct [:target, :args, :line]
  end

  defmodule NextRule do
    @moduledoc "A `nextrule` statement: dispatches to a different rule's pipeline."
    @enforce_keys []
    @type t :: %__MODULE__{target: String.t() | nil, args: map() | nil, line: non_neg_integer() | nil}
    defstruct [:target, :args, :line]
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/anemos/loop_test.exs test/anemos/flow_control_test.exs --trace`
Expected: all 7 tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/anemos/ast.ex test/anemos/loop_test.exs test/anemos/flow_control_test.exs
git commit -m "feat: add AST nodes for loops and flow control"
```

---

### Task 2: Parse loop statements

**Files:**
- Modify: `lib/anemos/parser.ex:434-451` (parse_statement dispatch)
- Test: `test/anemos/loop_test.exs`

- [ ] **Step 1: Write the failing parser tests**

Add to `test/anemos/loop_test.exs`:

```elixir
  # --- Parser tests ---

  test "parses while loop" do
    input = """
    rule r {
      when EV {
        while $count > 0 {
          log "tick"
        }
      }
    }
    """

    {:ok, %AST.Program{declarations: [rule]}} = Anemos.Parser.parse(input)
    [%AST.When{body: [%AST.While{} = w]}] = rule.body
    assert %AST.BinaryOp{op: :>} = w.condition
    assert [%AST.Log{}] = w.body
  end

  test "parses for-in loop" do
    input = """
    rule r {
      when EV {
        for item in ?items {
          log @item
        }
      }
    }
    """

    {:ok, %AST.Program{declarations: [rule]}} = Anemos.Parser.parse(input)
    [%AST.When{body: [%AST.For{} = f]}] = rule.body
    assert f.var == "item"
    assert %AST.VarRef{sigil: "?"} = f.iterable
    assert f.keyword == :for
  end

  test "parses each loop" do
    input = """
    rule r {
      when EV {
        each item {
          log @item
        }
      }
    }
    """

    {:ok, %AST.Program{declarations: [rule]}} = Anemos.Parser.parse(input)
    [%AST.When{body: [%AST.For{} = f]}] = rule.body
    assert f.var == "item"
    assert f.iterable == nil
    assert f.keyword == :each
  end

  test "parses foreach MODULE::verb loop" do
    input = """
    rule r {
      when EV {
        foreach FILE::list {
          log @item
        }
      }
    }
    """

    {:ok, %AST.Program{declarations: [rule]}} = Anemos.Parser.parse(input)
    [%AST.When{body: [%AST.For{} = f]}] = rule.body
    assert %AST.Command{module: "FILE", verb: "list"} = f.iterable
    assert f.keyword == :foreach
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/anemos/loop_test.exs --trace`
Expected: FAIL — parser hits "Unexpected token" on `while`, `for`, `each`, `foreach`.

- [ ] **Step 3: Add parser functions for loops**

Add to `parse_statement` dispatch in `lib/anemos/parser.ex` (after the existing `defp parse_statement` clauses, before the catch-all):

```elixir
  defp parse_statement([{:keyword, _, :while} | rest]), do: parse_while(rest)
  defp parse_statement([{:keyword, _, :for} | rest]), do: parse_for(rest)
  defp parse_statement([{:keyword, _, :each} | rest]), do: parse_each(rest)
  defp parse_statement([{:keyword, _, :every} | rest]), do: parse_each(rest)
  defp parse_statement([{:keyword, _, :foreach} | rest]), do: parse_foreach(rest)
```

Add the parsing functions:

```elixir
  # --- While ---

  defp parse_while(tokens) do
    line = token_line(hd(tokens))

    with {:ok, condition, rest} <- parse_expression(tokens),
         {:ok, rest} <- expect(rest, :lbrace),
         {:ok, body, rest} <- parse_statements_until_rbrace(rest, []),
         {:ok, rest} <- expect(rest, :rbrace) do
      {:ok, %AST.While{condition: condition, body: Enum.reverse(body), line: line}, rest}
    end
  end

  # --- For ---

  defp parse_for(tokens) do
    line = token_line(hd(tokens))

    case tokens do
      [{:identifier, _, var}, {:word_operator, _, :in} | rest] ->
        with {:ok, iterable, rest} <- parse_expression(rest),
             {:ok, rest} <- expect(rest, :lbrace),
             {:ok, body, rest} <- parse_statements_until_rbrace(rest, []),
             {:ok, rest} <- expect(rest, :rbrace) do
          {:ok, %AST.For{var: var, iterable: iterable, body: Enum.reverse(body), keyword: :for, line: line}, rest}
        end

      [{_, meta, _} | _] ->
        {:error, "Expected 'for <var> in <expr>' on line #{meta[:line]}"}

      [] ->
        {:error, "Expected 'for <var> in <expr>' but got end of input"}
    end
  end

  # --- Each / Every ---

  defp parse_each(tokens) do
    line = token_line(hd(tokens))

    case tokens do
      [{:identifier, _, var}, {:word_operator, _, :in} | rest] ->
        with {:ok, iterable, rest} <- parse_expression(rest),
             {:ok, rest} <- expect(rest, :lbrace),
             {:ok, body, rest} <- parse_statements_until_rbrace(rest, []),
             {:ok, rest} <- expect(rest, :rbrace) do
          {:ok, %AST.For{var: var, iterable: iterable, body: Enum.reverse(body), keyword: :each, line: line}, rest}
        end

      [{:identifier, _, var}, {:lbrace, _, _} | _] = all ->
        [{:identifier, _, _} | rest] = all
        with {:ok, rest} <- expect(rest, :lbrace),
             {:ok, body, rest} <- parse_statements_until_rbrace(rest, []),
             {:ok, rest} <- expect(rest, :rbrace) do
          {:ok, %AST.For{var: var, iterable: nil, body: Enum.reverse(body), keyword: :each, line: line}, rest}
        end

      [{_, meta, _} | _] ->
        {:error, "Expected 'each <var> [in <expr>]' on line #{meta[:line]}"}

      [] ->
        {:error, "Expected 'each <var>' but got end of input"}
    end
  end

  # --- Foreach ---

  defp parse_foreach(tokens) do
    line = token_line(hd(tokens))

    case tokens do
      [{:module_id, meta, mod}, {:double_colon, _, _} | rest] ->
        with {:ok, verb, rest} <- parse_command_verb(rest),
             {:ok, rest} <- expect(rest, :lbrace),
             {:ok, body, rest} <- parse_statements_until_rbrace(rest, []),
             {:ok, rest} <- expect(rest, :rbrace) do
          cmd = %AST.Command{module: mod, verb: verb, args: [], line: meta[:line]}
          {:ok, %AST.For{var: "item", iterable: cmd, body: Enum.reverse(body), keyword: :foreach, line: line}, rest}
        end

      [{_, meta, _} | _] ->
        {:error, "Expected 'foreach MODULE::verb' on line #{meta[:line]}"}

      [] ->
        {:error, "Expected 'foreach MODULE::verb' but got end of input"}
    end
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/anemos/loop_test.exs --trace`
Expected: all parser tests pass (struct tests + 4 new parser tests).

- [ ] **Step 5: Run full test suite for regressions**

Run: `mix test --trace`
Expected: only the 3 pre-existing NLD failures, no new failures.

- [ ] **Step 6: Commit**

```bash
git add lib/anemos/parser.ex test/anemos/loop_test.exs
git commit -m "feat: parse while, for, each, every, foreach loops"
```

---

### Task 3: Parse flow control statements

**Files:**
- Modify: `lib/anemos/parser.ex`
- Test: `test/anemos/flow_control_test.exs`

- [ ] **Step 1: Write the failing parser tests**

Add to `test/anemos/flow_control_test.exs`:

```elixir
  # --- Parser tests ---

  test "parses return with value" do
    input = """
    rule r {
      when EV {
        return "done"
      }
    }
    """

    {:ok, %AST.Program{declarations: [rule]}} = Anemos.Parser.parse(input)
    [%AST.When{body: [%AST.Return{} = r]}] = rule.body
    assert %AST.Literal{value: "done"} = r.value
  end

  test "parses return without value" do
    input = """
    rule r {
      when EV {
        return
        log "unreachable"
      }
    }
    """

    {:ok, %AST.Program{declarations: [rule]}} = Anemos.Parser.parse(input)
    [%AST.When{body: [%AST.Return{} = r, %AST.Log{}]}] = rule.body
    assert r.value == nil
  end

  test "parses done" do
    input = """
    rule r {
      when EV {
        done
      }
    }
    """

    {:ok, %AST.Program{declarations: [rule]}} = Anemos.Parser.parse(input)
    [%AST.When{body: [%AST.Done{}]}] = rule.body
  end

  test "parses nextevent with target" do
    input = """
    rule r {
      when EV {
        nextevent OTHER_HANDLER
      }
    }
    """

    {:ok, %AST.Program{declarations: [rule]}} = Anemos.Parser.parse(input)
    [%AST.When{body: [%AST.NextEvent{} = ne]}] = rule.body
    assert ne.target == "OTHER_HANDLER"
  end

  test "parses nextrule with target" do
    input = """
    rule r {
      when EV {
        nextrule other-rule
      }
    }
    """

    {:ok, %AST.Program{declarations: [rule]}} = Anemos.Parser.parse(input)
    [%AST.When{body: [%AST.NextRule{} = nr]}] = rule.body
    assert nr.target == "other-rule"
  end

  test "parses nextrule with block args" do
    input = """
    rule r {
      when EV {
        nextrule other-rule with { key: "value" }
      }
    }
    """

    {:ok, %AST.Program{declarations: [rule]}} = Anemos.Parser.parse(input)
    [%AST.When{body: [%AST.NextRule{} = nr]}] = rule.body
    assert nr.target == "other-rule"
    assert %AST.BlockArgs{} = nr.args
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/anemos/flow_control_test.exs --trace`
Expected: FAIL — parser hits "Unexpected token" on `return`, `done`, `nextevent`, `nextrule`.

- [ ] **Step 3: Add parser functions for flow control**

Add to `parse_statement` dispatch in `lib/anemos/parser.ex`:

```elixir
  defp parse_statement([{:keyword, _, :return} | rest]), do: parse_return(rest)
  defp parse_statement([{:keyword, _, :done} | rest]), do: parse_done(rest)
  defp parse_statement([{:keyword, _, :nextevent} | rest]), do: parse_nextevent(rest)
  defp parse_statement([{:keyword, _, :nextrule} | rest]), do: parse_nextrule(rest)
```

Add the parsing functions:

```elixir
  # --- Return ---

  defp parse_return([{:rbrace, _, _} | _] = tokens) do
    line = token_line(hd(tokens))
    {:ok, %AST.Return{value: nil, line: line}, tokens}
  end

  defp parse_return([{:keyword, _, next_kw} | _] = tokens)
       when next_kw in [:when, :if, :at, :let, :set, :log, :emit, :demand, :return, :done,
                         :nextevent, :nextrule, :while, :for, :each, :every, :foreach, :else, :elseif] do
    line = token_line(hd(tokens))
    {:ok, %AST.Return{value: nil, line: line}, tokens}
  end

  defp parse_return(tokens) do
    line = token_line(hd(tokens))

    case parse_expression(tokens) do
      {:ok, expr, rest} ->
        {:ok, %AST.Return{value: expr, line: line}, rest}

      {:error, _} ->
        {:ok, %AST.Return{value: nil, line: line}, tokens}
    end
  end

  # --- Done ---

  defp parse_done(tokens) do
    line = case tokens do
      [{_, meta, _} | _] -> meta[:line]
      [] -> nil
    end
    {:ok, %AST.Done{line: line}, tokens}
  end

  # --- NextEvent ---

  defp parse_nextevent([{:module_id, meta, target} | rest]) do
    {args, rest} = parse_optional_with(rest)
    {:ok, %AST.NextEvent{target: target, args: args, line: meta[:line]}, rest}
  end

  defp parse_nextevent([{:identifier, meta, target} | rest]) do
    {args, rest} = parse_optional_with(rest)
    {:ok, %AST.NextEvent{target: target, args: args, line: meta[:line]}, rest}
  end

  defp parse_nextevent([{_, meta, _} | _]) do
    {:error, "Expected event target after 'nextevent' on line #{meta[:line]}"}
  end

  defp parse_nextevent([]) do
    {:error, "Expected event target after 'nextevent' but got end of input"}
  end

  # --- NextRule ---

  defp parse_nextrule([{:identifier, meta, target} | rest]) do
    {args, rest} = parse_optional_with(rest)
    {:ok, %AST.NextRule{target: target, args: args, line: meta[:line]}, rest}
  end

  defp parse_nextrule([{_, meta, _} | _]) do
    {:error, "Expected rule name after 'nextrule' on line #{meta[:line]}"}
  end

  defp parse_nextrule([]) do
    {:error, "Expected rule name after 'nextrule' but got end of input"}
  end

  defp parse_optional_with([{:keyword, _, :with}, {:lbrace, meta, _} | rest]) do
    case parse_block_args(rest, []) do
      {:ok, pairs, rest} ->
        with {:ok, rest} <- expect(rest, :rbrace) do
          {%AST.BlockArgs{pairs: pairs, line: meta[:line]}, rest}
        end

      {:error, _} ->
        {nil, rest}
    end
  end

  defp parse_optional_with(tokens), do: {nil, tokens}

  defp parse_block_args([{:rbrace, _, _} | _] = tokens, acc), do: {:ok, Enum.reverse(acc), tokens}

  defp parse_block_args([{:identifier, _, key}, {:operator, _, :":"} | rest], acc) do
    case parse_expression(rest) do
      {:ok, value, rest} -> parse_block_args(rest, [{key, value} | acc])
      {:error, _} = err -> err
    end
  end

  defp parse_block_args([{_, meta, _} | _], _acc) do
    {:error, "Expected 'key: value' in block args on line #{meta[:line]}"}
  end
```

Note: The `":"` operator token — verify the lexer emits `:` as `{:operator, _, :":"}`. If it uses a different token type, adjust accordingly. The key-value separator in block args may need to match how the lexer tokenizes `key: value` pairs. Check if named args in commands already handle this pattern and reuse that approach.

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/anemos/flow_control_test.exs --trace`
Expected: all tests pass.

- [ ] **Step 5: Run full test suite for regressions**

Run: `mix test --trace`
Expected: only the 3 pre-existing NLD failures.

- [ ] **Step 6: Commit**

```bash
git add lib/anemos/parser.ex test/anemos/flow_control_test.exs
git commit -m "feat: parse return, done, nextevent, nextrule flow control"
```

---

### Task 4: Compile loops (while, for, each, every, foreach)

**Files:**
- Modify: `lib/anemos/compiler.ex:296-304` (`eval_body`), `lib/anemos/compiler.ex:384` (catch-all `eval_statement`)
- Test: `test/anemos/loop_test.exs`

- [ ] **Step 1: Write the failing compiler tests**

Add to `test/anemos/loop_test.exs`:

```elixir
  # --- Compiler tests ---

  test "while loop compiles and executes" do
    input = """
    rule r {
      when EV {
        set count = 3
        while $count > 0 {
          log $count
          set count = $count - 1
        }
      }
    }
    """

    {:ok, results} = Anemos.run(input, event: "EV")
    log_values = for %{type: :log, value: v} <- results, do: v
    assert log_values == [3, 2, 1]
  end

  test "for-in loop iterates over list" do
    input = """
    rule r {
      when EV {
        for x in ?items {
          log @x
        }
      }
    }
    """

    context = %{context_data: %{"items" => [1, 2, 3]}}
    {:ok, results} = Anemos.run(input, event: "EV", context: context)
    log_values = for %{type: :log, value: v} <- results, do: v
    assert log_values == [1, 2, 3]
  end

  test "while loop with zero iterations produces no ops" do
    input = """
    rule r {
      when EV {
        set count = 0
        while $count > 0 {
          log "never"
        }
      }
    }
    """

    {:ok, results} = Anemos.run(input, event: "EV")
    assert results == []
  end

  test "while loop safety limit prevents infinite loops" do
    input = """
    rule r {
      when EV {
        while true {
          log "infinite"
        }
      }
    }
    """

    {:ok, results} = Anemos.run(input, event: "EV")
    log_values = for %{type: :log, value: v} <- results, do: v
    assert length(log_values) == 10_000
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/anemos/loop_test.exs --trace`
Expected: FAIL — the catch-all `eval_statement(_other, _context, bindings)` silently drops `While` and `For` nodes.

- [ ] **Step 3: Add eval_statement clauses for loops**

Add to `lib/anemos/compiler.ex` before the catch-all `eval_statement`:

```elixir
  @while_limit 10_000

  defp eval_statement(%AST.While{condition: condition, body: body}, context, bindings) do
    {ops, bindings} = eval_while(condition, body, context, bindings, [], 0)
    {ops, bindings}
  end

  defp eval_while(condition, body, context, bindings, ops_acc, iteration)
       when iteration >= @while_limit do
    {ops_acc, bindings}
  end

  defp eval_while(condition, body, context, bindings, ops_acc, iteration) do
    if eval_condition(condition, context, bindings) do
      {new_ops, new_bindings} = eval_body(body, context, bindings)
      eval_while(condition, body, context, new_bindings, ops_acc ++ new_ops, iteration + 1)
    else
      {ops_acc, bindings}
    end
  end

  defp eval_statement(%AST.For{var: var, iterable: iterable, body: body}, context, bindings) do
    collection = resolve_iterable(iterable, context, bindings)

    {ops, bindings} =
      Enum.reduce(collection, {[], bindings}, fn item, {ops_acc, bindings_acc} ->
        iter_bindings = Map.put(bindings_acc, {:let, var}, item)
        {new_ops, new_bindings} = eval_body(body, context, iter_bindings)
        # Drop the loop variable from bindings, keep set bindings
        cleaned = Map.delete(new_bindings, {:let, var})
        {ops_acc ++ new_ops, cleaned}
      end)

    {ops, bindings}
  end

  defp resolve_iterable(nil, _context, _bindings), do: []

  defp resolve_iterable(%AST.Command{} = cmd, context, bindings) do
    resolved = resolve_expr(cmd, context, bindings)
    List.wrap(resolved)
  end

  defp resolve_iterable(expr, context, bindings) do
    result = resolve_expr(expr, context, bindings)
    List.wrap(result)
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/anemos/loop_test.exs --trace`
Expected: all loop tests pass.

- [ ] **Step 5: Run full test suite for regressions**

Run: `mix test --trace`
Expected: only the 3 pre-existing NLD failures.

- [ ] **Step 6: Commit**

```bash
git add lib/anemos/compiler.ex test/anemos/loop_test.exs
git commit -m "feat: compile while and for/each/every/foreach loops"
```

---

### Task 5: Compile return and done (early exit from handlers)

**Files:**
- Modify: `lib/anemos/compiler.ex:280-303` (`build_handler` and `eval_body`)
- Test: `test/anemos/flow_control_test.exs`

Early exit uses throw/catch. `return` and `done` throw tagged tuples. `build_handler` catches them and returns the accumulated ops. `eval_body` uses `Enum.reduce_while` to propagate the throw through nested structures.

- [ ] **Step 1: Write the failing compiler tests**

Add to `test/anemos/flow_control_test.exs`:

```elixir
  # --- Compiler tests ---

  test "return stops execution and discards subsequent ops" do
    input = """
    rule r {
      when EV {
        log "before"
        return
        log "after"
      }
    }
    """

    {:ok, results} = Anemos.run(input, event: "EV")
    log_values = for %{type: :log, value: v} <- results, do: v
    assert log_values == ["before"]
  end

  test "done stops execution" do
    input = """
    rule r {
      when EV {
        log "before"
        done
        log "after"
      }
    }
    """

    {:ok, results} = Anemos.run(input, event: "EV")
    log_values = for %{type: :log, value: v} <- results, do: v
    assert log_values == ["before"]
  end

  test "return inside if block exits the handler" do
    input = """
    rule r {
      when EV {
        if true {
          log "in-if"
          return
        }
        log "after-if"
      }
    }
    """

    {:ok, results} = Anemos.run(input, event: "EV")
    log_values = for %{type: :log, value: v} <- results, do: v
    assert log_values == ["in-if"]
  end

  test "return inside while loop exits the handler" do
    input = """
    rule r {
      when EV {
        set i = 0
        while true {
          set i = $i + 1
          if $i == 3 {
            return
          }
          log $i
        }
        log "unreachable"
      }
    }
    """

    {:ok, results} = Anemos.run(input, event: "EV")
    log_values = for %{type: :log, value: v} <- results, do: v
    assert log_values == [1, 2]
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/anemos/flow_control_test.exs --trace`
Expected: FAIL — `return` and `done` are silently dropped by the catch-all, execution continues.

- [ ] **Step 3: Refactor build_handler and eval_body, add return/done eval_statement**

Modify `build_handler` in `lib/anemos/compiler.ex` to catch flow control throws:

```elixir
  defp build_handler(body) do
    fn _event_name, context, persistent_bindings ->
      {ops, final_bindings} =
        try do
          eval_body(body, context, persistent_bindings)
        catch
          {:anemos_return, ops, bindings} -> {ops, bindings}
          {:anemos_done, ops, bindings} -> {ops, bindings}
          {:anemos_nextevent, target, ops, bindings} ->
            {ops ++ [%{type: :nextevent, target: target}], bindings}
          {:anemos_nextrule, target, args, ops, bindings} ->
            {ops ++ [%{type: :nextrule, target: target, args: args}], bindings}
        end

      updated_persistent =
        final_bindings
        |> Enum.filter(fn {{:set, _}, _} -> true; _ -> false end)
        |> Map.new()

      {:ok, ops, updated_persistent}
    end
  end
```

Refactor `eval_body` to accumulate ops so throws can include them:

```elixir
  defp eval_body(statements, context, bindings) do
    {ops_rev, final_bindings} =
      Enum.reduce(statements, {[], bindings}, fn stmt, {ops_acc, bindings_acc} ->
        {new_ops, new_bindings} = eval_statement(stmt, context, bindings_acc)
        {Enum.reverse(new_ops) ++ ops_acc, new_bindings}
      end)

    {Enum.reverse(ops_rev), final_bindings}
  end
```

Note: `eval_body` itself doesn't change — the throws propagate up through `Enum.reduce` and are caught by `build_handler`. This works because `Enum.reduce` doesn't catch throws.

Add `eval_statement` clauses for return and done:

```elixir
  defp eval_statement(%AST.Return{}, _context, bindings) do
    throw({:anemos_return, :acc, bindings})
  end

  defp eval_statement(%AST.Done{}, _context, bindings) do
    throw({:anemos_done, :acc, bindings})
  end
```

The tricky part: when `return`/`done` throw, the ops accumulated *so far* by `eval_body`'s `Enum.reduce` are lost because the reduce is interrupted. We need to track accumulated ops at the throw site.

Better approach — modify `eval_body` to use a process dictionary key to track accumulated ops:

```elixir
  defp eval_body(statements, context, bindings) do
    prev_ops = Process.get(:anemos_accumulated_ops, [])

    {ops_rev, final_bindings} =
      Enum.reduce(statements, {[], bindings}, fn stmt, {ops_acc, bindings_acc} ->
        # Update accumulated ops before each statement so throws capture them
        Process.put(:anemos_accumulated_ops, prev_ops ++ Enum.reverse(ops_acc))
        {new_ops, new_bindings} = eval_statement(stmt, context, bindings_acc)
        {Enum.reverse(new_ops) ++ ops_acc, new_bindings}
      end)

    Process.put(:anemos_accumulated_ops, prev_ops)
    {Enum.reverse(ops_rev), final_bindings}
  end
```

And the throw handlers read from the process dictionary:

```elixir
  defp eval_statement(%AST.Return{}, _context, bindings) do
    ops = Process.get(:anemos_accumulated_ops, [])
    throw({:anemos_return, ops, bindings})
  end

  defp eval_statement(%AST.Done{}, _context, bindings) do
    ops = Process.get(:anemos_accumulated_ops, [])
    throw({:anemos_done, ops, bindings})
  end
```

Also update `eval_while` to handle throws — the throw propagates naturally since `eval_while` calls `eval_body`, and `eval_body` updates the process dictionary. No changes needed to `eval_while`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/anemos/flow_control_test.exs --trace`
Expected: all tests pass.

- [ ] **Step 5: Run full test suite for regressions**

Run: `mix test --trace`
Expected: only the 3 pre-existing NLD failures.

- [ ] **Step 6: Commit**

```bash
git add lib/anemos/compiler.ex test/anemos/flow_control_test.exs
git commit -m "feat: compile return and done with early exit via throw/catch"
```

---

### Task 6: Compile nextevent and nextrule (dispatcher integration)

**Files:**
- Modify: `lib/anemos/compiler.ex` (eval_statement for NextEvent/NextRule — already wired in build_handler from Task 5)
- Modify: `lib/anemos/runtime/dispatcher.ex:219-257` (`dispatch_to_rules`), `lib/anemos/runtime/dispatcher.ex:306-373` (`execute_op`)
- Test: `test/anemos/flow_control_test.exs`

- [ ] **Step 1: Write the failing end-to-end tests**

Add to `test/anemos/flow_control_test.exs`:

```elixir
  # --- Dispatcher integration tests ---

  test "nextrule dispatches to another rule" do
    input = """
    rule first {
      when EV {
        log "first"
        nextrule second
      }
    }

    rule second {
      when NEXTRULE_second {
        log "second"
      }
    }
    """

    {:ok, results} = Anemos.run(input, event: "EV")
    log_values = for %{type: :log, value: v} <- results, do: v
    assert "first" in log_values
    assert "second" in log_values
  end

  test "nextevent re-enters same rule at different when block" do
    input = """
    rule multi {
      when START {
        log "start"
        nextevent STEP_TWO
      }

      when STEP_TWO {
        log "step two"
      }
    }
    """

    {:ok, results} = Anemos.run(input, event: "START")
    log_values = for %{type: :log, value: v} <- results, do: v
    assert "start" in log_values
    assert "step two" in log_values
  end

  test "nextrule stops executing current handler after the nextrule op" do
    input = """
    rule first {
      when EV {
        log "before"
        nextrule second
        log "after-nextrule"
      }
    }

    rule second {
      when NEXTRULE_second {
        log "second"
      }
    }
    """

    {:ok, results} = Anemos.run(input, event: "EV")
    log_values = for %{type: :log, value: v} <- results, do: v
    assert "before" in log_values
    assert "second" in log_values
    refute "after-nextrule" in log_values
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/anemos/flow_control_test.exs --trace`
Expected: FAIL — dispatcher doesn't know about `:nextevent` or `:nextrule` operation types.

- [ ] **Step 3: Add eval_statement for NextEvent and NextRule**

Add to `lib/anemos/compiler.ex` before the catch-all:

```elixir
  defp eval_statement(%AST.NextEvent{target: target}, _context, bindings) do
    ops = Process.get(:anemos_accumulated_ops, [])
    throw({:anemos_nextevent, target, ops, bindings})
  end

  defp eval_statement(%AST.NextRule{target: target, args: args}, _context, bindings) do
    resolved_args = case args do
      %AST.BlockArgs{pairs: pairs} ->
        Map.new(pairs, fn {k, v} -> {k, v} end)
      _ -> nil
    end
    ops = Process.get(:anemos_accumulated_ops, [])
    throw({:anemos_nextrule, target, resolved_args, ops, bindings})
  end
```

- [ ] **Step 4: Add execute_op clauses for nextevent and nextrule in dispatcher**

Add to `lib/anemos/runtime/dispatcher.ex` in `execute_op`:

```elixir
  defp execute_op(%{type: :nextevent, target: target}, context, state) do
    {results, _state} = dispatch_to_rules(target, context, state)
    results
  end

  defp execute_op(%{type: :nextrule, target: target}, context, state) do
    synthetic_event = "NEXTRULE_#{target}"
    {results, _state} = dispatch_to_rules(synthetic_event, context, state)
    results
  end
```

For `nextrule`, the target rule needs to subscribe to `NEXTRULE_<name>`. Update `compile_rule` to automatically add a `NEXTRULE_<name>` subscription to every compiled rule:

Actually, a simpler approach: `nextrule` dispatches a synthetic event `NEXTRULE_<target>`. The target rule just needs a `when NEXTRULE_<name>` block. This is consistent with how conditions work (`CONDITION_<name>`). The test above already uses this pattern. No automatic subscription needed — the user writes the `when NEXTRULE_second` block explicitly.

Wait, that's bad UX. Let me reconsider: the spec says `nextrule other-rule` should dispatch to `other-rule`'s pipeline. The simplest approach that matches the spec: `nextrule` re-dispatches to the target rule directly by name, not via a synthetic event.

Revise the dispatcher to look up rules by name:

```elixir
  defp execute_op(%{type: :nextrule, target: target}, context, state) do
    matching = Enum.filter(state.rules, fn rule -> rule.name == target end)

    Enum.flat_map(matching, fn rule ->
      persistent = Map.get(state.rule_bindings, rule.name, %{})
      case safe_handle(rule, "nextrule:#{target}", context, persistent) do
        {:ok, ops, _new_persistent} ->
          Enum.flat_map(ops, fn op -> List.wrap(execute_op(op, context, state)) end)
        {:error, reason} ->
          [{:error, {:handler_crash, rule.name, reason}}]
      end
    end)
  end

  defp execute_op(%{type: :nextevent, target: target}, context, state) do
    {results, _state} = dispatch_to_rules(target, context, state)
    results
  end
```

Update the test for nextrule — the target rule uses a regular `when` block, and `nextrule` dispatches to it directly:

```elixir
  test "nextrule dispatches to another rule" do
    input = """
    rule first {
      when EV {
        log "first"
        nextrule second
      }
    }

    rule second {
      when ANY {
        log "second"
      }
    }
    """

    {:ok, results} = Anemos.run(input, event: "EV")
    log_values = for %{type: :log, value: v} <- results, do: v
    assert "first" in log_values
    assert "second" in log_values
  end
```

Hmm, but this means `nextrule` bypasses subscription matching and calls the handler directly. That's the right semantics — `nextrule` is a direct invocation, not an event dispatch.

Update the nextrule test to not require a specific `when` block:

```elixir
  test "nextrule dispatches to another rule" do
    input = """
    rule first {
      when EV {
        log "first"
        nextrule second
      }
    }

    rule second {
      when OTHER {
        log "second"
      }
    }
    """

    {:ok, results} = Anemos.run(input, event: "EV")
    log_values = for %{type: :log, value: v} <- results, do: v
    assert "first" in log_values
    assert "second" in log_values
  end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/anemos/flow_control_test.exs --trace`
Expected: all tests pass.

- [ ] **Step 6: Run full test suite for regressions**

Run: `mix test --trace`
Expected: only the 3 pre-existing NLD failures.

- [ ] **Step 7: Commit**

```bash
git add lib/anemos/compiler.ex lib/anemos/runtime/dispatcher.ex test/anemos/flow_control_test.exs
git commit -m "feat: compile nextevent and nextrule with dispatcher integration"
```

---

### Task 7: Fix NLD timezone test failures

While we're here, fix the 3 pre-existing NLD test failures caused by UTC vs local time mismatch.

**Files:**
- Modify: `lib/anemos/runtime/nld.ex` or `test/anemos/nld_test.exs`

- [ ] **Step 1: Read the NLD resolver to identify the mismatch**

Read `lib/anemos/runtime/nld.ex` and `test/anemos/nld_test.exs` to understand where UTC vs local diverges.

- [ ] **Step 2: Fix the timezone mismatch**

The tests use `Date.utc_today()` but the resolver likely uses `Date.utc_today()` at a different moment, or uses local time. The fix should make both the resolver and the tests use the same time basis. If the resolver uses `NaiveDateTime.local_now/0`, switch the tests to `Date.utc_today() |> ...` to match, or vice versa. The simplest correct fix: make the resolver consistently use UTC and ensure the tests use UTC.

- [ ] **Step 3: Run the NLD tests**

Run: `mix test test/anemos/nld_test.exs --trace`
Expected: all pass.

- [ ] **Step 4: Run full test suite**

Run: `mix test --trace`
Expected: 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/anemos/runtime/nld.ex test/anemos/nld_test.exs
git commit -m "fix: NLD timezone mismatch — use consistent UTC basis"
```

---

### Task 8: End-to-end integration tests

**Files:**
- Modify: `test/anemos/pipeline_test.exs`

- [ ] **Step 1: Write end-to-end integration tests combining loops and flow control**

Add to `test/anemos/pipeline_test.exs`:

```elixir
  test "end-to-end: for loop with return exits early" do
    input = """
    rule scan {
      when SCAN {
        for item in ?items {
          if @item == "stop" {
            return
          }
          log @item
        }
      }
    }
    """

    context = %{context_data: %{"items" => ["a", "b", "stop", "c"]}}
    {:ok, results} = Anemos.run(input, event: "SCAN", context: context)
    log_values = for %{type: :log, value: v} <- results, do: v
    assert log_values == ["a", "b"]
  end

  test "end-to-end: while loop with set persistence across firings" do
    input = """
    rule counter {
      when TICK {
        set n = $n + 1
        log $n
      }
    }
    """

    {:ok, ast} = Anemos.Parser.parse(input)
    {:ok, compiled} = Anemos.Compiler.compile(ast)
    {:ok, registry} = Anemos.Runtime.ModuleRegistry.start_link([])
    {:ok, dispatcher} = Anemos.Runtime.Dispatcher.start_link(
      rules: compiled.rules,
      registry: registry
    )

    Anemos.Runtime.Dispatcher.dispatch(dispatcher, "TICK")
    results = Anemos.Runtime.Dispatcher.dispatch(dispatcher, "TICK")
    log_values = for {:ok, %{type: :log, value: v}} <- results, do: v

    GenServer.stop(dispatcher)
    Agent.stop(registry)

    # Second firing should see $n persisted from first
    assert log_values == [2]
  end

  test "end-to-end: nextevent chains within same rule" do
    input = """
    rule pipeline {
      when START {
        log "phase-1"
        nextevent PHASE_TWO
      }

      when PHASE_TWO {
        log "phase-2"
      }
    }
    """

    {:ok, results} = Anemos.run(input, event: "START")
    log_values = for %{type: :log, value: v} <- results, do: v
    assert "phase-1" in log_values
    assert "phase-2" in log_values
  end
```

- [ ] **Step 2: Run integration tests**

Run: `mix test test/anemos/pipeline_test.exs --trace`
Expected: all pass.

- [ ] **Step 3: Run full test suite — zero failures required**

Run: `mix test --trace`
Expected: 0 failures.

- [ ] **Step 4: Commit**

```bash
git add test/anemos/pipeline_test.exs
git commit -m "test: end-to-end integration tests for loops and flow control"
```
