# Wire Runtime Endpoints Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Connect all parsed-but-disconnected runtime endpoints so log, emit, set, condition side effects, and context store actually do something.

**Architecture:** Log ops go through Elixir Logger. Emit ops re-dispatch as new events through the dispatcher. Set ops stop being emitted as operations (persistence is internal). Condition side effects evaluate on transition. Context store is wired into `Anemos.run/2` so `?` variables resolve. Mix task shows emit_type.

**Tech Stack:** Elixir Logger, existing GenServer infrastructure

---

## File Structure

### Modified files

| File | Changes |
|------|---------|
| `lib/anemos/runtime/dispatcher.ex` | Log via Logger, emit re-dispatches events, remove set passthrough, accept context_store |
| `lib/anemos/runtime/condition_server.ex` | Execute side_effects on false->true transition, accept side_effect_handler |
| `lib/anemos/compiler.ex` | Compile condition side_effects into an executable handler, stop emitting set as an op |
| `lib/anemos.ex` | Start ContextStore, pass to dispatcher, accept `:context_data` option |
| `lib/mix/tasks/anemos.run.ex` | Show emit_type, accept `--context` flag |
| `test/anemos/runtime/dispatcher_test.exs` | Tests for log, emit, set changes |
| `test/anemos/runtime/condition_server_test.exs` | Tests for side effect execution |
| `test/anemos/compiler_test.exs` | Update set test (no longer emits op) |
| `test/anemos/pipeline_test.exs` | End-to-end tests with context store |

---

## Task 1: Log ops go through Logger

Currently `execute_op` for `:log` returns `{:ok, op}` as a passthrough. Make it actually log via `Logger.info/1` and still return the op (so callers can observe what was logged).

**Files:**

- Modify: `lib/anemos/runtime/dispatcher.ex:226-228`
- Test: `test/anemos/runtime/dispatcher_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/anemos/runtime/dispatcher_test.exs`:

```elixir
test "log operations emit through Logger" do
  input = """
  rule log-test {
    when LOG_EVENT {
      log "hello from anemos"
    }
  }
  """

  {:ok, ast} = Parser.parse(input)
  {:ok, %{rules: [compiled]}} = Compiler.compile(ast)
  {:ok, registry} = ModuleRegistry.start_link([])
  {:ok, dispatcher} = Dispatcher.start_link(rules: [compiled], registry: registry)

  log =
    ExUnit.CaptureLog.capture_log(fn ->
      results = Dispatcher.dispatch(dispatcher, "LOG_EVENT")
      assert [{:ok, %{type: :log, value: "hello from anemos"}}] = results
    end)

  assert log =~ "hello from anemos"
end
```

Add `import ExUnit.CaptureLog` at the top of the test module (or use the fully qualified call as shown).

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/anemos/runtime/dispatcher_test.exs --trace`
Expected: FAIL — log output not captured because `execute_op` doesn't call Logger.

- [ ] **Step 3: Update execute_op for :log**

In `lib/anemos/runtime/dispatcher.ex`, add `require Logger` at the top of the module and change:

```elixir
defp execute_op(%{type: :log, value: value} = op, _context, _registry, _capability_servers) do
  Logger.info("[anemos] #{value}")
  {:ok, op}
end
```

- [ ] **Step 4: Run tests**

Run: `mix test`
Expected: All PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/anemos/runtime/dispatcher.ex test/anemos/runtime/dispatcher_test.exs
git commit -m "feat: log operations emit through Elixir Logger"
```

---

## Task 2: Emit ops re-dispatch as events

Emit operations should feed back into the dispatcher as new events. The emit value's command (if present) becomes an operation, and the emit itself is dispatched as a new event named from the label or a generated name.

For now, emit re-dispatches the label (if present) as an event name through the dispatcher. If no label, the emit is still returned as-is (no event name to dispatch).

**Files:**

- Modify: `lib/anemos/runtime/dispatcher.ex:230-232`
- Test: `test/anemos/runtime/dispatcher_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/anemos/runtime/dispatcher_test.exs`:

```elixir
test "emit with label dispatches label as event" do
  input = """
  rule emitter {
    when SOURCE_EVENT {
      emit [EVENT::fire] as :my.event
    }
  }

  rule listener {
    when my.event {
      log "received emit"
    }
  }
  """

  {:ok, ast} = Parser.parse(input)
  {:ok, %{rules: rules}} = Compiler.compile(ast)
  {:ok, registry} = ModuleRegistry.start_link([])
  {:ok, dispatcher} = Dispatcher.start_link(rules: rules, registry: registry)

  results = Dispatcher.dispatch(dispatcher, "SOURCE_EVENT")

  log_values =
    Enum.flat_map(results, fn
      {:ok, %{type: :log, value: v}} -> [v]
      _ -> []
    end)

  assert "received emit" in log_values
end

test "emit without label returns op as-is" do
  input = """
  rule emitter {
    when SOURCE_EVENT {
      emit [EVENT::fire]
    }
  }
  """

  {:ok, ast} = Parser.parse(input)
  {:ok, %{rules: [compiled]}} = Compiler.compile(ast)
  {:ok, registry} = ModuleRegistry.start_link([])
  {:ok, dispatcher} = Dispatcher.start_link(rules: [compiled], registry: registry)

  results = Dispatcher.dispatch(dispatcher, "SOURCE_EVENT")
  assert [{:ok, %{type: :emit}}] = results
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/anemos/runtime/dispatcher_test.exs --trace`
Expected: FAIL — emit doesn't dispatch.

- [ ] **Step 3: Update execute_op for :emit**

The emit handler needs access to the dispatcher state to re-dispatch. Change `execute_op` to accept state and return `{results, state}` for emit, or handle emit re-dispatch at a higher level.

Simpler approach: `execute_op` for emit returns both the emit op AND a list of synthetic events to dispatch. Change `dispatch_to_rules` to collect and process these.

Actually, the simplest approach: make `execute_op` return `{:emit_event, label}` for labeled emits, and handle that in `dispatch_to_rules`:

In `lib/anemos/runtime/dispatcher.ex`:

```elixir
defp execute_op(%{type: :emit, label: label} = op, _context, _registry, _capability_servers)
     when is_binary(label) do
  Logger.info("[anemos] emit #{label}")
  {:emit_event, label, op}
end

defp execute_op(%{type: :emit} = op, _context, _registry, _capability_servers) do
  {:ok, op}
end
```

Then in `dispatch_to_rules`, after executing ops, collect `{:emit_event, label, op}` results and re-dispatch them:

```elixir
defp dispatch_to_rules(event_name, context, state) do
  matching = Map.get(state.index, event_name, [])
  event_context = Map.get(context, :context_path)

  matching
  |> Enum.filter(&context_matches?(&1, event_context))
  |> Enum.reduce({[], state}, fn rule, {results_acc, st} ->
    persistent = Map.get(st.rule_bindings, rule.name, %{})

    case safe_handle(rule, event_name, context, persistent) do
      {:ok, ops, new_persistent} ->
        new_st = put_in(st.rule_bindings[rule.name], new_persistent)

        {executed, emit_events} =
          ops
          |> Enum.flat_map(fn op ->
            List.wrap(execute_op(op, context, st.registry, st.capability_servers))
          end)
          |> Enum.split_with(fn
            {:emit_event, _, _} -> false
            _ -> true
          end)

        # Re-dispatch any labeled emits
        {emit_results, new_st} =
          Enum.reduce(emit_events, {[], new_st}, fn {:emit_event, label, op}, {acc, s} ->
            {sub_results, s} = dispatch_to_rules(label, context, s)
            {acc ++ [{:ok, op} | sub_results], s}
          end)

        {results_acc ++ executed ++ emit_results, new_st}

      {:error, reason} ->
        {results_acc ++ [{:error, {:handler_crash, rule.name, reason}}], st}
    end
  end)
end
```

- [ ] **Step 4: Run tests**

