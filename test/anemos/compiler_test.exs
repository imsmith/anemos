defmodule Anemos.CompilerTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Anemos.{Compiler, Parser}

  doctest Anemos.Compiler

  test "compiles a rule to a module with handle_event/2" do
    input = """
    rule garage-lights-on {
      when SENSOR_MOTION_DETECTED {
        [DEVICE::set "garage.lights" "on"]
      }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, %{rules: modules}} = Compiler.compile(ast)

    assert [compiled] = modules
    assert compiled.name == "garage-lights-on"
    assert compiled.subscriptions == ["SENSOR_MOTION_DETECTED"]
    assert is_function(compiled.handler, 3)
  end

  test "compiled handler returns operations list" do
    input = """
    rule test-rule {
      when TEST_EVENT {
        [DEVICE::set "light" "on"]
        log "done"
      }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, %{rules: [compiled]}} = Compiler.compile(ast)

    {:ok, ops, _} = compiled.handler.("TEST_EVENT", %{}, %{})

    assert [%{module: "DEVICE", verb: "set", args: ["light", "on"]}, %{type: :log, value: "done"}] =
             ops
  end

  test "if/else handling in compiled handler" do
    input = """
    rule cond-rule {
      when TEST_EVENT {
        if "a" eq "a" {
          log "yes"
        } else {
          log "no"
        }
      }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, %{rules: [compiled]}} = Compiler.compile(ast)

    {:ok, ops, _} = compiled.handler.("TEST_EVENT", %{}, %{})
    assert [%{type: :log, value: "yes"}] = ops
  end

  test "if/else takes else branch when condition is false" do
    input = """
    rule cond-rule {
      when TEST_EVENT {
        if "a" eq "b" {
          log "yes"
        } else {
          log "no"
        }
      }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, %{rules: [compiled]}} = Compiler.compile(ast)

    {:ok, ops, _} = compiled.handler.("TEST_EVENT", %{}, %{})
    assert [%{type: :log, value: "no"}] = ops
  end

  test "let bindings are available as variable references" do
    input = """
    rule let-rule {
      when TEST_EVENT {
        let x = "hello"
        log @x
      }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, %{rules: [compiled]}} = Compiler.compile(ast)

    {:ok, ops, _} = compiled.handler.("TEST_EVENT", %{}, %{})
    assert [%{type: :log, value: "hello"}] = ops
  end

  test "let binding with command produces command operation" do
    input = """
    rule let-cmd-rule {
      when TEST_EVENT {
        let title = [PDF::title]
        log @title
      }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, %{rules: [compiled]}} = Compiler.compile(ast)

    {:ok, ops, _} = compiled.handler.("TEST_EVENT", %{}, %{})
    # let with a command value stores the command op; log resolves $title to it
    assert [
             %{type: :command, module: "PDF", verb: "title", args: []},
             %{type: :log, value: %{type: :command, module: "PDF", verb: "title", args: []}}
           ] = ops
  end

  test "emit operations are compiled" do
    input = """
    rule emit-rule {
      when TEST_EVENT {
        emit [EVENT::fire]
      }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, %{rules: [compiled]}} = Compiler.compile(ast)

    {:ok, ops, _} = compiled.handler.("TEST_EVENT", %{}, %{})

    assert [%{type: :emit, value: %{type: :command, module: "EVENT", verb: "fire", args: []}}] =
             ops
  end

  test "emit with type and label" do
    input = """
    rule emit-typed {
      when TEST_EVENT {
        emit state [EVENT::fire] as :my.label
      }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, %{rules: [compiled]}} = Compiler.compile(ast)

    {:ok, ops, _} = compiled.handler.("TEST_EVENT", %{}, %{})
    assert [%{type: :emit, emit_type: :state, label: "my.label"}] = ops
  end

  test "multiple when blocks in a rule produce multiple compiled rules" do
    input = """
    rule multi-when {
      when EVENT_A {
        log "a"
      }
      when EVENT_B {
        log "b"
      }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, %{rules: modules}} = Compiler.compile(ast)

    assert length(modules) == 2
    [a, b] = modules
    assert a.name == "multi-when"
    assert a.subscriptions == ["EVENT_A"]
    assert b.name == "multi-when"
    assert b.subscriptions == ["EVENT_B"]

    {:ok, ops_a, _} = a.handler.("EVENT_A", %{}, %{})
    assert [%{type: :log, value: "a"}] = ops_a

    {:ok, ops_b, _} = b.handler.("EVENT_B", %{}, %{})
    assert [%{type: :log, value: "b"}] = ops_b
  end

  test "compound event subscriptions" do
    input = """
    rule compound-rule {
      when (INFRA::ip4 OR INFRA::ip6) {
        log "ip changed"
      }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, %{rules: [compiled]}} = Compiler.compile(ast)

    assert compiled.subscriptions == ["INFRA::ip4", "INFRA::ip6"]
  end

  test "demand produces demand operation" do
    input = """
    rule demand-rule {
      when TEST_EVENT {
        demand katachora-ddns-key
      }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, %{rules: [compiled]}} = Compiler.compile(ast)

    {:ok, ops, _} = compiled.handler.("TEST_EVENT", %{}, %{})
    assert [%{type: :demand, capability: "katachora-ddns-key"}] = ops
  end

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

  test "ne comparison in if block" do
    input = """
    rule ne-rule {
      when TEST_EVENT {
        if "a" ne "b" {
          log "different"
        }
      }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, %{rules: [compiled]}} = Compiler.compile(ast)

    {:ok, ops, _} = compiled.handler.("TEST_EVENT", %{}, %{})
    assert [%{type: :log, value: "different"}] = ops
  end

  test "context blocks are traversed for when blocks" do
    input = """
    rule ctx-rule {
      context "garage.motion" {
        when SENSOR_MOTION_DETECTED {
          log "motion"
        }
      }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, %{rules: [compiled]}} = Compiler.compile(ast)

    assert compiled.subscriptions == ["SENSOR_MOTION_DETECTED"]
    {:ok, ops, _} = compiled.handler.("SENSOR_MOTION_DETECTED", %{}, %{})
    assert [%{type: :log, value: "motion"}] = ops
  end

  test "command with var ref argument resolves from let bindings" do
    input = """
    rule varref-rule {
      when TEST_EVENT {
        let name = "world"
        [DEVICE::set "greeting" @name]
      }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, %{rules: [compiled]}} = Compiler.compile(ast)

    {:ok, ops, _} = compiled.handler.("TEST_EVENT", %{}, %{})
    assert [%{type: :command, module: "DEVICE", verb: "set", args: ["greeting", "world"]}] = ops
  end

  # --- Error-path / edge-case tests ---

  test "empty program (no declarations) returns {:ok, []}" do
    ast = %Anemos.AST.Program{declarations: []}
    assert {:ok, %{rules: []}} = Compiler.compile(ast)
  end

  test "rule with no when blocks produces no compiled rules" do
    ast = %Anemos.AST.Program{
      declarations: [
        %Anemos.AST.Rule{
          name: "empty-rule",
          body: [
            %Anemos.AST.Log{expression: %Anemos.AST.Literal{value: "orphan"}}
          ]
        }
      ]
    }

    assert {:ok, %{rules: []}} = Compiler.compile(ast)
  end

  test "unresolvable $nonexistent variable reference returns nil" do
    input = """
    rule varref-missing {
      when TEST_EVENT {
        log $nonexistent
      }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, %{rules: [compiled]}} = Compiler.compile(ast)

    {:ok, ops, _} = compiled.handler.("TEST_EVENT", %{}, %{})
    assert [%{type: :log, value: nil}] = ops
  end

  test "multiple rules in program" do
    input = """
    rule a {
      when X {
        log "a"
      }
    }
    rule b {
      when Y {
        log "b"
      }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, %{rules: modules}} = Compiler.compile(ast)

    assert length(modules) == 2
    names = Enum.map(modules, & &1.name)
    assert "a" in names
    assert "b" in names
  end

  # --- Condition and Capability compilation ---

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

  # --- Variable sigil differentiation ---

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
    context = %{context_data: %{"fqdn" => "host.example.tld"}}
    {:ok, ops, _} = compiled.handler.("TEST_EVENT", context, %{})
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
    {:ok, ops, persistent} = compiled.handler.("TEST_EVENT", %{}, %{})
    assert [%{type: :log, value: "immutable"}] = ops
    assert persistent == %{{:set, "y"} => "mutable"}
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
    {:ok, ops, _} = compiled.handler.("TEST_EVENT", %{context_data: %{}}, %{})
    assert [%{type: :log, value: nil}] = ops
  end

  # --- at block compilation ---

  test "at block in rule produces schedule and rule subscribed to AT_ event" do
    input = """
    rule scheduled {
      at 13:00 {
        log "time"
      }
    }
    """
    {:ok, ast} = Parser.parse(input)
    {:ok, compiled} = Compiler.compile(ast)

    assert length(compiled.schedules) == 1
    [sched] = compiled.schedules
    assert sched.event_name == "AT_13_00"
    assert sched.time_spec == {:time, {13, 0}}
    assert sched.recurrence == nil

    assert length(compiled.rules) == 1
    [rule] = compiled.rules
    assert "AT_13_00" in rule.subscriptions
  end

  test "at interval produces schedule with interval recurrence" do
    input = """
    rule polling {
      at interval(5min) {
        log "tick"
      }
    }
    """
    {:ok, ast} = Parser.parse(input)
    {:ok, compiled} = Compiler.compile(ast)

    assert length(compiled.schedules) == 1
    [sched] = compiled.schedules
    assert sched.event_name == "AT_INTERVAL_5min"
    assert sched.time_spec == {:interval, {5, :min}}
    assert sched.recurrence == :interval
  end

  test "at with every produces recurring schedule" do
    input = """
    rule daily {
      at 09:00 every day {
        log "morning"
      }
    }
    """
    {:ok, ast} = Parser.parse(input)
    {:ok, compiled} = Compiler.compile(ast)

    [sched] = compiled.schedules
    assert sched.event_name == "AT_09_00"
    assert sched.time_spec == {:time, {9, 0}}
    assert sched.recurrence == :day
  end

  test "at in condition produces schedule" do
    input = """
    condition statuscheck {
      at 11:00 every weekday {
        log "checking"
      }
    }
    """
    {:ok, ast} = Parser.parse(input)
    {:ok, compiled} = Compiler.compile(ast)

    assert length(compiled.schedules) == 1
    [sched] = compiled.schedules
    assert sched.event_name == "AT_11_00"
    assert sched.recurrence == :weekday
  end

  test "rule with both when and at blocks" do
    input = """
    rule mixed {
      when EVENT_A {
        log "event"
      }
      at 09:00 {
        log "morning"
      }
    }
    """
    {:ok, ast} = Parser.parse(input)
    {:ok, compiled} = Compiler.compile(ast)

    assert length(compiled.rules) == 2
    assert length(compiled.schedules) == 1
  end

  # --- Data and Query block compilation ---

  test "compiles simple data block" do
    input = """
    data test-list {
      alpha
      bravo
      charlie
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, result} = Compiler.compile(ast)

    assert [data] = result.data_blocks
    assert data.name == "test-list"
    assert data.scope == :global
    assert MapSet.member?(data.dataset, "alpha")
    assert MapSet.member?(data.dataset, "bravo")
    assert MapSet.member?(data.dataset, "charlie")
  end

  test "compiles data block with format block" do
    input = ~s|data stuff { edn { {:key "value"} } }|

    {:ok, ast} = Parser.parse(input)
    {:ok, result} = Compiler.compile(ast)

    assert [data] = result.data_blocks
    assert data.name == "stuff"
    assert data.format == "edn"
    assert is_binary(data.raw)
  end

  test "compiles query block" do
    input = """
    query find-user {
      expect :name
      users {
        lookup ?name
      }
      return ?user
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, result} = Compiler.compile(ast)

    assert [query] = result.query_blocks
    assert query.name == "find-user"
    assert query.expect == [:name]
    assert query.engine == "users"
    assert query.return == "user"
    assert is_function(query.handler, 2)
  end

  test "compiles data and query alongside rules" do
    input = """
    data users {
      alice
      bob
    }
    query find {
      expect :name
      db { select ?name }
      return ?user
    }
    rule check {
      when EV { log "ok" }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, result} = Compiler.compile(ast)

    assert length(result.data_blocks) == 1
    assert length(result.query_blocks) == 1
    assert length(result.rules) == 1
  end

  # --- Pipe operator and built-in function evaluation ---

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

  test "warns on dynamic inline data block" do
    import ExUnit.CaptureLog

    input = """
    rule check {
      data live-feed {
        dynamic {
          subscribe webhook "https://example.com/feed"
        }
      }
      when EVENT {
        log "ok"
      }
    }
    """

    {:ok, ast} = Parser.parse(input)

    log =
      capture_log(fn ->
        {:ok, _result} = Compiler.compile(ast)
      end)

    assert log =~ "dynamic"
    assert log =~ "live-feed"
  end

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
end
