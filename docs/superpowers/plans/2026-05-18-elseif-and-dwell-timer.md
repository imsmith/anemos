# `elseif` and `for <duration>` Dwell Timer — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Verify and test `elseif` chains end-to-end, and wire up runtime semantics for `when EVENT for <duration> { ... }` as a per-(rule, event) dwell-timer state machine.

**Architecture:** `elseif` is a verification-only task — parser and compiler already handle it via recursive `If` nodes; we just need test coverage. The dwell timer extracts duration→ms conversion into a shared `Anemos.Runtime.Duration` module, attaches `dwell_duration_ms` to `CompiledRule` at compile time, and adds a state-machine path in the `Dispatcher` (listening → armed → activated → listening) keyed by `(rule_name, event_name)` in the existing `rule_bindings` map. Timer messages flow through a new `handle_info({:dwell_fire, ...})` clause.

**Tech Stack:** Elixir 1.19, OTP 26+, ExUnit, NimbleParsec (existing). No new dependencies.

**Spec:** `docs/superpowers/specs/2026-05-18-elseif-and-dwell-timer-design.md`

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `test/anemos/elseif_test.exs` | Create | End-to-end `if/elseif/else` chain coverage |
| `lib/anemos/runtime/duration.ex` | Create | Shared `to_ms/1` helper for duration tuples |
| `test/anemos/runtime/duration_test.exs` | Create | Unit tests for duration conversion |
| `lib/anemos/runtime/scheduler.ex` | Modify | Delegate to new Duration module |
| `lib/anemos/compiler.ex` | Modify | Add `dwell_duration_ms` to CompiledRule; reject zero-duration |
| `test/anemos/compiler_test.exs` | Modify | Add dwell_duration_ms compile tests |
| `lib/anemos/runtime/dispatcher.ex` | Modify | Dwell state machine + `handle_info({:dwell_fire, ...})` |
| `test/anemos/dwell_timer_test.exs` | Create | State machine unit + integration tests |
| `TODO.md` | Modify | Move `elseif` and `for <duration>` out of the partial-implementation list |
| `~/.claude/projects/-home-imsmith-github-anemos/memory/project_status.md` | Modify | Update status memory |

---

## Task 1: `elseif` end-to-end test coverage

**Files:**
- Create: `test/anemos/elseif_test.exs`

- [ ] **Step 1: Write the failing test file**

Create `test/anemos/elseif_test.exs`:

