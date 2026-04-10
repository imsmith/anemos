# Anemos Runtime Semantics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Anemos policies mean something by implementing conditions (stateful GenServers), capabilities (demand-driven GenServers), context-scoped event filtering, and variable binding semantics.

**Architecture:** Each condition and capability becomes a supervised GenServer. The compiler produces process specs (not just closures). The dispatcher routes raw events to condition processes, which emit synthetic `CONDITION_<name>` events back through the dispatcher. Context scopes listener-side event filtering. Variable sigils (`?`, `$`, `@`) get distinct resolution paths: context data lookup, persistent process state, and ephemeral bindings respectively.

**Tech Stack:** Elixir/OTP GenServer, DynamicSupervisor, Phoenix.PubSub (already a dep), ExUnit TDD

---

## File Structure

### New files

| File | Responsibility |
|------|---------------|
| `lib/anemos/runtime/condition_server.ex` | GenServer for a single named condition. Holds boolean state, evaluates triggers, broadcasts `CONDITION_<name>` on false->true. Queryable for current state. |
| `lib/anemos/runtime/capability_server.ex` | GenServer for a single named capability. Holds `on demand` body. Executes when demanded, returns result. |
| `lib/anemos/runtime/context_store.ex` | Agent holding external key-value context data. Resolves `?` variable lookups against context path prefixes. |
| `lib/anemos/runtime/demand.ex` | Demand stack executor. Implements PAM-style control flag logic (requisite/required/optional/sufficient). |
| `lib/anemos/compiled_condition.ex` | Struct for compiled condition: name, subscriptions, evaluator, side_effects. |
| `lib/anemos/compiled_capability.ex` | Struct for compiled capability: name, context, handler. |
| `test/anemos/runtime/condition_server_test.exs` | Tests for condition GenServer lifecycle, state transitions, broadcasting. |
| `test/anemos/runtime/capability_server_test.exs` | Tests for capability execution via demand. |
| `test/anemos/runtime/context_store_test.exs` | Tests for context data resolution. |
| `test/anemos/runtime/demand_test.exs` | Tests for PAM-style demand stack evaluation. |

### Modified files

| File | Changes |
|------|---------|
| `lib/anemos/lexer.ex` | Fix `module_id` pattern to handle `CONDITION_networkchanged` as a single token (uppercase prefix + underscore + lowercase suffix). |
| `lib/anemos/parser.ex` | Handle `CONDITION_<name>` event syntax in `parse_when`. Add `--required`/`--optional`/`--sufficient` flag parsing to `parse_demand`. |
| `lib/anemos/ast.ex` | Add `flags` field to `Demand` struct. |
| `lib/anemos/compiler.ex` | Compile `Condition` and `Capability` declarations into process specs. Differentiate `?`/`$`/`@` variable resolution. Pass context path through compilation. |
| `lib/anemos/runtime/dispatcher.ex` | Route events to condition servers. Execute demand operations through capability servers. Apply context filtering on the listener side. |
| `lib/anemos/application.ex` | Start supervision tree: condition supervisor, capability supervisor, context store. |
| `lib/anemos.ex` | Wire up condition/capability compilation and process startup in `run/2`. |
| `lib/mix/tasks/anemos.run.ex` | Accept `--context-data` flag for providing external context key-value pairs. |
| `test/anemos/parser_test.exs` | Fix ddns test to expect `CONDITION_networkchanged` (underscore, not `::`). Add demand flag parsing tests. |
| `test/anemos/compiler_test.exs` | Add condition compilation tests, capability compilation tests, variable sigil differentiation tests. |
| `test/anemos/runtime/dispatcher_test.exs` | Add condition-triggered dispatch tests, context filtering tests. |
| `test/anemos/pipeline_test.exs` | Add end-to-end test with conditions firing rules, demand gating. |

---

## Task 1: Fix lexer — `CONDITION_networkchanged` tokenization

The lexer currently splits `CONDITION_networkchanged` into `module_id: "CONDITION_"` + `identifier: "networkchanged"` because the module_id pattern consumes uppercase+underscore greedily. We need `CONDITION_networkchanged` to produce a single token that the parser can match as an event name in `when` blocks.

**Files:**
- Modify: `lib/anemos/lexer.ex`
- Test: `test/anemos/lexer_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/anemos/lexer_test.exs`:

```elixir
test "tokenizes CONDITION_name as a single module_id token" do
  assert {:ok, tokens} = Anemos.Lexer.tokenize("CONDITION_networkchanged")
  assert [{:module_id, _, "CONDITION_networkchanged"}] = tokens
end

test "tokenizes mixed-case module event like SENSOR_motion_detected" do
  assert {:ok, tokens} = Anemos.Lexer.tokenize("SENSOR_MOTION_DETECTED")
  assert [{:module_id, _, "SENSOR_MOTION_DETECTED"}] = tokens
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/anemos/lexer_test.exs --only line:NEW_LINE -v`
Expected: FAIL — `CONDITION_networkchanged` splits into two tokens.

- [ ] **Step 3: Fix the module_id pattern in lexer**

In `lib/anemos/lexer.ex`, the `module_id` combinator needs to allow lowercase characters after an underscore within the identifier. The current pattern is approximately `[A-Z][A-Z0-9_]*`. Change it to `[A-Z][A-Z0-9_]*(_[a-z][a-z0-9_]*)*` — uppercase start, then optionally underscore followed by lowercase segments.

Find the `module_id` combinator (around line 85-95) and modify it so that after consuming uppercase+digit+underscore characters, if an underscore is followed by a lowercase letter, it continues consuming lowercase+digit+underscore characters. This makes `CONDITION_networkchanged` a single `module_id` token while keeping `CONDITION` alone still valid.

**Important:** This must not break existing tokens like `SENSOR_MOTION_DETECTED` (all uppercase), `DEVICE`, `FILE`, etc. The key insight: after `[A-Z][A-Z0-9_]*`, if we hit `_[a-z]`, we continue with `[a-z0-9_]*`. This is a single greedy match.

- [ ] **Step 4: Run all lexer tests to verify nothing broke**

Run: `mix test test/anemos/lexer_test.exs -v`
Expected: All PASS including new test.

- [ ] **Step 5: Commit**

```bash
git add lib/anemos/lexer.ex test/anemos/lexer_test.exs
git commit -m "fix: lexer tokenizes CONDITION_name as single module_id"
```

---

## Task 2: Fix parser — handle `CONDITION_<name>` in `when` and fix ddns test

Now that the lexer produces `CONDITION_networkchanged` as a single `module_id` token, the parser's existing `parse_when` for `module_id` events should handle it. But we need to update the ddns test expectation.

**Files:**
- Modify: `test/anemos/parser_test.exs`
- Test: `test/anemos/parser_test.exs`

- [ ] **Step 1: Update the ddns test expectation**

In `test/anemos/parser_test.exs` around line 357, change:

```elixir
# Before:
assert %AST.When{event: "CONDITION::networkchanged"} = when_block2

# After:
assert %AST.When{event: "CONDITION_networkchanged"} = when_block2
```

- [ ] **Step 2: Run the ddns parser test**

Run: `mix test test/anemos/parser_test.exs:332 -v`
Expected: PASS

- [ ] **Step 3: Run full test suite**

Run: `mix test -v`
Expected: All 72+ tests PASS, 0 failures.

- [ ] **Step 4: Commit**

```bash
git add test/anemos/parser_test.exs
git commit -m "fix: update ddns test to expect CONDITION_name with underscore"
```

---

## Task 3: Context store — external key-value data for `?` resolution

The context store holds externally-provided key-value data that `?` variables resolve against. Context paths act as prefixes: a rule in `context infra.networking.dns` resolves `?fqdn` by looking up `infra.networking.dns.fqdn` in the store.

**Files:**
- Create: `lib/anemos/runtime/context_store.ex`
- Create: `test/anemos/runtime/context_store_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/anemos/runtime/context_store_test.exs`:

