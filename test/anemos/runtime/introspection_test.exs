defmodule Anemos.Runtime.IntrospectionTest do
  @moduledoc """
  What is loaded, what an event would do, and what the last events did —
  read off the running system.
  """
  use ExUnit.Case, async: false

  alias Anemos.Runtime

  defmodule Failing do
    @moduledoc false
    @behaviour Anemos.Runtime.Module

    @impl true
    def handle_verb(_verb, _args, _context), do: {:error, {:refused, "s3cret-token"}}
  end

  setup context do
    name = :"in_#{:erlang.phash2(context.test)}"
    start_supervised!({Runtime, name: name})
    %{rt: name}
  end

  @policy """
  rule count {
    when TICK {
      set seen = "yes"
      log "tick"
    }
    at 08:00 { log "morning" }
  }

  rule garage {
    context "home.garage" {
      when MOTION { log "garage" }
    }
  }

  rule steady { when DOOR for 300s { log "open too long" } }

  condition hot { when TEMP { log "c" } }
  capability k { on demand { log "k" } }
  data users { alice }
  """

  describe "describe/1" do
    test "reports every declaration with its policy and its current state", %{rt: rt} do
      :ok = Runtime.register(rt, "FAIL", Failing)
      :ok = Runtime.load(rt, @policy, policy: "home.rule")
      Runtime.dispatch(rt, "TICK")
      Runtime.dispatch(rt, "TEMP")
      Runtime.dispatch(rt, "DOOR")

      d = Runtime.describe(rt)

      assert [%{id: "home.rule"}] = d.policies
      assert d.modules == ["FAIL", "POLICY"]

      rules = Map.new(d.rules, &{&1.name, &1})

      assert %{policy: "home.rule", events: ["TICK"], bindings: %{"seen" => "yes"}} =
               rules["count"]

      assert %{context: "home.garage", events: ["MOTION"], bindings: %{}} = rules["garage"]

      assert %{dwell_ms: 300_000, dwell: [%{event: "DOOR", state: :armed}], bindings: %{}} =
               rules["steady"]

      assert [%{name: "hot", policy: "home.rule", events: ["TEMP"], value: true}] = d.conditions
      assert [%{name: "k", policy: "home.rule"}] = d.capabilities
      assert [%{name: "users", policy: "home.rule"}] = d.data_blocks
      assert [%{event: "AT_" <> _, recurrence: _}] = d.schedules
    end

    test "an anonymous load has no policy", %{rt: rt} do
      :ok = Runtime.load(rt, ~s|rule a { when EV { log "a" } }|)
      assert [%{name: "a", policy: nil}] = Runtime.describe(rt).rules
    end
  end

  describe "explain/3" do
    test "says what an event would do, without doing it", %{rt: rt} do
      :ok = Runtime.load(rt, @policy, policy: "home.rule")

      assert %{rules: [%{rule: "count", policy: "home.rule", outcome: :fires}], conditions: []} =
               Runtime.explain(rt, "TICK")

      assert %{rules: [%{rule: "steady", outcome: {:dwell, 300_000}}]} =
               Runtime.explain(rt, "DOOR")

      assert %{rules: [], conditions: ["hot"]} = Runtime.explain(rt, "TEMP")
      assert %{rules: [], conditions: []} = Runtime.explain(rt, "NOTHING")

      # Nothing ran.
      assert Runtime.describe(rt).rules |> Enum.all?(&(&1.bindings == %{} and &1.dwell == []))
      assert Runtime.trace(rt) == []
    end

    test "a rule the context filter would stop is reported, with the reason", %{rt: rt} do
      :ok = Runtime.load(rt, @policy, policy: "home.rule")

      assert %{rules: [%{rule: "garage", outcome: :context_mismatch, context: "home.garage"}]} =
               Runtime.explain(rt, "MOTION", %{context_path: "office"})

      assert %{rules: [%{rule: "garage", outcome: :fires}]} =
               Runtime.explain(rt, "MOTION", %{context_path: "home.garage"})
    end
  end

  describe "trace/2" do
    test "records each dispatch, newest first", %{rt: rt} do
      :ok = Runtime.load(rt, @policy, policy: "home.rule")
      Runtime.dispatch(rt, "TICK")
      Runtime.dispatch(rt, "MOTION", %{context_path: "office"})
      Runtime.dispatch(rt, "TEMP")

      assert [temp, motion, tick] = Runtime.trace(rt)

      assert %{
               event: "TICK",
               steps: [%{rule: "count", event: "TICK", outcome: :fired}],
               results: [%{type: :log, value: "tick"}],
               at: %DateTime{},
               duration_us: us
             } = tick

      assert is_integer(us)

      assert %{
               event: "MOTION",
               context_path: "office",
               steps: [%{rule: "garage", outcome: :context_mismatch}],
               results: []
             } = motion

      assert %{event: "TEMP", conditions: ["hot"]} = temp
      assert [%{event: "TEMP"}] = Runtime.trace(rt, 1)
    end

    test "an event nothing listens to is still recorded", %{rt: rt} do
      Runtime.dispatch(rt, "NOBODY")
      assert [%{event: "NOBODY", steps: [], results: []}] = Runtime.trace(rt)
    end

    test "a rule one rule sends to appears as a step of the same dispatch", %{rt: rt} do
      :ok =
        Runtime.load(rt, """
        rule first { when EV { nextevent SECOND } }
        rule second { when SECOND { log "second" } }
        """)

      Runtime.dispatch(rt, "EV")

      assert [%{event: "EV", steps: steps}] = Runtime.trace(rt)
      assert Enum.map(steps, &{&1.rule, &1.event}) == [{"first", "EV"}, {"second", "SECOND"}]
    end

    test "a failed verb is recorded by kind, without what the host said", %{rt: rt} do
      :ok = Runtime.register(rt, "FAIL", Failing)
      :ok = Runtime.load(rt, ~s|rule r { when EV { [FAIL::go] } }|)
      Runtime.dispatch(rt, "EV")

      assert [%{results: [%{type: :error} = result]}] = Runtime.trace(rt)
      refute inspect(result) =~ "s3cret-token"
    end

    test "a verb that answers something other than a tuple does not take the dispatcher down",
         %{rt: rt} do
      defmodule Bare do
        @moduledoc false
        @behaviour Anemos.Runtime.Module
        @impl true
        def handle_verb(_verb, _args, _context), do: :ok
      end

      :ok = Runtime.register(rt, "BARE", Bare)
      :ok = Runtime.load(rt, ~s|rule r { when EV { [BARE::go] } }|)
      dispatcher = Process.whereis(:"#{rt}.dispatcher")

      ExUnit.CaptureLog.capture_log(fn ->
        try do
          Runtime.dispatch(rt, "EV")
        rescue
          _ -> :ok
        catch
          _, _ -> :ok
        end
      end)

      assert Process.whereis(:"#{rt}.dispatcher") == dispatcher
    end

    test "is empty for a runtime that is not running" do
      assert Runtime.trace(:no_such_runtime) == []
    end

    test "is bounded", %{rt: rt} do
      for _ <- 1..250, do: Runtime.dispatch(rt, "EV")
      assert length(Runtime.trace(rt, 1_000)) == 200
    end

    test "survives the dispatcher", %{rt: rt} do
      Runtime.dispatch(rt, "EV")
      dispatcher = :"#{rt}.dispatcher"
      old = Process.whereis(dispatcher)
      ref = Process.monitor(old)
      Process.exit(old, :kill)
      assert_receive {:DOWN, ^ref, _, _, _}

      assert [%{event: "EV"}] = Runtime.trace(rt)
    end
  end
end
