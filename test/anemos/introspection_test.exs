defmodule Anemos.IntrospectionTest do
  @moduledoc """
  The introspection statements, grounded in Comn's look / recon / choices:
  what a rule can learn about a module, an event, a catalogue, or a value.
  """
  use ExUnit.Case, async: false

  alias Anemos.{AST, Parser, Runtime}

  defmodule Described do
    @moduledoc false
    @behaviour Anemos.Runtime.Module
    @impl true
    def handle_verb(verb, _args, _ctx), do: {:ok, verb}
    @impl true
    def describe(name),
      do: %{look: "#{name}, described per name", recon: %{name: name}, choices: %{verbs: ["go"]}}
  end

  defmodule Comnish do
    @moduledoc false
    @behaviour Anemos.Runtime.Module
    @behaviour Comn
    @impl Anemos.Runtime.Module
    def handle_verb(verb, _args, _ctx), do: {:ok, verb}
    @impl Comn
    def look, do: "Comnish — answers through Comn"
    @impl Comn
    def recon, do: %{type: :implementation, verbs: ["go"]}
    @impl Comn
    def choices, do: %{verbs: ["go"]}
    @impl Comn
    def act(_), do: {:error, :not_implemented}
  end

  setup context do
    rt = :"in_#{:erlang.phash2(context.test)}"
    start_supervised!({Runtime, name: rt})
    :ok = Runtime.register(rt, "DESCRIBED", Described)
    :ok = Runtime.register(rt, "COMNISH", Comnish)
    %{rt: rt}
  end

  defp run(rt, body, facts \\ %{}) do
    :ok = Runtime.load(rt, "rule r { when EV {\n#{body}\n} }")
    {:ok, results} = Runtime.dispatch(rt, "EV", %{context_data: facts})
    results
  end

  describe "parsing" do
    test "a bare NAME, a catalogue word, and an expression are three subjects" do
      {:ok, %AST.Program{declarations: [rule]}} =
        Parser.parse("rule r { when EV { show DEVICE\n list rules\n explain ?x } }")

      [%AST.When{body: [a, b, c]}] = rule.body
      assert %AST.Introspect{verb: :show, subject: {:name, "DEVICE"}} = a
      assert %AST.Introspect{verb: :list, subject: {:catalogue, :rules}} = b
      assert %AST.Introspect{verb: :explain, subject: {:expr, %AST.VarRef{name: "x"}}} = c
    end

    test "assert always takes an expression, and exists is also a value" do
      {:ok, %AST.Program{declarations: [rule]}} =
        Parser.parse("rule r { when EV { assert ?x\n if exists ?x { log 1 } } }")

      [%AST.When{body: [a, i]}] = rule.body
      assert %AST.Introspect{verb: :assert, subject: {:expr, _}} = a
      assert %AST.If{condition: %AST.Introspect{verb: :exists, subject: {:expr, _}}} = i
    end
  end

  describe "a module" do
    test "answers look, recon and choices through describe/1, per name", %{rt: rt} do
      assert [
               %{type: :show, found: :module, value: "DESCRIBED, described per name"},
               %{type: :explain, value: %{name: "DESCRIBED"}},
               %{type: :list, value: %{verbs: ["go"]}},
               %{type: :exists, value: true}
             ] = run(rt, "show DESCRIBED\n explain DESCRIBED\n list DESCRIBED\n exists DESCRIBED")
    end

    test "or through Comn", %{rt: rt} do
      assert [
               %{value: "Comnish — answers through Comn"},
               %{value: %{type: :implementation, verbs: ["go"]}}
             ] =
               run(rt, "show COMNISH\n explain COMNISH")
    end

    test "or from what the runtime knows", %{rt: rt} do
      assert [%{value: "POLICY — " <> _}] = run(rt, "show POLICY")
    end
  end

  describe "an event" do
    test "is found by its listeners", %{rt: rt} do
      :ok =
        Runtime.load(rt, ~s|rule other { when EV { log 1 } }\ncondition c { when EV { log 2 } }|)

      results = run(rt, "show EV\n explain EV\n list EV\n exists EV")
      answers = Map.new(for %{found: :event, type: type} = a <- results, do: {type, a})

      assert %{value: "event EV: 2 rules and 1 condition listen"} = answers.show
      assert %{value: %{rules: rules, conditions: ["c"]}} = answers.explain
      assert Enum.sort(rules) == ["other", "r"]
      assert Enum.sort(answers.list.value) == ["c", "other", "r"]
      assert %{value: true} = answers.exists
    end

    test "a name that is neither module nor event", %{rt: rt} do
      assert [%{found: nil, value: "NOPE: no module" <> _}, %{type: :exists, value: false}] =
               run(rt, "show NOPE\n exists NOPE")
    end
  end

  describe "a catalogue" do
    test "rules, modules, events, policies, conditions", %{rt: rt} do
      :ok = Runtime.load(rt, ~s|condition hot { when TEMP { log 1 } }|, policy: "p")

      assert [
               %{type: :list, value: ["r"]},
               %{type: :show, value: "3 modules: COMNISH, DESCRIBED, POLICY"},
               %{
                 type: :explain,
                 value: [%{name: "EV", rules: ["r"]}]
               },
               %{type: :list, value: ["p", "(anonymous)"]},
               %{type: :explain, value: [%{name: "hot", value: false}]}
             ] =
               run(
                 rt,
                 "list rules\n show modules\n explain events\n list policies\n explain conditions"
               )
    end
  end

  describe "a value" do
    test "show, infer, list, exists, trace", %{rt: rt} do
      facts = %{"who" => "ian", "items" => [1, 2], "map" => %{"k" => 1}}

      assert [
               %{type: :show, value: "ian", text: "?who"},
               %{type: :infer, value: %{kind: :string, length: 3}},
               %{type: :list, value: [1, 2]},
               %{type: :list, value: ["k"]},
               %{type: :exists, value: false, text: "?missing"},
               %{type: :trace, value: "ian"},
               %{type: :infer, value: %{kind: :nothing}}
             ] =
               run(
                 rt,
                 "show ?who\n infer ?who\n list ?items\n list ?map\n exists ?missing\n trace ?who\n infer ?missing",
                 facts
               )
    end

    test "graph answers the triples a value is in", %{rt: rt} do
      assert [_assert, %{type: :graph, value: [["a", "knows", "b"]]}] =
               run(rt, ~s|let [:a -> :knows -> :b]\n graph "a"|)
    end

    test "a secret shows wrapped", %{rt: rt} do
      secret = Anemos.Secret.new("hunter2", label: "k")

      [%{type: :show, value: shown}, %{type: :infer, value: kind}] =
        run(rt, "show ?s\n infer ?s", %{"s" => secret})

      refute inspect(shown) =~ "hunter2"
      assert kind == %{kind: :secret}
    end
  end

  describe "exists as a value and assert" do
    test "exists guards a branch", %{rt: rt} do
      assert [%{type: :log, value: "bound"}, %{type: :log, value: "module"}] =
               run(
                 rt,
                 ~s|if exists ?who { log "bound" }\n if exists ?nope { log "no" }\n if exists DESCRIBED { log "module" }\n if exists NOPE { log "no" }|,
                 %{"who" => "x"}
               )
    end

    test "a held assertion passes through; a failed one stops the rule and says so", %{rt: rt} do
      assert [
               %{type: :assert, held: true},
               %{type: :log, value: "on"},
               %{type: :assert, held: false, text: "?nope"}
             ] =
               run(rt, ~s|assert ?who == "x"\n log "on"\n assert ?nope\n log "never"|, %{
                 "who" => "x"
               })
    end

    test "other rules still run after a failed assertion", %{rt: rt} do
      :ok = Runtime.load(rt, ~s|rule other { when EV { log "other" } }|)
      results = run(rt, "assert ?nope")
      assert %{type: :log, value: "other"} in results
    end
  end

  test "introspection values are kept in the trace", %{rt: rt} do
    run(rt, "show ?who\n assert ?who", %{"who" => "ian"})

    assert [
             %{
               results: [
                 %{type: :show, subject: "?who", value: "ian"},
                 %{type: :assert, held: true}
               ]
             }
           ] =
             Runtime.trace(rt, 1)
  end
end