```elixir
defmodule Anemos.Runtime.ContextStoreTest do
  use ExUnit.Case, async: true

  alias Anemos.Runtime.ContextStore

  test "stores and retrieves a key-value pair" do
    {:ok, store} = ContextStore.start_link([])
    ContextStore.put(store, "infra.networking.dns.fqdn", "host.example.tld")
    assert {:ok, "host.example.tld"} = ContextStore.resolve(store, "infra.networking.dns", "fqdn")
  end

  test "resolves key against context path prefix" do
    {:ok, store} = ContextStore.start_link([])
    ContextStore.put(store, "infra.networking.dns.fqdn", "host.example.tld")
    ContextStore.put(store, "infra.networking.gateway", "192.168.1.1")

    assert {:ok, "host.example.tld"} = ContextStore.resolve(store, "infra.networking.dns", "fqdn")
    assert {:ok, "192.168.1.1"} = ContextStore.resolve(store, "infra.networking", "gateway")
  end

  test "returns :error for missing key" do
    {:ok, store} = ContextStore.start_link([])
    assert :error = ContextStore.resolve(store, "infra.networking.dns", "missing")
  end

  test "context scoping: narrower context does not see sibling keys" do
    {:ok, store} = ContextStore.start_link([])
    ContextStore.put(store, "storage.backups.path", "/mnt/backup")

    assert :error = ContextStore.resolve(store, "infra.networking", "path")
  end

  test "bulk load from keyword list" do
    {:ok, store} = ContextStore.start_link(data: [
      {"infra.networking.dns.fqdn", "host.example.tld"},
      {"infra.networking.dns.ttl", "300"}
    ])

    assert {:ok, "host.example.tld"} = ContextStore.resolve(store, "infra.networking.dns", "fqdn")
    assert {:ok, "300"} = ContextStore.resolve(store, "infra.networking.dns", "ttl")
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/anemos/runtime/context_store_test.exs -v`
Expected: FAIL — module does not exist.

- [ ] **Step 3: Implement ContextStore**

Create `lib/anemos/runtime/context_store.ex`:

```elixir
defmodule Anemos.Runtime.ContextStore do
  @moduledoc """
  Agent holding external key-value context data.

  Keys are dotted paths (e.g., "infra.networking.dns.fqdn").
  Resolution joins the context path with the variable name to form the lookup key.
  """

  use Agent

  def start_link(opts) do
    name = Keyword.get(opts, :name)
    initial_data = Keyword.get(opts, :data, [])
    initial_map = Map.new(initial_data)
    Agent.start_link(fn -> initial_map end, name: name)
  end

  @spec put(pid() | atom(), String.t(), term()) :: :ok
  def put(store, key, value) do
    Agent.update(store, &Map.put(&1, key, value))
  end

  @spec resolve(pid() | atom(), String.t(), String.t()) :: {:ok, term()} | :error
  def resolve(store, context_path, name) do
    full_key = "#{context_path}.#{name}"

    case Agent.get(store, &Map.get(&1, full_key)) do
      nil -> :error
      value -> {:ok, value}
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/anemos/runtime/context_store_test.exs -v`
Expected: All PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/anemos/runtime/context_store.ex test/anemos/runtime/context_store_test.exs
git commit -m "feat: context store for external key-value data with path-scoped resolution"
```

---

## Task 4: Condition server — stateful GenServer with broadcast on false->true

Each named condition is a GenServer that holds boolean state, evaluates incoming events against its trigger logic, and broadcasts `CONDITION_<name>` through PubSub when transitioning from false to true.

**Files:**
- Create: `lib/anemos/compiled_condition.ex`
- Create: `lib/anemos/runtime/condition_server.ex`
- Create: `test/anemos/runtime/condition_server_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/anemos/runtime/condition_server_test.exs`:

```elixir
defmodule Anemos.Runtime.ConditionServerTest do
  use ExUnit.Case, async: true

  alias Anemos.Runtime.ConditionServer

  test "starts with state false" do
    {:ok, pid} = ConditionServer.start_link(
      name_str: "networkchanged",
      subscriptions: ["INFRA_ip4_addr_changed"],
      evaluator: fn _event, _ctx -> true end,
      side_effects: []
    )

    assert ConditionServer.get_state(pid) == false
  end

  test "transitions to true when matching event arrives and evaluator returns true" do
    test_pid = self()

    {:ok, pid} = ConditionServer.start_link(
      name_str: "networkchanged",
      subscriptions: ["INFRA_ip4_addr_changed"],
      evaluator: fn _event, _ctx -> true end,
      side_effects: [],
      on_transition: fn name -> send(test_pid, {:condition_true, name}) end
    )

    ConditionServer.handle_event(pid, "INFRA_ip4_addr_changed", %{})

    assert ConditionServer.get_state(pid) == true
    assert_receive {:condition_true, "networkchanged"}
  end

  test "does not broadcast when already true (true->true)" do
    test_pid = self()

    {:ok, pid} = ConditionServer.start_link(
      name_str: "networkchanged",
      subscriptions: ["INFRA_ip4_addr_changed"],
      evaluator: fn _event, _ctx -> true end,
      side_effects: [],
      on_transition: fn name -> send(test_pid, {:condition_true, name}) end
    )

    ConditionServer.handle_event(pid, "INFRA_ip4_addr_changed", %{})
    assert_receive {:condition_true, "networkchanged"}

    ConditionServer.handle_event(pid, "INFRA_ip4_addr_changed", %{})
    refute_receive {:condition_true, "networkchanged"}, 50
  end

  test "transitions silently to false when evaluator returns false" do
    test_pid = self()
    call_count = :counters.new(1, [:atomics])

    {:ok, pid} = ConditionServer.start_link(
      name_str: "temp_high",
      subscriptions: ["TEMP_READING"],
      evaluator: fn _event, _ctx ->
        :counters.add(call_count, 1, 1)
        :counters.get(call_count, 1) == 1
      end,
      side_effects: [],
      on_transition: fn name -> send(test_pid, {:condition_true, name}) end
    )

    # First event: evaluator returns true -> transition fires
    ConditionServer.handle_event(pid, "TEMP_READING", %{})
    assert ConditionServer.get_state(pid) == true
    assert_receive {:condition_true, "temp_high"}

    # Second event: evaluator returns false -> silent transition to false
    ConditionServer.handle_event(pid, "TEMP_READING", %{})
    assert ConditionServer.get_state(pid) == false
    refute_receive {:condition_true, "temp_high"}, 50
  end

  test "ignores non-subscribed events" do
    {:ok, pid} = ConditionServer.start_link(
      name_str: "networkchanged",
      subscriptions: ["INFRA_ip4_addr_changed"],
      evaluator: fn _event, _ctx -> true end,
      side_effects: []
    )

    ConditionServer.handle_event(pid, "UNRELATED_EVENT", %{})
    assert ConditionServer.get_state(pid) == false
  end

  test "queryable at any time" do
    {:ok, pid} = ConditionServer.start_link(
      name_str: "test_cond",
      subscriptions: ["EV"],
      evaluator: fn _event, _ctx -> true end,
      side_effects: []
    )

    assert ConditionServer.get_state(pid) == false
    ConditionServer.handle_event(pid, "EV", %{})
    assert ConditionServer.get_state(pid) == true
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/anemos/runtime/condition_server_test.exs -v`
Expected: FAIL — module does not exist.

- [ ] **Step 3: Create CompiledCondition struct**

Create `lib/anemos/compiled_condition.ex`:

```elixir
defmodule Anemos.CompiledCondition do
  @moduledoc """
  A compiled condition: name, trigger subscriptions, evaluator function, and side effects.
  """
  defstruct [:name, :subscriptions, :evaluator, :side_effects, :context]