```elixir
defmodule Anemos.ElseifTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Anemos.{Parser, Compiler, AST}

  # --- Parser tests ---

  test "parses if/elseif chain (no else)" do
    input = """
    rule r {
      when EV {
        if "a" eq "b" {
          log "first"
        } elseif "c" eq "c" {
          log "second"
        }
      }
    }
    """

    {:ok, %AST.Program{declarations: [rule]}} = Parser.parse(input)
    [%AST.When{body: [%AST.If{} = outer]}] = rule.body
    assert [%AST.If{} = inner] = outer.else_body
    assert [%AST.Log{expression: %AST.Literal{value: "second"}}] = inner.body
  end

  test "parses if/elseif/else chain" do
    input = """
    rule r {
      when EV {
        if "a" eq "b" {
          log "first"
        } elseif "c" eq "d" {
          log "second"
        } else {
          log "third"
        }
      }
    }
    """

    {:ok, %AST.Program{declarations: [rule]}} = Parser.parse(input)
    [%AST.When{body: [%AST.If{} = outer]}] = rule.body
    assert [%AST.If{} = inner] = outer.else_body
    assert [%AST.Log{expression: %AST.Literal{value: "third"}}] = inner.else_body
  end

  test "parses long elseif chain (four arms)" do
    input = """
    rule r {
      when EV {
        if "a" eq "b" {
          log "1"
        } elseif "a" eq "c" {
          log "2"
        } elseif "a" eq "d" {
          log "3"
        } else {
          log "4"
        }
      }
    }
    """

    {:ok, _ast} = Parser.parse(input)
  end

  test "parses two-token 'else if' form equivalently" do
    input = """
    rule r {
      when EV {
        if "a" eq "b" {
          log "first"
        } else if "c" eq "c" {
          log "second"
        }
      }
    }
    """

    {:ok, %AST.Program{declarations: [rule]}} = Parser.parse(input)
    [%AST.When{body: [%AST.If{} = outer]}] = rule.body
    assert [%AST.If{}] = outer.else_body
  end

  # --- End-to-end execution tests ---

  test "elseif fires when first branch is false and elseif is true" do
    input = """
    rule r {
      when EV {
        if "a" eq "b" {
          log "first"
        } elseif "c" eq "c" {
          log "second"
        }
      }
    }
    """

    {:ok, results} = Anemos.run(input, event: "EV")
    log_values = for %{type: :log, value: v} <- results, do: v
    assert log_values == ["second"]
  end

  test "first branch wins over elseif when both true" do
    input = """
    rule r {
      when EV {
        if "a" eq "a" {
          log "first"
        } elseif "b" eq "b" {
          log "second"
        }
      }
    }
    """

    {:ok, results} = Anemos.run(input, event: "EV")
    log_values = for %{type: :log, value: v} <- results, do: v
    assert log_values == ["first"]
  end

  test "else fires when all preceding branches false" do
    input = """
    rule r {
      when EV {
        if "a" eq "b" {
          log "first"
        } elseif "a" eq "c" {
          log "second"
        } else {
          log "third"
        }
      }
    }
    """

    {:ok, results} = Anemos.run(input, event: "EV")
    log_values = for %{type: :log, value: v} <- results, do: v
    assert log_values == ["third"]
  end

  test "mid-chain match: only the matching arm fires" do
    input = """
    rule r {
      when EV {
        if "a" eq "b" {
          log "1"
        } elseif "a" eq "c" {
          log "2"
        } elseif "a" eq "a" {
          log "3"
        } elseif "a" eq "d" {
          log "4"
        } else {
          log "5"
        }
      }
    }
    """

    {:ok, results} = Anemos.run(input, event: "EV")
    log_values = for %{type: :log, value: v} <- results, do: v
    assert log_values == ["3"]
  end

  test "no else, all-false chain produces no log ops" do
    input = """
    rule r {
      when EV {
        if "a" eq "b" {
          log "1"
        } elseif "a" eq "c" {
          log "2"
        }
      }
    }
    """

    {:ok, results} = Anemos.run(input, event: "EV")
    log_values = for %{type: :log, value: v} <- results, do: v
    assert log_values == []
  end

  test "compiler walks elseif as nested If" do
    input = """
    rule r {
      when EV {
        if "a" eq "b" {
          log "first"
        } elseif "c" eq "c" {
          log "second"
        }
      }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, %{rules: [compiled]}} = Compiler.compile(ast)
    {:ok, ops, _} = compiled.handler.("EV", %{}, %{})
    assert [%{type: :log, value: "second"}] = ops
  end
end
```

- [ ] **Step 2: Run the tests to see what passes and what fails**

Run: `mix test test/anemos/elseif_test.exs`

Expected: most tests should pass (parser+compiler already wire elseif correctly). If any fail, that's the gap to fix in step 3. If all pass, skip to step 4.

- [ ] **Step 3: If any tests fail, fix the parser/compiler**

Likely failure surfaces:
- `parse_optional_else` at `lib/anemos/parser.ex:925` for the `:elseif` clause — verify it returns the `If` node wrapped in a list as the parent's `else_body`. If it returns the bare node, wrap it in `[if_node]`.
- The `:else` clause at `parser.ex:900` handles `else if` — verify it returns `{[if_node], rest}` for that sub-case.

After any fix, re-run: `mix test test/anemos/elseif_test.exs`
Expected: PASS.

- [ ] **Step 4: Run the full test suite to confirm no regressions**

