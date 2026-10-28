defmodule Anemos.FlowTest do
  # `flow <name> { nextrule ... }` is a stored, ordered workflow of rules
  # taken as a whole; `flow <name>` in a rule body runs it (decided
  # 2026-10-28). The invocation takes no inputs; a step may carry `with`.
  use ExUnit.Case

  alias Anemos.{AST, Parser, Runtime}

  defp syntax_error(source) do
    {:error, %Comn.Errors.ErrorStruct{code: "anemos.parser/syntax_error", message: msg}} =
      Parser.parse(source)

    msg
  end

  defp logs(results), do: for(%{type: :log, value: v} <- results, do: v)
  defp codes(results), do: for({:error, %{code: c}} <- results, do: c)

  describe "parser" do
    test "a flow is an ordered list of nextrule steps" do
      {:ok, %{declarations: [%AST.Flow{name: "deploy", body: steps}]}} =
        Parser.parse(~S|flow deploy { nextrule build  nextrule ship with { env: "prod" } }|)

      assert [
               %AST.NextRule{target: "build", args: nil},
               %AST.NextRule{target: "ship", args: %AST.BlockArgs{}}
             ] =
               steps
    end

    test "a flow body holds steps and nothing else" do
      assert syntax_error(~S|flow f { when EV { log "x" } }|) =~ "when EV { flow f }"
      assert syntax_error(~S|flow f { log "x" }|) =~ "nextrule"
      assert syntax_error(~S|flow f { }|) =~ "no steps"
    end

    test "flow <name> is a statement that takes no inputs" do
      {:ok,
       %{declarations: [%AST.Rule{body: [%AST.When{body: [%AST.FlowCall{name: "deploy"}]}]}]}} =
        Parser.parse(~S|rule go { when GO { flow deploy } }|)

      assert syntax_error(~S|rule go { when GO { flow deploy with { a: 1 } } }|) =~ "inputs"
    end
  end

  describe "runtime" do
    setup %{test: test} do
      name = :"flow_#{:erlang.phash2(test)}"
      start_supervised!({Runtime, name: name})
      %{rt: name}
    end

    @policy ~S"""
    rule build { when BUILD { log "build" } }
    rule test { when TEST { log "test" } }
    rule ship { when SHIP { log ?env } }

    flow release {
      nextrule build
      nextrule test
      nextrule ship with { env: "prod" }
    }

    rule go { when GO { log "start"  flow release  log "end" } }
    """

    test "steps run in order, inside the invoking dispatch", %{rt: rt} do
      :ok = Runtime.load(rt, @policy)
      {:ok, results} = Runtime.dispatch(rt, "GO")
      assert logs(results) == ["start", "build", "test", "prod", "end"]
      assert codes(results) == []
    end

    test "steps see the triggering event's payload; a step's with overrides", %{rt: rt} do
      :ok =
        Runtime.load(rt, ~S"""
        rule who { when WHO { log ?user  log ?env } }
        flow f { nextrule who  nextrule who with { env: "override" } }
        rule go { when GO { flow f } }
        """)

      {:ok, results} =
        Runtime.dispatch(rt, "GO", %{context_data: %{"user" => "ada", "env" => "dev"}})

      assert logs(results) == ["ada", "dev", "ada", "override"]
    end

    test "a step that fails halts the flow", %{rt: rt} do
      :ok =
        Runtime.load(rt, ~S"""
        rule one { when ONE { log "one" } }
        rule three { when THREE { log "three" } }
        flow f { nextrule one  nextrule missing  nextrule three }
        rule go { when GO { flow f  log "after" } }
        """)

      {:ok, results} = Runtime.dispatch(rt, "GO")
      assert logs(results) == ["one", "after"]
      assert codes(results) == ["anemos.runtime/unknown_rule", "anemos.runtime/flow_halted"]

      assert [{:error, %{field: "f/missing"}}] =
               Enum.filter(results, &match?({:error, %{code: "anemos.runtime/flow_halted"}}, &1))
    end

    test "an unknown flow is a runtime error", %{rt: rt} do
      :ok = Runtime.load(rt, ~S|rule go { when GO { flow nope } }|)
      {:ok, results} = Runtime.dispatch(rt, "GO")
      assert [{:error, %{code: "anemos.runtime/unknown_flow", field: "nope"}}] = results
    end

    test "a flow is owned, listed, refused to a second policy, and unloaded", %{rt: rt} do
      :ok = Runtime.load(rt, @policy, policy: "p")

      assert %{flows: [%{name: "release", policy: "p", steps: ["build", "test", "ship"]}]} =
               Runtime.describe(rt)

      assert {:error, %{code: "anemos.runtime/name_taken"}} =
               Runtime.load(rt, ~S|flow release { nextrule build }|, policy: "q")

      :ok = Runtime.unload(rt, "p")
      :ok = Runtime.load(rt, ~S|rule go { when GO { flow release } }|)
      {:ok, results} = Runtime.dispatch(rt, "GO")
      assert codes(results) == ["anemos.runtime/unknown_flow"]
    end

    test "target rules keep their own context boundary", %{rt: rt} do
      :ok =
        Runtime.load(rt, ~S"""
        rule scoped { context "garage" { when EV { log "garage" } } }
        flow f { nextrule scoped }
        rule go { when GO { flow f } }
        """)

      {:ok, outside} = Runtime.dispatch(rt, "GO")
      assert logs(outside) == []

      {:ok, inside} = Runtime.dispatch(rt, "GO", %{context_path: "garage"})
      assert logs(inside) == ["garage"]
    end
  end
end