end
```

- [ ] **Step 4: Implement ConditionServer**

Create `lib/anemos/runtime/condition_server.ex`:

```elixir
defmodule Anemos.Runtime.ConditionServer do
  @moduledoc """
  GenServer for a single named condition.

  Holds boolean state. Evaluates incoming events against trigger logic.
  Broadcasts `CONDITION_<name>` on false->true transition.
  Queryable for current state at any time.
  """

  use GenServer

  # --- Client API ---

  def start_link(opts) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec get_state(pid() | atom()) :: boolean()
  def get_state(server) do
    GenServer.call(server, :get_state)
  end

  @spec handle_event(pid() | atom(), String.t(), map()) :: :ok
  def handle_event(server, event_name, context) do
    GenServer.cast(server, {:event, event_name, context})
  end

  # --- Server callbacks ---

  @impl true
  def init(opts) do
    state = %{
      name: Keyword.fetch!(opts, :name_str),
      subscriptions: MapSet.new(Keyword.fetch!(opts, :subscriptions)),
      evaluator: Keyword.fetch!(opts, :evaluator),
      side_effects: Keyword.get(opts, :side_effects, []),
      on_transition: Keyword.get(opts, :on_transition),
      value: false
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state.value, state}
  end

  @impl true
  def handle_cast({:event, event_name, context}, state) do
    if MapSet.member?(state.subscriptions, event_name) do
      new_value = state.evaluator.(event_name, context)

      case {state.value, new_value} do
        {false, true} ->
          if state.on_transition, do: state.on_transition.(state.name)
          {:noreply, %{state | value: true}}

        {_old, new_val} ->
          {:noreply, %{state | value: new_val}}
      end
    else
      {:noreply, state}
    end
  end
end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/anemos/runtime/condition_server_test.exs -v`
Expected: All PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/anemos/compiled_condition.ex lib/anemos/runtime/condition_server.ex test/anemos/runtime/condition_server_test.exs
git commit -m "feat: condition server GenServer with stateful transitions and broadcast"
```

---

## Task 5: Capability server — passive GenServer, executes on demand

Each named capability is a GenServer holding its `on demand` body. It's passive until demanded — then it executes the body and returns the result.

**Files:**
- Create: `lib/anemos/compiled_capability.ex`
- Create: `lib/anemos/runtime/capability_server.ex`
- Create: `test/anemos/runtime/capability_server_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/anemos/runtime/capability_server_test.exs`:

```elixir
defmodule Anemos.Runtime.CapabilityServerTest do
  use ExUnit.Case, async: true

  alias Anemos.Runtime.CapabilityServer

  test "starts and is addressable" do
    {:ok, pid} = CapabilityServer.start_link(
      name_str: "test-key",
      context: "infra.networking",
      handler: fn _ctx -> {:ok, [%{type: :emit, value: "unlocked"}]} end
    )

    assert Process.alive?(pid)
  end

  test "execute returns handler result" do
    {:ok, pid} = CapabilityServer.start_link(
      name_str: "test-key",
      context: "infra.networking",
      handler: fn _ctx -> {:ok, [%{type: :emit, value: "unlocked"}]} end
    )

    assert {:ok, [%{type: :emit, value: "unlocked"}]} = CapabilityServer.execute(pid, %{})
  end

  test "handler receives context" do
    {:ok, pid} = CapabilityServer.start_link(
      name_str: "ctx-cap",
      context: "infra",
      handler: fn ctx -> {:ok, [%{type: :emit, value: ctx[:user]}]} end
    )

    assert {:ok, [%{type: :emit, value: "ian"}]} = CapabilityServer.execute(pid, %{user: "ian"})
  end

  test "handler error is returned, does not crash server" do
    {:ok, pid} = CapabilityServer.start_link(
      name_str: "fail-cap",
      context: "test",
      handler: fn _ctx -> {:error, :unavailable} end
    )

    assert {:error, :unavailable} = CapabilityServer.execute(pid, %{})
    assert Process.alive?(pid)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/anemos/runtime/capability_server_test.exs -v`
Expected: FAIL — module does not exist.

- [ ] **Step 3: Create CompiledCapability struct**

Create `lib/anemos/compiled_capability.ex`:

```elixir
defmodule Anemos.CompiledCapability do
  @moduledoc """
  A compiled capability: name, context scope, and handler closure for on-demand execution.
  """
  defstruct [:name, :context, :handler]
end
```

- [ ] **Step 4: Implement CapabilityServer**

Create `lib/anemos/runtime/capability_server.ex`:

```elixir
defmodule Anemos.Runtime.CapabilityServer do
  @moduledoc """
  GenServer for a single named capability.

  Passive until demanded. Executes its `on demand` handler and returns the result.
  """

  use GenServer

  # --- Client API ---

  def start_link(opts) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec execute(pid() | atom(), map()) :: {:ok, list()} | {:error, term()}
  def execute(server, context) do
    GenServer.call(server, {:execute, context})
  end

  # --- Server callbacks ---

  @impl true
  def init(opts) do
    state = %{
      name: Keyword.fetch!(opts, :name_str),
      context: Keyword.fetch!(opts, :context),
      handler: Keyword.fetch!(opts, :handler)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:execute, context}, _from, state) do
    result =
      try do
        state.handler.(context)
      rescue
        e -> {:error, {:capability_crash, state.name, Exception.message(e)}}
      end

    {:reply, result, state}
  end
end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/anemos/runtime/capability_server_test.exs -v`
Expected: All PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/anemos/compiled_capability.ex lib/anemos/runtime/capability_server.ex test/anemos/runtime/capability_server_test.exs
git commit -m "feat: capability server GenServer with on-demand execution"
```

---

## Task 6: Demand executor — PAM-style control flag stack evaluation

The demand executor takes a list of demand operations (each with a capability name and optional control flag) and evaluates them against running capability servers using PAM semantics.

**Files:**
- Create: `lib/anemos/runtime/demand.ex`
- Create: `test/anemos/runtime/demand_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/anemos/runtime/demand_test.exs`:

```elixir
defmodule Anemos.Runtime.DemandTest do
  use ExUnit.Case, async: true

  alias Anemos.Runtime.{Demand, CapabilityServer}

  defp start_capability(name, result) do
    {:ok, pid} = CapabilityServer.start_link(
      name_str: name,
      context: "test",
      handler: fn _ctx -> result end
    )
    pid
  end

  test "single bare demand (requisite) — success" do
    pid = start_capability("key", {:ok, [%{type: :emit, value: "unlocked"}]})
    registry = %{"key" => pid}
    demands = [%{capability: "key", flag: :requisite}]

    assert {:ok, results} = Demand.evaluate(demands, registry, %{})
    assert [%{type: :emit, value: "unlocked"}] = results
  end

  test "single bare demand (requisite) — failure stops immediately" do
    pid = start_capability("key", {:error, :denied})
    registry = %{"key" => pid}
    demands = [%{capability: "key", flag: :requisite}]

    assert {:error, {:demand_failed, "key", :denied}} = Demand.evaluate(demands, registry, %{})
  end

  test "missing capability — requisite fails" do
    demands = [%{capability: "nonexistent", flag: :requisite}]

    assert {:error, {:unknown_capability, "nonexistent"}} = Demand.evaluate(demands, %{}, %{})
  end

  test "optional demand — failure continues" do
    fail_pid = start_capability("optional-key", {:error, :unavailable})
    ok_pid = start_capability("main-key", {:ok, [%{type: :emit, value: "done"}]})
    registry = %{"optional-key" => fail_pid, "main-key" => ok_pid}

    demands = [
      %{capability: "optional-key", flag: :optional},
      %{capability: "main-key", flag: :requisite}
    ]

    assert {:ok, results} = Demand.evaluate(demands, registry, %{})
    assert [%{type: :emit, value: "done"}] = results
  end

  test "required demand — deferred failure after stack" do
    fail_pid = start_capability("req-key", {:error, :denied})
    ok_pid = start_capability("other-key", {:ok, [%{type: :emit, value: "ok"}]})
    registry = %{"req-key" => fail_pid, "other-key" => ok_pid}

    demands = [
      %{capability: "req-key", flag: :required},
      %{capability: "other-key", flag: :requisite}
    ]

    # required fails, but stack continues; final result is failure
    assert {:error, {:demand_failed, "req-key", :denied}} = Demand.evaluate(demands, registry, %{})
  end

  test "sufficient demand — success skips rest of stack" do
    ok_pid = start_capability("suf-key", {:ok, [%{type: :emit, value: "enough"}]})
    registry = %{"suf-key" => ok_pid}

    demands = [
      %{capability: "suf-key", flag: :sufficient},
      %{capability: "nonexistent", flag: :requisite}
    ]

    # sufficient succeeds, so nonexistent is never checked
    assert {:ok, results} = Demand.evaluate(demands, registry, %{})
    assert [%{type: :emit, value: "enough"}] = results
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/anemos/runtime/demand_test.exs -v`
Expected: FAIL — module does not exist.

- [ ] **Step 3: Implement Demand executor**

Create `lib/anemos/runtime/demand.ex`:

```elixir
defmodule Anemos.Runtime.Demand do
  @moduledoc """
  Evaluates a stack of demand operations against capability servers
  using PAM-style control flag semantics.

  Flags:
  - `:requisite` (default) — must succeed, fail immediately if not
  - `:required` — must succeed, but evaluate rest of stack before failing
  - `:optional` — continue whether it succeeds or fails
  - `:sufficient` — if succeeds, skip rest of stack
  """

  alias Anemos.Runtime.CapabilityServer

  @spec evaluate([map()], map(), map()) :: {:ok, list()} | {:error, term()}
  def evaluate(demands, capability_registry, context) do
    eval_stack(demands, capability_registry, context, [], nil)
  end

  defp eval_stack([], _registry, _context, results, nil) do
    {:ok, Enum.reverse(results) |> List.flatten()}
  end

  defp eval_stack([], _registry, _context, _results, deferred_error) do
    deferred_error
  end

  defp eval_stack([demand | rest], registry, context, results, deferred_error) do
    case Map.get(registry, demand.capability) do
      nil ->
        handle_missing(demand, rest, registry, context, results, deferred_error)

      pid ->
        case CapabilityServer.execute(pid, context) do
          {:ok, ops} ->
            handle_success(demand, ops, rest, registry, context, results, deferred_error)

          {:error, reason} ->
            handle_failure(demand, reason, rest, registry, context, results, deferred_error)
        end
    end
  end

  defp handle_missing(demand, rest, registry, context, results, deferred_error) do
    error = {:error, {:unknown_capability, demand.capability}}

    case demand.flag do
      :requisite -> error
      :required -> eval_stack(rest, registry, context, results, deferred_error || error)
      :optional -> eval_stack(rest, registry, context, results, deferred_error)
      :sufficient -> eval_stack(rest, registry, context, results, deferred_error)
    end
  end

  defp handle_success(demand, ops, rest, registry, context, results, deferred_error) do
    case demand.flag do
      :sufficient -> {:ok, Enum.reverse(results) ++ List.wrap(ops)}
      _ -> eval_stack(rest, registry, context, List.wrap(ops) ++ results, deferred_error)
    end
  end

  defp handle_failure(demand, reason, rest, registry, context, results, deferred_error) do
    error = {:error, {:demand_failed, demand.capability, reason}}

    case demand.flag do
      :requisite -> error
      :required -> eval_stack(rest, registry, context, results, deferred_error || error)
      :optional -> eval_stack(rest, registry, context, results, deferred_error)
      :sufficient -> eval_stack(rest, registry, context, results, deferred_error)
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/anemos/runtime/demand_test.exs -v`
Expected: All PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/anemos/runtime/demand.ex test/anemos/runtime/demand_test.exs
git commit -m "feat: demand executor with PAM-style control flag stack evaluation"
```