Run: `mix test`
Expected: All PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/anemos/runtime/dispatcher.ex test/anemos/runtime/dispatcher_test.exs
git commit -m "feat: emit with label re-dispatches as event through dispatcher"
```

---

## Task 3: Remove set op from execute_op output

Set persistence is now handled internally by the handler/dispatcher bindings mechanism. The `:set` op in the output is redundant noise. Stop emitting it as an operation from the compiler and remove the execute_op clause.

**Files:**

- Modify: `lib/anemos/compiler.ex:220-222`
- Modify: `lib/anemos/runtime/dispatcher.ex:243-245`
- Modify: `test/anemos/compiler_test.exs`
- Modify: `test/anemos/runtime/dispatcher_test.exs`

- [ ] **Step 1: Update compiler — set no longer emits an op**

In `lib/anemos/compiler.ex`, change `eval_statement` for `Set`:

```elixir
defp eval_statement(%AST.Set{name: name, value: value}, context, bindings) do
  resolved = resolve_expr(value, context, bindings)
  {[], Map.put(bindings, {:set, name}, resolved)}
end
```

Remove the `%{type: :set, ...}` op — `set` is now purely a binding update, no output.

- [ ] **Step 2: Remove execute_op for :set**

In `lib/anemos/runtime/dispatcher.ex`, delete:

```elixir
defp execute_op(%{type: :set} = op, _context, _registry, _capability_servers) do
  {:ok, op}
end
```

- [ ] **Step 3: Update compiler test**

In `test/anemos/compiler_test.exs`, the "set produces set operation" test needs to change. Set no longer produces ops:

```elixir
test "set updates persistent bindings without producing ops" do
  input = """
  rule set-rule {
    when TEST_EVENT {
      set x = "value"
    }
  }
  """

  {:ok, ast} = Parser.parse(input)
  {:ok, %{rules: [compiled]}} = Compiler.compile(ast)

  {:ok, ops, persistent} = compiled.handler.("TEST_EVENT", %{}, %{})
  assert ops == []
  assert persistent == %{{:set, "x"} => "value"}
end
```

Also update the "@ reads let bindings, $ reads set bindings" test — it currently expects a `:set` op in the output:

```elixir
test "@ reads let bindings, $ reads set bindings" do
  input = """
  rule sigil-rule {
    when TEST_EVENT {
      let x = "immutable"
      set y = "mutable"
      log @x
    }
  }
  """

  {:ok, ast} = Parser.parse(input)
  {:ok, %{rules: [compiled]}} = Compiler.compile(ast)
  {:ok, ops, persistent} = compiled.handler.("TEST_EVENT", %{}, %{})
  assert [%{type: :log, value: "immutable"}] = ops
  assert persistent == %{{:set, "y"} => "mutable"}
end
```

- [ ] **Step 4: Update dispatcher test**

In `test/anemos/runtime/dispatcher_test.exs`, the "set bindings persist across firings" test expects `{:ok, %{type: :set, ...}}` in results — update it since set no longer emits ops. The log should still appear:

```elixir
test "set bindings persist across firings" do
  input = """
  rule counter {
    when TICK {
      set count = 1
      log $count
    }
  }
  """

  {:ok, ast} = Parser.parse(input)
  {:ok, %{rules: [compiled]}} = Compiler.compile(ast)
  {:ok, registry} = ModuleRegistry.start_link([])
  {:ok, dispatcher} = Dispatcher.start_link(rules: [compiled], registry: registry)

  # First firing: set count = 1, log $count (which is 1 from this firing)
  results1 = Dispatcher.dispatch(dispatcher, "TICK")

  assert Enum.any?(results1, fn
    {:ok, %{type: :log, value: 1}} -> true
    _ -> false
  end)

  # Second firing: $count persists from first firing
  results2 = Dispatcher.dispatch(dispatcher, "TICK")

  assert Enum.any?(results2, fn
    {:ok, %{type: :log, value: 1}} -> true
    _ -> false
  end)
end
```

- [ ] **Step 5: Run tests**

Run: `mix test`
Expected: All PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/anemos/compiler.ex lib/anemos/runtime/dispatcher.ex test/anemos/compiler_test.exs test/anemos/runtime/dispatcher_test.exs
git commit -m "refactor: set is a binding update only, no longer emits op"
```