Run: `mix test`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add test/anemos/elseif_test.exs
# Add any parser/compiler files if step 3 modified them
git commit -m "test: end-to-end coverage for elseif chains"
```

---

## Task 2: Extract `Duration.to_ms/1` helper

**Files:**
- Create: `lib/anemos/runtime/duration.ex`
- Create: `test/anemos/runtime/duration_test.exs`
- Modify: `lib/anemos/runtime/scheduler.ex`

- [ ] **Step 1: Write the failing test**

Create `test/anemos/runtime/duration_test.exs`:

```elixir
defmodule Anemos.Runtime.DurationTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Anemos.Runtime.Duration

  test "milliseconds passthrough" do
    assert Duration.to_ms({500, :ms}) == 500
  end

  test "seconds" do
    assert Duration.to_ms({3, :s}) == 3_000
    assert Duration.to_ms({3, :seconds}) == 3_000
  end

  test "minutes" do
    assert Duration.to_ms({2, :min}) == 120_000
    assert Duration.to_ms({2, :minutes}) == 120_000
  end

  test "hours" do
    assert Duration.to_ms({1, :h}) == 3_600_000
    assert Duration.to_ms({1, :hours}) == 3_600_000
  end

  test "days" do
    assert Duration.to_ms({2, :d}) == 172_800_000
    assert Duration.to_ms({2, :days}) == 172_800_000
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/anemos/runtime/duration_test.exs`
Expected: FAIL with `(UndefinedFunctionError) function Anemos.Runtime.Duration.to_ms/1 is undefined`.

- [ ] **Step 3: Implement the Duration module**

Create `lib/anemos/runtime/duration.ex`:

```elixir
defmodule Anemos.Runtime.Duration do
  @moduledoc """
  Converts duration tuples (e.g., `{5, :min}`) to milliseconds.

  Supported units: `:ms`, `:s`, `:seconds`, `:min`, `:minutes`,
  `:h`, `:hours`, `:d`, `:days`.
  """

  @doc """
  Converts a duration tuple to milliseconds.

  ## Examples

      iex> Anemos.Runtime.Duration.to_ms({5, :min})
      300_000

      iex> Anemos.Runtime.Duration.to_ms({2, :s})
      2_000
  """
  @spec to_ms({non_neg_integer(), atom()}) :: non_neg_integer()
  def to_ms({amount, :ms}), do: amount
  def to_ms({amount, :s}), do: amount * 1_000
  def to_ms({amount, :seconds}), do: amount * 1_000
  def to_ms({amount, :min}), do: amount * 60_000
  def to_ms({amount, :minutes}), do: amount * 60_000
  def to_ms({amount, :h}), do: amount * 3_600_000
  def to_ms({amount, :hours}), do: amount * 3_600_000
  def to_ms({amount, :d}), do: amount * 86_400_000
  def to_ms({amount, :days}), do: amount * 86_400_000
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/anemos/runtime/duration_test.exs`
Expected: PASS, 5 tests.

- [ ] **Step 5: Delegate scheduler.ex to the new module**

Edit `lib/anemos/runtime/scheduler.ex`. Replace the `duration_to_ms/1` private function block (currently at lines 129-137) with a single delegation:

```elixir
  defp duration_to_ms(dur), do: Anemos.Runtime.Duration.to_ms(dur)
```

Leave the call sites (e.g., `start_timer/1`'s `ms = duration_to_ms(dur)` at line 84) unchanged.

- [ ] **Step 6: Run scheduler tests to confirm no regression**

Run: `mix test test/anemos/runtime/scheduler_test.exs`
Expected: all green.

- [ ] **Step 7: Commit**

```bash
git add lib/anemos/runtime/duration.ex test/anemos/runtime/duration_test.exs lib/anemos/runtime/scheduler.ex
git commit -m "refactor: extract Duration.to_ms/1 from scheduler"
```

---

## Task 3: Add `dwell_duration_ms` to `CompiledRule`; compile `When.duration`

**Files:**
- Modify: `lib/anemos/compiler.ex`
- Modify: `test/anemos/compiler_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/anemos/compiler_test.exs` (anywhere; group with other compile-time tests):

```elixir
  # --- for <duration> compilation ---

  test "when without 'for' has nil dwell_duration_ms" do
    input = """
    rule r {
      when EV { log "go" }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, %{rules: [compiled]}} = Compiler.compile(ast)
    assert compiled.dwell_duration_ms == nil
  end

  test "when EV for 10min compiles dwell_duration_ms to 600_000" do
    input = """
    rule r {
      when EV for 10min { log "go" }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, %{rules: [compiled]}} = Compiler.compile(ast)
    assert compiled.dwell_duration_ms == 600_000
  end

  test "when EV for 500ms compiles dwell_duration_ms to 500" do
    input = """
    rule r {
      when EV for 500ms { log "go" }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, %{rules: [compiled]}} = Compiler.compile(ast)
    assert compiled.dwell_duration_ms == 500
  end

  test "for 0s is rejected at compile time" do
    input = """
    rule r {
      when EV for 0s { log "go" }
    }
    """

    {:ok, ast} = Parser.parse(input)
    assert {:error, msg} = Compiler.compile(ast)
    assert msg =~ "zero"
  end

  test "multiple when blocks, mixed for/no-for" do
    input = """
    rule r {
      when EV1 { log "a" }
      when EV2 for 5min { log "b" }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, %{rules: rules}} = Compiler.compile(ast)

    assert length(rules) == 2
    ev1_rule = Enum.find(rules, &("EV1" in &1.subscriptions))
    ev2_rule = Enum.find(rules, &("EV2" in &1.subscriptions))

    assert ev1_rule.dwell_duration_ms == nil
    assert ev2_rule.dwell_duration_ms == 300_000
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/anemos/compiler_test.exs`
Expected: 5 new failures (field doesn't exist yet; zero-rejection not implemented).

- [ ] **Step 3: Add `dwell_duration_ms` to `CompiledRule` struct**

Edit `lib/anemos/compiler.ex`. At the top of the file (lines 1-18), the `CompiledRule` struct currently is:

```elixir
defmodule Anemos.CompiledRule do
  @moduledoc """
  A compiled rule: name, event subscriptions, and a handler closure.
  ...
  """
  @enforce_keys [:name, :subscriptions, :handler]
  defstruct [:name, :subscriptions, :handler, :meta]
  ...