---

## Task 7: Compiler — compile conditions and capabilities into process specs

The compiler currently skips `Condition` and `Capability` AST nodes. This task adds compilation of both into structs that the runtime can use to start GenServers.

**Files:**
- Modify: `lib/anemos/compiler.ex`
- Test: `test/anemos/compiler_test.exs`

- [ ] **Step 1: Write the failing tests**

Add to `test/anemos/compiler_test.exs`:

```elixir
test "compiles condition declaration into CompiledCondition" do
  input = """
  condition networkchanged {
    when (INFRA_ip4_addr_changed OR INFRA_ip6_addr_changed) {
      log "network changed"
    }
  }
  """

  {:ok, ast} = Parser.parse(input)
  {:ok, compiled} = Compiler.compile(ast)

  # Conditions come back separately from rules
  assert compiled.conditions != []
  [cond] = compiled.conditions
  assert cond.name == "networkchanged"
  assert "INFRA_ip4_addr_changed" in cond.subscriptions
  assert "INFRA_ip6_addr_changed" in cond.subscriptions
  assert is_function(cond.evaluator, 2)
end

test "compiles capability declaration into CompiledCapability" do
  input = """
  capability test-key {
    context infra.networking

    on demand {
      log "unlocked"
    }
  }
  """

  {:ok, ast} = Parser.parse(input)
  {:ok, compiled} = Compiler.compile(ast)

  assert compiled.capabilities != []
  [cap] = compiled.capabilities
  assert cap.name == "test-key"
  assert cap.context == "infra.networking"
  assert is_function(cap.handler, 1)
end

test "mixed declarations: rules, conditions, capabilities all compiled" do
  source = File.read!("priv/examples/ddns.rule")
  {:ok, ast} = Parser.parse(source)
  {:ok, compiled} = Compiler.compile(ast)

  assert length(compiled.rules) == 1
  assert length(compiled.conditions) == 1
  assert length(compiled.capabilities) == 1

  assert hd(compiled.rules).name == "update-ddns"
  assert hd(compiled.conditions).name == "networkchanged"
  assert hd(compiled.capabilities).name == "katachora-ddns-key"
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/anemos/compiler_test.exs -v`
Expected: FAIL — `compiled.conditions` not available, return type is `{:ok, [CompiledRule]}`.

- [ ] **Step 3: Change compiler return type and add condition/capability compilation**

The compiler's `compile/1` currently returns `{:ok, [CompiledRule]}`. Change it to return `{:ok, %{rules: [...], conditions: [...], capabilities: [...]}}`.

In `lib/anemos/compiler.ex`, replace the `compile/1` function and add `compile_declaration` clauses for `Condition` and `Capability`:

```elixir
defmodule Anemos.CompilationResult do
  defstruct rules: [], conditions: [], capabilities: []
end
```

Add this struct at the top of the file (before `Anemos.Compiler`). Then change `compile/1`:

```elixir
def compile(%AST.Program{declarations: declarations}) do
  result =
    Enum.reduce(declarations, %Anemos.CompilationResult{}, fn decl, acc ->
      case compile_declaration(decl) do
        {:rule, rules} ->
          %{acc | rules: acc.rules ++ rules}

        {:condition, cond} ->
          %{acc | conditions: acc.conditions ++ [cond]}

        {:capability, cap} ->
          %{acc | capabilities: acc.capabilities ++ [cap]}

        :skip ->
          acc
      end
    end)

  {:ok, result}
end
```

Change `compile_declaration` clauses:

```elixir
defp compile_declaration(%AST.Rule{} = rule) do
  {:rule, compile_rule(rule)}
end

defp compile_declaration(%AST.Condition{} = cond_decl) do
  {:condition, compile_condition(cond_decl)}
end

defp compile_declaration(%AST.Capability{} = cap) do
  {:capability, compile_capability(cap)}
end

defp compile_declaration(_other), do: :skip
```

Add `compile_condition`:

```elixir
defp compile_condition(%AST.Condition{name: name, body: body}) do
  when_blocks = extract_when_blocks(body)
  subscriptions =
    Enum.flat_map(when_blocks, fn %AST.When{event: event} ->
      event_to_subscriptions(event)
    end)

  side_effects = Enum.flat_map(when_blocks, fn %AST.When{body: when_body} -> when_body end)

  evaluator = fn _event_name, _context -> true end

  %Anemos.CompiledCondition{
    name: name,
    subscriptions: subscriptions,
    evaluator: evaluator,
    side_effects: side_effects
  }
end
```

Add `compile_capability`:

```elixir
defp compile_capability(%AST.Capability{name: name, context: context, body: body}) do
  handler = fn _context ->
    {ops, _bindings} = eval_body(body, %{}, %{})
    {:ok, ops}
  end

  %Anemos.CompiledCapability{
    name: name,
    context: context,
    handler: handler
  }
end
```