---

## Task 4: Condition side effects execute on transition

When a condition transitions false→true, its side_effects (the body of its `when` block — e.g., `emit`, `log`) should execute. The compiler needs to compile side_effects into an executable handler, and the condition server needs to call it on transition.

**Files:**

- Modify: `lib/anemos/compiler.ex:95-114`
- Modify: `lib/anemos/runtime/condition_server.ex:68-81`
- Test: `test/anemos/runtime/condition_server_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/anemos/runtime/condition_server_test.exs`:

```elixir
test "side effects execute on false->true transition" do
  test_pid = self()

  {:ok, pid} =
    ConditionServer.start_link(
      name_str: "with_effects",
      subscriptions: ["EV"],
      evaluator: fn _event, _ctx -> true end,
      side_effect_handler: fn ->
        send(test_pid, :side_effect_fired)
        {:ok, [%{type: :log, value: "condition effect"}]}
      end
    )

  ConditionServer.handle_event(pid, "EV", %{})
  assert_receive :side_effect_fired
end

test "side effects do not execute on true->true" do
  test_pid = self()

  {:ok, pid} =
    ConditionServer.start_link(
      name_str: "no_repeat",
      subscriptions: ["EV"],
      evaluator: fn _event, _ctx -> true end,
      side_effect_handler: fn ->
        send(test_pid, :side_effect_fired)
        {:ok, []}
      end
    )

  ConditionServer.handle_event(pid, "EV", %{})
  assert_receive :side_effect_fired

  ConditionServer.handle_event(pid, "EV", %{})
  refute_receive :side_effect_fired, 50
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/anemos/runtime/condition_server_test.exs --trace`
Expected: FAIL — `side_effect_handler` not recognized.

- [ ] **Step 3: Update ConditionServer to accept and call side_effect_handler**

In `lib/anemos/runtime/condition_server.ex`, update `init`:

```elixir
def init(opts) do
  state = %{
    name: Keyword.fetch!(opts, :name_str),
    subscriptions: MapSet.new(Keyword.fetch!(opts, :subscriptions)),
    evaluator: Keyword.fetch!(opts, :evaluator),
    side_effects: Keyword.get(opts, :side_effects, []),
    side_effect_handler: Keyword.get(opts, :side_effect_handler),
    on_transition: Keyword.get(opts, :on_transition),
    value: false
  }
  {:ok, state}
end
```

Update the false→true transition handler:

```elixir
{false, true} ->
  if state.side_effect_handler, do: state.side_effect_handler.()
  if state.on_transition, do: state.on_transition.(state.name)
  {:noreply, %{state | value: true}}
```

- [ ] **Step 4: Update compiler to build side_effect_handler**

In `lib/anemos/compiler.ex`, update `compile_condition`:

```elixir
defp compile_condition(%AST.Condition{name: name, body: body}) do
  when_blocks = extract_when_blocks(body)

  subscriptions =
    Enum.flat_map(when_blocks, fn %AST.When{event: event} ->
      event_to_subscriptions(event)
    end)

  side_effect_body = Enum.flat_map(when_blocks, fn %AST.When{body: when_body} -> when_body end)

  side_effect_handler =
    if side_effect_body == [] do
      nil
    else
      fn ->
        {ops, _bindings} = eval_body(side_effect_body, %{}, %{})
        {:ok, ops}
      end
    end

  evaluator = fn _event_name, _context -> true end

  %Anemos.CompiledCondition{
    name: name,
    subscriptions: subscriptions,
    evaluator: evaluator,
    side_effects: side_effect_body,
    side_effect_handler: side_effect_handler
  }
end
```

Add `:side_effect_handler` to the `CompiledCondition` struct in `lib/anemos/compiled_condition.ex`:

```elixir
defstruct [:name, :subscriptions, :evaluator, :side_effects, :side_effect_handler, :context]
```

Update the `@type t` to include it.

Update the dispatcher's `init` to pass `side_effect_handler` when starting condition servers:

In `lib/anemos/runtime/dispatcher.ex`, the `ConditionServer.start_link` call:

```elixir
ConditionServer.start_link(
  name_str: cond_spec.name,
  subscriptions: cond_spec.subscriptions,
  evaluator: cond_spec.evaluator,
  side_effects: cond_spec.side_effects,
  side_effect_handler: cond_spec.side_effect_handler,
  on_transition: fn name ->
    send(dispatcher_pid, {:condition_transition, name})
  end
)
```

- [ ] **Step 5: Run tests**

Run: `mix test`
Expected: All PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/anemos/compiled_condition.ex lib/anemos/compiler.ex lib/anemos/runtime/condition_server.ex lib/anemos/runtime/dispatcher.ex test/anemos/runtime/condition_server_test.exs
git commit -m "feat: condition side effects execute on false->true transition"
```

---

## Task 5: Wire ContextStore into Anemos.run/2

The ContextStore exists but isn't started or used. Wire it into `Anemos.run/2` so users can pass `:context_data` and `?` variables resolve.

**Files:**

- Modify: `lib/anemos.ex`
- Test: `test/anemos/pipeline_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/anemos/pipeline_test.exs`:

```elixir
test "? variables resolve from context_data option" do
  input = """
  rule greet {
    when GREET {
      log ?name
    }
  }
  """

  context = %{context_data: %{"name" => "ian"}}
  {:ok, results} = Anemos.run(input, event: "GREET", context: context)
  assert [%{type: :log, value: "ian"}] = results
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/anemos/pipeline_test.exs --trace`
Expected: FAIL — `?name` resolves to nil because context_data isn't threaded through.

- [ ] **Step 3: Verify it actually works**

The `context` map is already passed through `Anemos.run/2` → `Dispatcher.dispatch/3` → `safe_handle` → `handler.(event, context, persistent)` → `eval_body(body, context, ...)` → `resolve_expr(%VarRef{sigil: "?"}, context, _)` → `get_in(context, [:context_data, name])`.

So context_data should already resolve. Run the test — it might actually pass. If it does, the wiring is already complete and this task is just adding the test.

- [ ] **Step 4: Run tests**

Run: `mix test`
Expected: All PASS.

- [ ] **Step 5: Commit**

```bash
git add test/anemos/pipeline_test.exs
git commit -m "test: verify ? variables resolve from context_data through full pipeline"
```

---

## Task 6: Mix task shows emit_type

The mix task doesn't display `emit_type` (`:state`, `:effect`, `:stream`) even though the compiler includes it.

**Files:**

- Modify: `lib/mix/tasks/anemos.run.ex:40-43`

- [ ] **Step 1: Update emit display**

In `lib/mix/tasks/anemos.run.ex`, change the emit handler:

```elixir
%{type: :emit, value: value} = op ->
  emit_type = if op[:emit_type], do: "#{op[:emit_type]} ", else: ""
  dest = if op[:destination], do: " to #{inspect(op[:destination])}", else: ""
  label = if op[:label], do: " as #{op[:label]}", else: ""
  Mix.shell().info("  #{emit_type}emit #{inspect(value)}#{dest}#{label}")
```

Also remove the `:set` display clause since set no longer produces ops:

Delete:

```elixir
%{type: :set, name: name, value: value} ->
  Mix.shell().info("  set #{name} = #{inspect(value)}")
```

- [ ] **Step 2: Run tests**

Run: `mix test`
Expected: All PASS.

- [ ] **Step 3: Commit**

```bash
git add lib/mix/tasks/anemos.run.ex
git commit -m "fix: mix task shows emit_type, removes stale set display"
```

---

## Summary

After all 6 tasks:

1. **Log** — goes through `Logger.info/1`, observable in production
2. **Emit with label** — re-dispatches as a new event through the dispatcher
3. **Set** — purely internal binding update, no op noise in output
4. **Condition side effects** — execute on false→true transition
5. **Context data** — `?` variables resolve through the full pipeline
6. **Mix task** — displays emit_type correctly, no stale set output