```

Update to add `:dwell_duration_ms`:

```elixir
defmodule Anemos.CompiledRule do
  @moduledoc """
  A compiled rule: name, event subscriptions, handler closure, and optional dwell duration.

  The handler takes `(event_name, context, persistent_bindings)` and returns
  `{:ok, [operation], updated_persistent_bindings}`. Persistent bindings hold
  `set` values that survive across firings.

  When `dwell_duration_ms` is non-nil, the rule is dispatched through the
  Dispatcher's dwell-timer state machine instead of being fired immediately.
  See `Anemos.Runtime.Dispatcher` for the state-machine semantics.
  """
  @enforce_keys [:name, :subscriptions, :handler]
  defstruct [:name, :subscriptions, :handler, :meta, :dwell_duration_ms]

  @type t :: %__MODULE__{
          name: String.t(),
          subscriptions: [String.t()],
          handler: (String.t(), map(), map() -> {:ok, [map()], map()}),
          meta: map() | nil,
          dwell_duration_ms: non_neg_integer() | nil
        }
end
```

- [ ] **Step 4: Wire `compile_rule/1` to extract and set the duration**

Edit `lib/anemos/compiler.ex`. Find the `compile_rule/1` function (around line 279). The current `when_rules` construction (around line 308) is:

```elixir
    when_rules =
      Enum.map(when_blocks, fn %AST.When{event: event, body: when_body, guard: guard} ->
        subscriptions = event_to_subscriptions(event)
        handler = build_guarded_handler(when_body, guard)
        %CompiledRule{name: name, subscriptions: subscriptions, handler: handler, meta: compiled_meta}
      end)
```

Replace with:

```elixir
    when_rules =
      Enum.map(when_blocks, fn %AST.When{event: event, body: when_body, guard: guard, duration: duration} ->
        subscriptions = event_to_subscriptions(event)
        handler = build_guarded_handler(when_body, guard)
        dwell_ms = duration_to_dwell_ms(duration)

        %CompiledRule{
          name: name,
          subscriptions: subscriptions,
          handler: handler,
          meta: compiled_meta,
          dwell_duration_ms: dwell_ms
        }
      end)
```

- [ ] **Step 5: Add `duration_to_dwell_ms/1` helper and zero-rejection**

In `lib/anemos/compiler.ex`, add these helpers near the other private helpers (e.g., near `event_to_subscriptions/1` around line 431):

```elixir
  # --- Dwell duration ---

  defp duration_to_dwell_ms(nil), do: nil

  defp duration_to_dwell_ms({0, _unit}) do
    throw({:compile_error, "for <duration>: zero duration not allowed"})
  end

  defp duration_to_dwell_ms({amount, _unit} = dur) when amount > 0 do
    Anemos.Runtime.Duration.to_ms(dur)
  end
```

- [ ] **Step 6: Catch the throw in `compile/1` and return as `{:error, msg}`**

In `lib/anemos/compiler.ex`, find the `compile/1` function (around line 115):

```elixir
  def compile(%AST.Program{declarations: declarations}) do
    result =
      Enum.reduce(declarations, %Anemos.CompilationResult{}, fn decl, acc ->
        ...
      end)

    {:ok, result}
  end
```

Wrap the body in a `try`:

```elixir
  def compile(%AST.Program{declarations: declarations}) do
    try do
      result =
        Enum.reduce(declarations, %Anemos.CompilationResult{}, fn decl, acc ->
          case compile_declaration(decl) do
            {:rule, rules, schedules, inline_data, inline_queries} ->
              %{acc |
                rules: acc.rules ++ rules,
                schedules: acc.schedules ++ schedules,
                data_blocks: acc.data_blocks ++ inline_data,
                query_blocks: acc.query_blocks ++ inline_queries
              }
            {:condition, cond, schedules} ->
              %{acc | conditions: acc.conditions ++ [cond], schedules: acc.schedules ++ schedules}
            {:capability, cap} -> %{acc | capabilities: acc.capabilities ++ [cap]}
            {:data, compiled_data} -> %{acc | data_blocks: acc.data_blocks ++ [compiled_data]}
            {:query, compiled_query} -> %{acc | query_blocks: acc.query_blocks ++ [compiled_query]}
            :skip -> acc
          end
        end)

      {:ok, result}
    catch
      {:compile_error, msg} -> {:error, msg}
    end
  end