- [ ] **Step 4: Update existing tests for new return type**

The return type changed from `{:ok, [CompiledRule]}` to `{:ok, %CompilationResult{}}`. Existing tests that pattern match on `{:ok, [compiled]}` or `{:ok, modules}` need updating.

In `test/anemos/compiler_test.exs`, update all existing tests. For example, change:

```elixir
# Before:
{:ok, [compiled]} = Compiler.compile(ast)

# After:
{:ok, %{rules: [compiled]}} = Compiler.compile(ast)
```

And:

```elixir
# Before:
{:ok, modules} = Compiler.compile(ast)
assert length(modules) == 2

# After:
{:ok, %{rules: rules}} = Compiler.compile(ast)
assert length(rules) == 2
```

Also update `test/anemos/pipeline_test.exs`, `test/anemos/runtime/dispatcher_test.exs`, `lib/anemos.ex`, and `lib/mix/tasks/anemos.run.ex` to destructure the new return type. In `lib/anemos.ex`:

```elixir
# Before:
{:ok, rules} <- Compiler.compile(ast),

# After:
{:ok, %{rules: rules}} <- Compiler.compile(ast),
```

The dispatcher and pipeline tests use `Compiler.compile(ast)` and pass rules directly — update their destructuring similarly.

- [ ] **Step 5: Run all tests to verify they pass**

Run: `mix test -v`
Expected: All PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/anemos/compiler.ex lib/anemos/compiled_condition.ex lib/anemos/compiled_capability.ex lib/anemos.ex lib/mix/tasks/anemos.run.ex test/anemos/compiler_test.exs test/anemos/pipeline_test.exs test/anemos/runtime/dispatcher_test.exs
git commit -m "feat: compiler produces conditions and capabilities alongside rules"
```

---

## Task 8: Variable sigil differentiation in the compiler

Currently `$`, `@`, and `?` all resolve identically via bindings lookup. This task differentiates them:

- `?name` resolves against the context store (external data)
- `@name` resolves against ephemeral `let` bindings (immutable within execution)
- `$name` resolves against persistent `set` bindings (mutable, stored in process state)

**Files:**
- Modify: `lib/anemos/compiler.ex`
- Test: `test/anemos/compiler_test.exs`

- [ ] **Step 1: Write the failing tests**

Add to `test/anemos/compiler_test.exs`:

```elixir
test "? variable resolves from context data, not bindings" do
  input = """
  rule query-rule {
    when TEST_EVENT {
      log ?fqdn
    }
  }
  """

  {:ok, ast} = Parser.parse(input)
  {:ok, %{rules: [compiled]}} = Compiler.compile(ast)

  # Pass context_data with the fqdn key, scoped to the default context
  context = %{context_data: %{"fqdn" => "host.example.tld"}}
  {:ok, ops} = compiled.handler.("TEST_EVENT", context)
  assert [%{type: :log, value: "host.example.tld"}] = ops
end

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

  {:ok, ops} = compiled.handler.("TEST_EVENT", %{})
  assert [%{type: :set, name: "y", value: "mutable"}, %{type: :log, value: "immutable"}] = ops
end

test "? returns nil when context data key is missing" do
  input = """
  rule missing-query {
    when TEST_EVENT {
      log ?nonexistent
    }
  }
  """

  {:ok, ast} = Parser.parse(input)
  {:ok, %{rules: [compiled]}} = Compiler.compile(ast)

  {:ok, ops} = compiled.handler.("TEST_EVENT", %{context_data: %{}})
  assert [%{type: :log, value: nil}] = ops
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/anemos/compiler_test.exs -v`
Expected: FAIL — `?` variables currently resolve via bindings (returning nil), not from context_data.

- [ ] **Step 3: Differentiate sigil resolution in `resolve_expr`**

In `lib/anemos/compiler.ex`, change the `resolve_expr` for `VarRef` from the single catch-all to three clauses:

```elixir
# ? — resolve from context data
defp resolve_expr(%AST.VarRef{sigil: "?", name: name}, context, _bindings) do
  case get_in(context, [:context_data, name]) do
    nil -> nil
    value -> value
  end
end

# @ — resolve from let bindings (immutable/ephemeral)
defp resolve_expr(%AST.VarRef{sigil: "@", name: name}, _context, bindings) do
  Map.get(bindings, {:let, name})
end

# $ — resolve from set bindings (mutable/persistent)
defp resolve_expr(%AST.VarRef{sigil: "$", name: name}, _context, bindings) do
  Map.get(bindings, {:set, name})
end
```

Update `eval_statement` for `Let` to store under `{:let, name}`:

```elixir
defp eval_statement(%AST.Let{name: name, value: value}, context, bindings) do
  resolved = resolve_expr(value, context, bindings)

  {ops, new_bindings} =
    case resolved do
      %{type: :command} = cmd_op ->
        {[cmd_op], Map.put(bindings, {:let, name}, cmd_op)}

      other ->
        {[], Map.put(bindings, {:let, name}, other)}
    end

  {ops, new_bindings}
end
```

Update `eval_statement` for `Set` to store under `{:set, name}`:

```elixir
defp eval_statement(%AST.Set{name: name, value: value}, context, bindings) do
  resolved = resolve_expr(value, context, bindings)
  {[%{type: :set, name: name, value: resolved}], Map.put(bindings, {:set, name}, resolved)}
end
```

- [ ] **Step 4: Update existing tests that use `$` to read `let` bindings**

The existing tests use `let x = "hello"` then `log $x`. With the new semantics, `let` creates an `@` binding, so `$x` would resolve to nil. Update these tests:

In `test/anemos/compiler_test.exs`, the "let bindings are available as variable references" test:

```elixir
# Change from:
let x = "hello"
log $x

# To:
let x = "hello"
log @x
```

Similarly update "let binding with command produces command operation" and "command with var ref argument resolves from context" — anywhere `let` + `$` appears, change `$` to `@`.

Also update the doctest in `lib/anemos/compiler.ex` if it uses `$` with `let`.

- [ ] **Step 5: Run all tests**

Run: `mix test -v`
Expected: All PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/anemos/compiler.ex test/anemos/compiler_test.exs
git commit -m "feat: differentiate ? $ @ variable resolution — context, mutable, immutable"
```

---

## Task 9: Dispatcher — wire conditions into event routing

The dispatcher needs to:
1. Route incoming events to condition servers
2. When a condition transitions to true, dispatch `CONDITION_<name>` to rules
3. Apply context path filtering on the listener side

**Files:**
- Modify: `lib/anemos/runtime/dispatcher.ex`
- Test: `test/anemos/runtime/dispatcher_test.exs`

- [ ] **Step 1: Write the failing tests**

Add to `test/anemos/runtime/dispatcher_test.exs`:

```elixir
test "condition server triggers CONDITION_<name> event to matching rules" do
  # Rule subscribes to CONDITION_networkchanged
  rule_input = """
  rule react-to-condition {
    when CONDITION_networkchanged {
      log "network changed!"
    }
  }
  """

  {:ok, ast} = Parser.parse(rule_input)
  {:ok, %{rules: [compiled_rule]}} = Compiler.compile(ast)

  {:ok, registry} = ModuleRegistry.start_link([])

  # Start a condition server that triggers on RAW_EVENT
  {:ok, dispatcher} = Dispatcher.start_link(
    rules: [compiled_rule],
    registry: registry,
    conditions: [
      %Anemos.CompiledCondition{
        name: "networkchanged",
        subscriptions: ["RAW_EVENT"],
        evaluator: fn _event, _ctx -> true end,
        side_effects: []
      }
    ]
  )

  # Dispatch the raw event — condition should transition, then CONDITION_networkchanged fires
  results = Dispatcher.dispatch(dispatcher, "RAW_EVENT")
  assert [{:ok, %{type: :log, value: "network changed!"}}] = results
end

test "condition that stays false does not trigger rules" do
  rule_input = """
  rule react-to-condition {
    when CONDITION_never_true {
      log "should not fire"
    }
  }
  """

  {:ok, ast} = Parser.parse(rule_input)
  {:ok, %{rules: [compiled_rule]}} = Compiler.compile(ast)

  {:ok, registry} = ModuleRegistry.start_link([])

  {:ok, dispatcher} = Dispatcher.start_link(
    rules: [compiled_rule],
    registry: registry,
    conditions: [
      %Anemos.CompiledCondition{
        name: "never_true",
        subscriptions: ["RAW_EVENT"],
        evaluator: fn _event, _ctx -> false end,
        side_effects: []
      }
    ]
  )

  results = Dispatcher.dispatch(dispatcher, "RAW_EVENT")
  assert results == []
end

test "condition queryable via dispatcher" do
  {:ok, registry} = ModuleRegistry.start_link([])

  {:ok, dispatcher} = Dispatcher.start_link(
    rules: [],
    registry: registry,
    conditions: [
      %Anemos.CompiledCondition{
        name: "test_cond",
        subscriptions: ["EV"],
        evaluator: fn _event, _ctx -> true end,
        side_effects: []
      }
    ]
  )

  assert Dispatcher.condition_state(dispatcher, "test_cond") == false
  Dispatcher.dispatch(dispatcher, "EV")
  assert Dispatcher.condition_state(dispatcher, "test_cond") == true
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/anemos/runtime/dispatcher_test.exs -v`
Expected: FAIL — `Dispatcher.start_link` doesn't accept `:conditions`, no `condition_state/2`.

- [ ] **Step 3: Update Dispatcher to manage condition servers**

In `lib/anemos/runtime/dispatcher.ex`:

1. Accept optional `:conditions` in `start_link` opts.
2. In `init`, start a `ConditionServer` for each compiled condition, passing an `on_transition` callback that dispatches the synthetic event back through the dispatcher.
3. On `dispatch`, first route the event to condition servers, collect any synthetic events, then dispatch those too.
4. Add `condition_state/2` for querying condition state.

```elixir
def start_link(opts) do
  rules = Keyword.fetch!(opts, :rules)
  registry = Keyword.fetch!(opts, :registry)
  conditions = Keyword.get(opts, :conditions, [])
  name = Keyword.get(opts, :name)
  GenServer.start_link(__MODULE__, {rules, registry, conditions}, name: name)
end

def condition_state(dispatcher, condition_name) do
  GenServer.call(dispatcher, {:condition_state, condition_name})
end

@impl true
def init({rules, registry, compiled_conditions}) do
  index = build_index(rules)
  dispatcher_pid = self()

  condition_servers =
    Map.new(compiled_conditions, fn cond ->
      {:ok, pid} = Anemos.Runtime.ConditionServer.start_link(
        name_str: cond.name,
        subscriptions: cond.subscriptions,
        evaluator: cond.evaluator,
        side_effects: cond.side_effects,
        on_transition: fn name ->
          send(dispatcher_pid, {:condition_transition, name})
        end
      )
      {cond.name, %{pid: pid, subscriptions: cond.subscriptions}}
    end)

  {:ok, %{rules: rules, index: index, registry: registry, condition_servers: condition_servers}}
end
```

Update `handle_call` for dispatch to first route to conditions, then collect synthetic events:

```elixir
@impl true
def handle_call({:dispatch, event_name, context}, _from, state) do
  # Route to condition servers
  Enum.each(state.condition_servers, fn {_name, %{pid: pid}} ->
    Anemos.Runtime.ConditionServer.handle_event(pid, event_name, context)
  end)

  # Collect any condition transitions that happened synchronously
  synthetic_events = collect_transitions()

  # Dispatch original event to matching rules
  results = dispatch_to_rules(event_name, context, state)

  # Dispatch any synthetic CONDITION_<name> events
  synthetic_results =
    Enum.flat_map(synthetic_events, fn cond_name ->
      dispatch_to_rules("CONDITION_#{cond_name}", context, state)
    end)

  {:reply, results ++ synthetic_results, state}
end

@impl true
def handle_call({:condition_state, name}, _from, state) do
  case Map.get(state.condition_servers, name) do
    %{pid: pid} -> {:reply, Anemos.Runtime.ConditionServer.get_state(pid), state}
    nil -> {:reply, nil, state}
  end
end

@impl true
def handle_info({:condition_transition, _name}, state) do
  # Handled synchronously in dispatch via collect_transitions
  {:noreply, state}
end

defp dispatch_to_rules(event_name, context, state) do
  matching = Map.get(state.index, event_name, [])

  Enum.flat_map(matching, fn rule ->
    case safe_handle(rule, event_name, context) do
      {:ok, ops} -> Enum.map(ops, &execute_op(&1, context, state.registry))
      {:error, reason} -> [{:error, {:handler_crash, rule.name, reason}}]
    end
  end)
end

defp collect_transitions do
  collect_transitions([])
end

defp collect_transitions(acc) do
  receive do
    {:condition_transition, name} -> collect_transitions([name | acc])
  after
    0 -> Enum.reverse(acc)
  end
end
```

- [ ] **Step 4: Run tests**

Run: `mix test test/anemos/runtime/dispatcher_test.exs -v`
Expected: All PASS (existing + new).

- [ ] **Step 5: Run full suite**

Run: `mix test -v`
Expected: All PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/anemos/runtime/dispatcher.ex test/anemos/runtime/dispatcher_test.exs
git commit -m "feat: dispatcher routes events to conditions, dispatches synthetic CONDITION_ events"
```

---

## Task 10: Wire demand execution into the dispatcher

When the dispatcher encounters a `:demand` operation during rule execution, it should resolve it through the capability servers using the demand executor.

**Files:**
- Modify: `lib/anemos/runtime/dispatcher.ex`
- Test: `test/anemos/runtime/dispatcher_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/anemos/runtime/dispatcher_test.exs`:

```elixir
test "demand operation invokes capability server and returns result" do
  input = """
  rule demand-test {
    when TEST_EVENT {
      demand test-cap
      log "after demand"
    }
  }
  """

  {:ok, ast} = Parser.parse(input)
  {:ok, %{rules: [compiled_rule]}} = Compiler.compile(ast)

  {:ok, registry} = ModuleRegistry.start_link([])

  {:ok, dispatcher} = Dispatcher.start_link(
    rules: [compiled_rule],
    registry: registry,
    capabilities: [
      %Anemos.CompiledCapability{
        name: "test-cap",
        context: "test",
        handler: fn _ctx -> {:ok, [%{type: :emit, value: "cap-result"}]} end
      }
    ]
  )

  results = Dispatcher.dispatch(dispatcher, "TEST_EVENT")

  # Should have: capability result + log
  assert {:ok, %{type: :emit, value: "cap-result"}} in results
  assert {:ok, %{type: :log, value: "after demand"}} in results
end

test "demand for missing capability returns error" do
  input = """
  rule demand-missing {
    when TEST_EVENT {
      demand nonexistent
    }
  }
  """

  {:ok, ast} = Parser.parse(input)
  {:ok, %{rules: [compiled_rule]}} = Compiler.compile(ast)

  {:ok, registry} = ModuleRegistry.start_link([])

  {:ok, dispatcher} = Dispatcher.start_link(
    rules: [compiled_rule],
    registry: registry,
    capabilities: []
  )

  results = Dispatcher.dispatch(dispatcher, "TEST_EVENT")
  assert [{:error, {:unknown_capability, "nonexistent"}}] = results
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/anemos/runtime/dispatcher_test.exs -v`
Expected: FAIL — demand ops are still passthrough.

- [ ] **Step 3: Update Dispatcher init to start capability servers**

In `lib/anemos/runtime/dispatcher.ex`, accept `:capabilities` option, start capability servers, and resolve demand ops through them:

```elixir
def start_link(opts) do
  rules = Keyword.fetch!(opts, :rules)
  registry = Keyword.fetch!(opts, :registry)
  conditions = Keyword.get(opts, :conditions, [])
  capabilities = Keyword.get(opts, :capabilities, [])
  name = Keyword.get(opts, :name)
  GenServer.start_link(__MODULE__, {rules, registry, conditions, capabilities}, name: name)