```

Also update the `@spec` line just above (around line 114) from:

```elixir
  @spec compile(AST.Program.t()) :: {:ok, Anemos.CompilationResult.t()}
```

to:

```elixir
  @spec compile(AST.Program.t()) :: {:ok, Anemos.CompilationResult.t()} | {:error, String.t()}
```

There's also a `# TODO:` comment a few lines above the `@spec` (`# TODO: Add {:error, String.t()} return when the compiler needs to reject invalid AST.`). Delete that comment — this task resolves it.

- [ ] **Step 7: Run the compiler tests**

Run: `mix test test/anemos/compiler_test.exs`
Expected: all green, including the 5 new dwell tests.

- [ ] **Step 8: Run the full test suite**

Run: `mix test`
Expected: all green. Pre-existing tests that construct `%CompiledRule{}` directly should still work — `dwell_duration_ms` defaults to `nil`.

- [ ] **Step 9: Commit**

```bash
git add lib/anemos/compiler.ex test/anemos/compiler_test.exs
git commit -m "feat: compile for-duration into CompiledRule.dwell_duration_ms"
```

---

## Task 4: Dwell-timer state machine in Dispatcher

**Files:**
- Modify: `lib/anemos/runtime/dispatcher.ex`
- Create: `test/anemos/dwell_timer_test.exs`

- [ ] **Step 1: Write the failing unit test file**

Create `test/anemos/dwell_timer_test.exs`:

```elixir
defmodule Anemos.DwellTimerTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias Anemos.{Parser, Compiler}
  alias Anemos.Runtime.{Dispatcher, ModuleRegistry}

  # Use 50ms durations for fast tests. The compiler converts integer + unit;
  # we use `for 50ms` in source.

  defp setup_runtime(source) do
    {:ok, ast} = Parser.parse(source)
    {:ok, compiled} = Compiler.compile(ast)
    {:ok, registry} = ModuleRegistry.start_link([])
    {:ok, dispatcher} = Dispatcher.start_link(rules: compiled.rules, registry: registry)
    dispatcher
  end

  defp log_values(results) do
    results
    |> List.flatten()
    |> Enum.flat_map(fn
      {:ok, %{type: :log, value: v}} -> [v]
      _ -> []
    end)
  end

  test "armed timer fires after duration with single truthy arrival" do
    import ExUnit.CaptureLog

    src = """
    rule r {
      when EV for 50ms { log "fired" }
    }
    """
    dispatcher = setup_runtime(src)

    log =
      capture_log(fn ->
        _ = Dispatcher.dispatch(dispatcher, "EV", %{})
        Process.sleep(120)
      end)

    assert log =~ "fired"
  end

  test "second truthy arrival does NOT restart the timer" do
    import ExUnit.CaptureLog

    src = """
    rule r {
      when EV for 100ms { log "fired" }
    }
    """
    dispatcher = setup_runtime(src)

    log =
      capture_log(fn ->
        t0 = System.monotonic_time(:millisecond)
        _ = Dispatcher.dispatch(dispatcher, "EV", %{})
        # 60ms in, send another arrival. If timer restarted, fire would happen
        # at t=160ms. If timer does NOT restart, fire at t=100ms.
        Process.sleep(60)
        _ = Dispatcher.dispatch(dispatcher, "EV", %{})
        # Wait until t=130ms — past the 100ms expiry, well before any 160ms.
        Process.sleep(70)
        t1 = System.monotonic_time(:millisecond)
        assert t1 - t0 >= 130 and t1 - t0 < 150
      end)

    assert log =~ "fired"
  end

  test "falsy-payload arrival in armed state cancels the timer (body never fires)" do
    import ExUnit.CaptureLog

    src = """
    rule r {
      when EV for 100ms { log "fired" }
    }
    """
    dispatcher = setup_runtime(src)

    log =
      capture_log(fn ->
        _ = Dispatcher.dispatch(dispatcher, "EV", %{})
        Process.sleep(30)
        # Falsy payload — cancels the timer.
        _ = Dispatcher.dispatch(dispatcher, "EV", %{context_data: %{"state" => false}})
        # Wait well past the original expiry.
        Process.sleep(150)
      end)

    refute log =~ "fired"
  end

  test "falsy-payload arrival in listening state is a no-op (no timer started)" do
    import ExUnit.CaptureLog

    src = """
    rule r {
      when EV for 50ms { log "fired" }
    }
    """
    dispatcher = setup_runtime(src)

    log =
      capture_log(fn ->
        _ = Dispatcher.dispatch(dispatcher, "EV", %{context_data: %{"state" => false}})
        Process.sleep(100)
      end)

    refute log =~ "fired"
  end

  test "after firing, returns to listening (can re-arm)" do
    import ExUnit.CaptureLog

    src = """
    rule r {
      when EV for 50ms { log "fired" }
    }
    """
    dispatcher = setup_runtime(src)

    log =
      capture_log(fn ->
        _ = Dispatcher.dispatch(dispatcher, "EV", %{})
        Process.sleep(80)  # fires at ~50ms
        _ = Dispatcher.dispatch(dispatcher, "EV", %{})
        Process.sleep(80)  # fires again at ~130ms total
      end)

    # Count occurrences of "fired" in the log.
    fired_count =
      log
      |> String.split("fired")
      |> length()
      |> Kernel.-(1)

    assert fired_count == 2
  end

  test "two when blocks with different events get independent dwell state" do
    import ExUnit.CaptureLog

    src = """
    rule r {
      when EV1 for 50ms { log "one" }
      when EV2 for 50ms { log "two" }
    }
    """
    dispatcher = setup_runtime(src)

    log =
      capture_log(fn ->
        _ = Dispatcher.dispatch(dispatcher, "EV1", %{})
        _ = Dispatcher.dispatch(dispatcher, "EV2", %{})
        Process.sleep(100)
      end)

    assert log =~ "one"
    assert log =~ "two"
  end

  test "non-dwell rules (no for) still fire immediately" do
    src = """
    rule r {
      when EV { log "immediate" }
    }
    """
    dispatcher = setup_runtime(src)

    results = Dispatcher.dispatch(dispatcher, "EV", %{})
    assert log_values(results) == ["immediate"]
  end
end
```

Note the first `test/2` is exploratory and unused — remove it before committing. Replace it by deleting the first `test` block; keep the rest.

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/anemos/dwell_timer_test.exs`
Expected: most fail because the dispatcher doesn't implement dwell semantics yet. The "non-dwell" test should pass.

- [ ] **Step 3: Add the dwell-timer path to the dispatcher**

Edit `lib/anemos/runtime/dispatcher.ex`. Find `dispatch_to_rules/3` (around line 340):

```elixir
  defp dispatch_to_rules(event_name, context, state) do
    matching = Map.get(state.index, event_name, [])
    event_context = Map.get(context, :context_path)

    matching
    |> Enum.filter(&context_matches?(&1, event_context))
    |> Enum.reduce({[], state}, fn rule, {results_acc, st} ->
      persistent = Map.get(st.rule_bindings, rule.name, %{})
      ...
    end)
  end
```

Add a fork at the top of the per-rule reduce body so dwell-bearing rules take a different path. Replace the body of `Enum.reduce(..., fn rule, {results_acc, st} -> ... end)` with a call to a dispatcher that picks immediate vs dwell. Final shape:

```elixir
  defp dispatch_to_rules(event_name, context, state) do
    matching = Map.get(state.index, event_name, [])
    event_context = Map.get(context, :context_path)

    matching
    |> Enum.filter(&context_matches?(&1, event_context))
    |> Enum.reduce({[], state}, fn rule, {results_acc, st} ->
      case rule.dwell_duration_ms do
        nil ->
          dispatch_immediate(rule, event_name, context, results_acc, st)

        ms when is_integer(ms) ->
          new_st = handle_dwell_event(rule, event_name, context, ms, st)
          {results_acc, new_st}
      end
    end)
  end
```

Then extract the existing per-rule logic into `dispatch_immediate/5`. Move the body that's currently inside the `Enum.reduce` (from `persistent = Map.get(...)` down through the `{:error, reason}` case) into a new private function. This is a refactor — same code, just relocated:

```elixir
  defp dispatch_immediate(rule, event_name, context, results_acc, st) do
    persistent = Map.get(st.rule_bindings, rule.name, %{})

    enriched_context =
      context
      |> Map.put(:data_store, st.data_store)
      |> Map.put(:_rule_name, rule.name)

    case safe_handle(rule, event_name, enriched_context, persistent) do
      {:ok, ops, new_persistent} ->
        new_st = put_in(st.rule_bindings[rule.name], new_persistent)
        rule_context = Map.get(rule, :meta, %{}) |> Map.get(:context_path)
        exec_context = Map.put(context, :_rule_source, {rule.name, rule_context})

        all_results =
          Enum.flat_map(ops, fn op ->
            List.wrap(execute_op(op, exec_context, new_st))
          end)

        {normal_results, emit_events} =
          Enum.split_with(all_results, fn
            {:emit_event, _, _} -> false
            _ -> true
          end)

        {emit_results, new_st} =
          Enum.reduce(emit_events, {[], new_st}, fn {:emit_event, label, op}, {acc, s} ->
            {sub_results, s} = dispatch_to_rules(label, context, s)
            {acc ++ [{:ok, op} | sub_results], s}
          end)

        {results_acc ++ normal_results ++ emit_results, new_st}

      {:error, reason} ->
        err = Comn.Errors.Registry.error!("anemos.runtime/handler_crash",
          message: "Rule #{rule.name} raised: #{inspect(reason)}")
        {results_acc ++ [{:error, err}], st}
    end
  end