end
```

In `init`, start capability servers:

```elixir
capability_servers =
  Map.new(compiled_capabilities, fn cap ->
    {:ok, pid} = Anemos.Runtime.CapabilityServer.start_link(
      name_str: cap.name,
      context: cap.context || "",
      handler: cap.handler
    )
    {cap.name, pid}
  end)
```

Store in state: `capability_servers: capability_servers`.

Update `execute_op` for `:demand`:

```elixir
defp execute_op(%{type: :demand, capability: cap_name}, context, _registry, capability_servers) do
  demands = [%{capability: cap_name, flag: :requisite}]

  case Anemos.Runtime.Demand.evaluate(demands, capability_servers, context) do
    {:ok, ops} -> Enum.map(ops, fn op -> {:ok, op} end)
    {:error, _} = err -> [err]
  end
end
```

Note: `execute_op` needs the `capability_servers` map passed through. Update `dispatch_to_rules` and `execute_op` signatures to include it from state.

- [ ] **Step 4: Run tests**

Run: `mix test test/anemos/runtime/dispatcher_test.exs -v`
Expected: All PASS.

- [ ] **Step 5: Run full suite**

Run: `mix test -v`
Expected: All PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/anemos/runtime/dispatcher.ex test/anemos/runtime/dispatcher_test.exs
git commit -m "feat: dispatcher resolves demand operations through capability servers"
```

---

## Task 11: Wire everything into `Anemos.run/2` and update mix task

Connect the full pipeline: parse -> compile (rules + conditions + capabilities) -> start processes -> dispatch.

**Files:**
- Modify: `lib/anemos.ex`
- Modify: `lib/anemos/application.ex`
- Test: `test/anemos/pipeline_test.exs`

- [ ] **Step 1: Write the end-to-end test**

Add to `test/anemos/pipeline_test.exs`:

```elixir
test "end-to-end: condition triggers rule via synthetic event" do
  input = """
  condition networkchanged {
    when RAW_NETWORK_EVENT {
      log "condition side effect"
    }
  }

  rule react {
    when CONDITION_networkchanged {
      log "rule fired from condition"
    }
  }
  """

  assert {:ok, results} = Anemos.run(input, event: "RAW_NETWORK_EVENT")

  log_values = for %{type: :log, value: v} <- results, do: v
  assert "rule fired from condition" in log_values
end

test "end-to-end: demand invokes capability" do
  input = """
  capability test-cap {
    context test

    on demand {
      log "capability executed"
    }
  }

  rule use-cap {
    when TEST_EVENT {
      demand test-cap
      log "after demand"
    }
  }
  """

  assert {:ok, results} = Anemos.run(input, event: "TEST_EVENT")
  log_values = for r <- results, match?({:ok, %{type: :log}}, r) or match?(%{type: :log}, r), do: r
  assert length(log_values) > 0
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/anemos/pipeline_test.exs -v`
Expected: FAIL — `Anemos.run/2` doesn't use conditions/capabilities yet.

- [ ] **Step 3: Update `Anemos.run/2`**

In `lib/anemos.ex`, update `run/2` to pass compiled conditions and capabilities to the dispatcher:

```elixir
def run(source, opts) do
  event = Keyword.fetch!(opts, :event)
  context = Keyword.get(opts, :context, %{})

  with {:ok, ast} <- Parser.parse(source),
       {:ok, compiled} <- Compiler.compile(ast),
       {:ok, registry} <- ModuleRegistry.start_link([]) do
    try do
      Enum.each(@default_modules, fn {name, mod} ->
        ModuleRegistry.register(registry, name, mod)
      end)

      with {:ok, dispatcher} <-
             Dispatcher.start_link(
               rules: compiled.rules,
               registry: registry,
               conditions: compiled.conditions,
               capabilities: compiled.capabilities
             ) do
        try do
          raw_results = Dispatcher.dispatch(dispatcher, event, context)

          results =
            Enum.flat_map(raw_results, fn
              {:ok, value} -> [value]
              {:error, _} = err -> [err]
            end)

          {:ok, results}
        after
          GenServer.stop(dispatcher)
        end
      end
    after
      Agent.stop(registry)
    end
  end
end
```

- [ ] **Step 4: Run all tests**

Run: `mix test -v`
Expected: All PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/anemos.ex test/anemos/pipeline_test.exs
git commit -m "feat: end-to-end pipeline with conditions and capabilities"
```

---

## Task 12: Parse demand flags and add AST support

Add `--required`, `--optional`, `--sufficient` flag parsing to the demand statement. Default is `:requisite`.

**Files:**
- Modify: `lib/anemos/ast.ex`
- Modify: `lib/anemos/parser.ex`
- Modify: `lib/anemos/compiler.ex`
- Test: `test/anemos/parser_test.exs`

- [ ] **Step 1: Write the failing tests**

Add to `test/anemos/parser_test.exs`:

```elixir
test "parses demand with --optional flag" do
  input = """
  rule flagged {
    when EV {
      demand my-cap --optional
    }
  }
  """

  {:ok, %AST.Program{declarations: [rule]}} = Parser.parse(input)
  [when_block] = rule.body
  [demand] = when_block.body
  assert %AST.Demand{capability: "my-cap", flag: :optional} = demand
end

test "parses demand with --required flag" do
  input = """
  rule flagged {
    when EV {
      demand my-cap --required
    }
  }
  """

  {:ok, %AST.Program{declarations: [rule]}} = Parser.parse(input)
  [when_block] = rule.body
  [demand] = when_block.body
  assert %AST.Demand{capability: "my-cap", flag: :required} = demand
end

test "parses demand with --sufficient flag" do
  input = """
  rule flagged {
    when EV {
      demand my-cap --sufficient
    }
  }
  """

  {:ok, %AST.Program{declarations: [rule]}} = Parser.parse(input)
  [when_block] = rule.body
  [demand] = when_block.body
  assert %AST.Demand{capability: "my-cap", flag: :sufficient} = demand
end

test "bare demand defaults to requisite flag" do
  input = """
  rule bare {
    when EV {
      demand my-cap
    }
  }
  """

  {:ok, %AST.Program{declarations: [rule]}} = Parser.parse(input)
  [when_block] = rule.body
  [demand] = when_block.body
  assert %AST.Demand{capability: "my-cap", flag: :requisite} = demand
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/anemos/parser_test.exs -v`
Expected: FAIL — `Demand` struct has no `flag` field, `--optional` not parsed.

- [ ] **Step 3: Add `flag` field to Demand struct**

In `lib/anemos/ast.ex`:

```elixir
# Before:
defmodule Demand do
  defstruct [:capability, :line]
end

# After:
defmodule Demand do
  defstruct [:capability, :flag, :line]
end
```

- [ ] **Step 4: Update lexer to tokenize `--` flags**

The lexer needs to handle `--required`, `--optional`, `--sufficient` as flag tokens. In `lib/anemos/lexer.ex`, add a combinator for double-dash flags:

Add a new token type. The simplest approach: after parsing the demand identifier, the parser checks if the next tokens form a `--flag` pattern. Since `--` isn't currently a token, add it to the lexer.

Actually, the simpler path: tokenize `--required` etc. as a single `:flag` token. Add a combinator:

```elixir
demand_flag =
  string("--")
  |> choice([string("required"), string("optional"), string("sufficient"), string("requisite")])
  |> tag(:demand_flag_raw)
  |> label("demand flag")
```

Add it to the token choice list (before identifiers). In `build_tokens`:

```elixir
defp build_tokens([{:demand_flag_raw, [_, value]} | rest], line, acc) do
  build_tokens(rest, line, [{:demand_flag, [line: line], String.to_atom(value)} | acc])
end
```

- [ ] **Step 5: Update parser to consume optional flag after demand name**

In `lib/anemos/parser.ex`, update `parse_demand`:

```elixir
defp parse_demand([{:identifier, meta, name} | rest]) do
  {flag, rest} = case rest do
    [{:demand_flag, _, flag_value} | rest] -> {flag_value, rest}
    _ -> {:requisite, rest}
  end

  {:ok, %AST.Demand{capability: name, flag: flag, line: meta[:line]}, rest}