```

- [ ] **Step 4: Implement the dwell state machine**

In `lib/anemos/runtime/dispatcher.ex`, add the dwell handler and helpers near the bottom of the module (before `defp triple_query_pattern/1`):

```elixir
  # --- Dwell timer state machine ---
  #
  # State per (rule_name, event_name) is stored in rule_bindings under the key
  # {:dwell, event_name} as %{state: :listening | :armed, timer_ref: ref | nil}.
  # See docs/superpowers/specs/2026-05-18-elseif-and-dwell-timer-design.md.

  defp handle_dwell_event(rule, event_name, context, ms, st) do
    truthy? = dwell_signal_truthy?(context)
    rule_state = Map.get(st.rule_bindings, rule.name, %{})
    dwell_key = {:dwell, event_name}
    current = Map.get(rule_state, dwell_key, %{state: :listening, timer_ref: nil, last_context: nil})

    new_dwell =
      case {current.state, truthy?} do
        {:listening, true} ->
          ref = Process.send_after(self(), {:dwell_fire, rule.name, event_name}, ms)
          %{state: :armed, timer_ref: ref, last_context: context}

        {:listening, false} ->
          current

        {:armed, true} ->
          # No restart — keep existing timer, update last_context.
          %{current | last_context: context}

        {:armed, false} ->
          if current.timer_ref, do: Process.cancel_timer(current.timer_ref, flush: true, info: false)
          %{state: :listening, timer_ref: nil, last_context: nil}
      end

    new_rule_state = Map.put(rule_state, dwell_key, new_dwell)
    put_in(st.rule_bindings[rule.name], new_rule_state)
  end

  defp dwell_signal_truthy?(context) do
    payload = Map.get(context, :context_data) || %{}

    cond do
      Map.has_key?(payload, "state") -> truthy?(Map.get(payload, "state"))
      Map.has_key?(payload, :state) -> truthy?(Map.get(payload, :state))
      true -> true
    end
  end

  defp truthy?(nil), do: false
  defp truthy?(false), do: false
  defp truthy?(_), do: true
```

- [ ] **Step 5: Add the `handle_info({:dwell_fire, ...})` clause**

In `lib/anemos/runtime/dispatcher.ex`, find the existing `handle_info({:condition_transition, _name}, state)` clause (around line 292). Add a new clause above it for `{:dwell_fire, rule_name, event_name}`:

```elixir
  @impl true
  def handle_info({:dwell_fire, rule_name, event_name}, state) do
    rule_state = Map.get(state.rule_bindings, rule_name, %{})
    dwell_key = {:dwell, event_name}

    case Map.get(rule_state, dwell_key) do
      %{state: :armed, last_context: context} when context != nil ->
        rule = Enum.find(state.rules, fn r -> r.name == rule_name and event_name in r.subscriptions end)

        new_state =
          if rule do
            # Activated: run handler, execute ops via existing immediate path.
            # dispatch_immediate appends to results, but we discard them here —
            # dwell-fired bodies are side-effect-only, accumulated via Logger
            # and channel publishes.
            {_results, st_after_run} = dispatch_immediate(rule, event_name, context, [], state)

            # Reset dwell state to listening regardless of body outcome.
            updated_rule_state =
              st_after_run.rule_bindings
              |> Map.get(rule_name, %{})
              |> Map.put(dwell_key, %{state: :listening, timer_ref: nil, last_context: nil})

            put_in(st_after_run.rule_bindings[rule_name], updated_rule_state)
          else
            state
          end

        {:noreply, new_state}

      _ ->
        # Stale fire — rule was cancelled or already fired. Drop silently.
        {:noreply, state}
    end
  end
```

- [ ] **Step 6: Run the dwell-timer tests**

Run: `mix test test/anemos/dwell_timer_test.exs`
Expected: all green.

If the "second truthy arrival does NOT restart the timer" test is flaky (timing-sensitive), bump the durations: change `for 100ms` to `for 200ms` and adjust sleep windows proportionally.

- [ ] **Step 7: Run the full test suite**

Run: `mix test`
Expected: all green. Pre-existing dispatcher tests should be unaffected because `dwell_duration_ms` is nil for all of them, routing through the unchanged immediate path.

- [ ] **Step 8: Commit**

```bash
git add lib/anemos/runtime/dispatcher.ex test/anemos/dwell_timer_test.exs
git commit -m "feat: dwell-timer state machine for when EV for <duration>"
```

---

## Task 5: End-to-end integration test through `Anemos.Runtime`

**Files:**
- Modify: `test/anemos/runtime_test.exs`

- [ ] **Step 1: Write the failing test**

Append to `test/anemos/runtime_test.exs` (before the final `end`):

```elixir
  test "for duration fires body after sustained truthy signal" do
    import ExUnit.CaptureLog

    start_supervised!({Anemos.Runtime, name: :test_dwell_e2e})

    Anemos.Runtime.load(:test_dwell_e2e, """
    rule r {
      when EV for 80ms { log "dwell fired" }
    }
    """)

    log =
      capture_log(fn ->
        Anemos.Runtime.dispatch(:test_dwell_e2e, "EV")
        Process.sleep(150)
      end)

    assert log =~ "dwell fired"
  end

  test "for duration cancels on falsy signal mid-window" do
    import ExUnit.CaptureLog

    start_supervised!({Anemos.Runtime, name: :test_dwell_cancel})

    Anemos.Runtime.load(:test_dwell_cancel, """
    rule r {
      when EV for 100ms { log "should not fire" }
    }
    """)

    log =
      capture_log(fn ->
        Anemos.Runtime.dispatch(:test_dwell_cancel, "EV")
        Process.sleep(30)
        Anemos.Runtime.dispatch(:test_dwell_cancel, "EV", %{context_data: %{"state" => false}})
        Process.sleep(150)
      end)

    refute log =~ "should not fire"
  end
```

- [ ] **Step 2: Run the new tests**

Run: `mix test test/anemos/runtime_test.exs`
Expected: green, including the two new dwell tests.

- [ ] **Step 3: Run the full suite one more time**

Run: `mix test`
Expected: all green.

- [ ] **Step 4: Commit**

```bash
git add test/anemos/runtime_test.exs
git commit -m "test: end-to-end dwell-timer integration through Anemos.Runtime"
```

---

## Task 6: Update status docs

**Files:**
- Modify: `TODO.md`
- Modify: `~/.claude/projects/-home-imsmith-github-anemos/memory/project_status.md`

- [ ] **Step 1: Update TODO.md**

In `TODO.md`, remove or update entries for these gaps. Current relevant lines:
- Line referencing partial implementation of operator precedence (already done — leave whatever is currently there alone unless explicitly listed)
- Find any "elseif" or "for 10min" / duration-related entries and remove them (search with `grep -in "elseif\|duration\|for.*10min" TODO.md`)

If no specific entries exist for either feature, append a short note under the "Fully working" section:

```markdown
  - ✅ elseif chains (if/elseif/else)
  - ✅ when EV for <duration> { ... } — dwell-timer state machine
```

- [ ] **Step 2: Update `project_status.md`**

In `~/.claude/projects/-home-imsmith-github-anemos/memory/project_status.md`, find the "What's not yet implemented" list. Remove these two lines:

```markdown
- **Duration enforcement** — `for 10min` parsed but runtime ignores it
- **elseif** — parsed but not fully wired
```

Update the "Current State" date line at the top to today's date. Add (or update) a "What's implemented" entry referencing the new features:

```markdown
- **Dwell timers** — `when EV for <duration> { ... }` runs a per-(rule, event) state machine (listening → armed → activated → listening). Timer does not restart on re-arrival; cancels on falsy `state` payload key.
- **elseif chains** — `if/elseif/.../else` works end-to-end (tested in `test/anemos/elseif_test.exs`)
```

- [ ] **Step 3: Commit**

```bash
git add TODO.md
git commit -m "docs: update TODO with elseif and dwell-timer completion"
```

Memory updates land outside the repo, no git commit needed for that file.

---

## Exit Criteria

```
mix compile --warnings-as-errors  → 0 errors
mix test                          → all green (existing + ~17 new tests)
elseif chains                     → tested end-to-end in elseif_test.exs
when EV for <duration>            → dwell timer fires body after sustained signal
when EV for <duration> + falsy    → timer cancels, body does not fire
TODO.md                           → both items moved out of partial list
project_status.md                 → both items moved out of not-yet-implemented
```