end
```

- [ ] **Step 6: Update compiler to pass flag through to demand operations**

In `lib/anemos/compiler.ex`, update the demand statement handler:

```elixir
defp eval_statement(%AST.Demand{capability: cap, flag: flag}, _context, bindings) do
  {[%{type: :demand, capability: cap, flag: flag || :requisite}], bindings}
end
```

- [ ] **Step 7: Run all tests**

Run: `mix test -v`
Expected: All PASS.

- [ ] **Step 8: Commit**

```bash
git add lib/anemos/ast.ex lib/anemos/lexer.ex lib/anemos/parser.ex lib/anemos/compiler.ex test/anemos/parser_test.exs
git commit -m "feat: demand flags (--required, --optional, --sufficient) with PAM semantics"
```

---

## Task 13: Context filtering on the listener side

Rules and conditions with a `context` path should only react to events that are relevant to their context. The context path filters on the listener side — events carry optional context metadata, and listeners only fire if the event context matches or is within their scope.

**Files:**
- Modify: `lib/anemos/compiler.ex`
- Modify: `lib/anemos/runtime/dispatcher.ex`
- Test: `test/anemos/runtime/dispatcher_test.exs`

- [ ] **Step 1: Write the failing tests**

Add to `test/anemos/runtime/dispatcher_test.exs`:

```elixir
test "rule with context only fires for events in that context" do
  input = """
  rule scoped {
    context "garage.motion" {
      when SENSOR_MOTION_DETECTED {
        log "motion in garage"
      }
    }
  }
  """

  {:ok, ast} = Parser.parse(input)
  {:ok, %{rules: [compiled]}} = Compiler.compile(ast)

  {:ok, registry} = ModuleRegistry.start_link([])
  {:ok, dispatcher} = Dispatcher.start_link(rules: [compiled], registry: registry)

  # Event with matching context fires the rule
  results = Dispatcher.dispatch(dispatcher, "SENSOR_MOTION_DETECTED", %{context_path: "garage.motion"})
  assert [{:ok, %{type: :log, value: "motion in garage"}}] = results

  # Event with wrong context does not fire
  results = Dispatcher.dispatch(dispatcher, "SENSOR_MOTION_DETECTED", %{context_path: "kitchen.motion"})
  assert results == []
end

test "rule with context fires for events in child context" do
  input = """
  rule scoped {
    context "infra.networking" {
      when NETWORK_EVENT {
        log "network"
      }
    }
  }
  """

  {:ok, ast} = Parser.parse(input)
  {:ok, %{rules: [compiled]}} = Compiler.compile(ast)

  {:ok, registry} = ModuleRegistry.start_link([])
  {:ok, dispatcher} = Dispatcher.start_link(rules: [compiled], registry: registry)

  # Child context matches parent listener
  results = Dispatcher.dispatch(dispatcher, "NETWORK_EVENT", %{context_path: "infra.networking.dns"})
  assert [{:ok, %{type: :log, value: "network"}}] = results
end

test "rule without context fires for any event regardless of context" do
  input = """
  rule global {
    when GLOBAL_EVENT {
      log "global"
    }
  }
  """

  {:ok, ast} = Parser.parse(input)
  {:ok, %{rules: [compiled]}} = Compiler.compile(ast)

  {:ok, registry} = ModuleRegistry.start_link([])
  {:ok, dispatcher} = Dispatcher.start_link(rules: [compiled], registry: registry)

  results = Dispatcher.dispatch(dispatcher, "GLOBAL_EVENT", %{context_path: "any.path"})
  assert [{:ok, %{type: :log, value: "global"}}] = results
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/anemos/runtime/dispatcher_test.exs -v`
Expected: FAIL — dispatcher doesn't filter by context.

- [ ] **Step 3: Add context_path to CompiledRule meta**

In `lib/anemos/compiler.ex`, when compiling a rule, extract the context path from `Context` nodes in the rule body and store it in the `CompiledRule.meta`:

```elixir
defp compile_rule(%AST.Rule{name: name, body: body}) do
  context_path = extract_context_path(body)
  when_blocks = extract_when_blocks(body)

  Enum.map(when_blocks, fn %AST.When{event: event, body: when_body} ->
    subscriptions = event_to_subscriptions(event)
    handler = build_handler(when_body)

    %CompiledRule{
      name: name,
      subscriptions: subscriptions,
      handler: handler,
      meta: %{context_path: context_path}
    }
  end)
end

defp extract_context_path(body) do
  Enum.find_value(body, nil, fn
    %AST.Context{path: path} -> path
    _ -> nil
  end)
end
```

- [ ] **Step 4: Add context filtering in dispatcher**

In `lib/anemos/runtime/dispatcher.ex`, update `dispatch_to_rules` to filter by context:

```elixir
defp dispatch_to_rules(event_name, context, state) do
  matching = Map.get(state.index, event_name, [])
  event_context = Map.get(context, :context_path)

  matching
  |> Enum.filter(&context_matches?(&1, event_context))
  |> Enum.flat_map(fn rule ->
    case safe_handle(rule, event_name, context) do
      {:ok, ops} -> Enum.map(ops, &execute_op(&1, context, state.registry))
      {:error, reason} -> [{:error, {:handler_crash, rule.name, reason}}]
    end
  end)
end

defp context_matches?(_rule, nil), do: true

defp context_matches?(rule, event_context) do
  case get_in(rule, [Access.key(:meta), :context_path]) do
    nil -> true
    rule_context -> String.starts_with?(event_context, rule_context)
  end
end
```

- [ ] **Step 5: Run all tests**

Run: `mix test -v`
Expected: All PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/anemos/compiler.ex lib/anemos/runtime/dispatcher.ex test/anemos/runtime/dispatcher_test.exs
git commit -m "feat: context-scoped event filtering on the listener side"
```

---

## Task 14: Full ddns.rule end-to-end integration test

Verify the complete ddns example works: condition fires, rule reacts, demand resolves.

**Files:**
- Modify: `test/anemos/pipeline_test.exs`

- [ ] **Step 1: Write the integration test**

Add to `test/anemos/pipeline_test.exs`:

```elixir
test "ddns.rule: raw event -> condition -> rule with demand" do
  source = File.read!("priv/examples/ddns.rule")
  {:ok, ast} = Anemos.Parser.parse(source)
  {:ok, compiled} = Anemos.Compiler.compile(ast)

  # Verify all three declaration types compiled
  assert length(compiled.rules) == 1
  assert length(compiled.conditions) == 1
  assert length(compiled.capabilities) == 1

  assert hd(compiled.rules).name == "update-ddns"
  assert hd(compiled.conditions).name == "networkchanged"
  assert hd(compiled.capabilities).name == "katachora-ddns-key"

  # Verify condition subscribes to the right events
  assert "INFRA_ip4_addr_changed" in hd(compiled.conditions).subscriptions or
         "INFRA::ip4_addr_changed" in hd(compiled.conditions).subscriptions

  # Verify rule subscribes to CONDITION_networkchanged
  assert "CONDITION_networkchanged" in hd(compiled.rules).subscriptions
end
```

- [ ] **Step 2: Run the test**

Run: `mix test test/anemos/pipeline_test.exs -v`
Expected: All PASS.

- [ ] **Step 3: Commit**

```bash
git add test/anemos/pipeline_test.exs
git commit -m "test: ddns.rule end-to-end integration test"
```

---

## Summary

After all 14 tasks, the Anemos pipeline will support:

1. **Conditions as GenServers** — stateful, broadcast on false->true, queryable
2. **Capabilities as GenServers** — passive, execute on demand
3. **Demand with PAM-style flags** — requisite (default), required, optional, sufficient
4. **Context-scoped filtering** — listeners self-select based on context path
5. **Variable sigil differentiation** — `?` resolves from context data, `@` from let bindings, `$` from set bindings
6. **Context store** — external key-value data for `?` resolution
7. **Full ddns.rule pipeline** — raw event -> condition transition -> synthetic event -> rule fires with demand gating

Policies will mean something.
