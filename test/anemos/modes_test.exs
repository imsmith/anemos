defmodule Anemos.ModesTest do
  @moduledoc """
  PRD §3.2 and §3.13: `it <mode>` scopes triggers to a mode, `as "<mode>"`
  runs on entering one, `by <identity> that { ... }` is an attributed block
  that runs on entering its `it`. Modes are switched by `[MODE::set ...]`
  and `[MODE::unset ...]`. `with` fans a body out concurrently.
  """
  use ExUnit.Case

  alias Anemos.{AST, Parser, Runtime}

  doctest Anemos.Runtime.Modes

  defp syntax_error(source) do
    {:error, %Comn.Errors.ErrorStruct{code: "anemos.parser/syntax_error", message: msg}} =
      Parser.parse(source)

    msg
  end

  defp logs(results), do: for(%{type: :log, value: v} <- results, do: v)
  defp codes(results), do: for({:error, %{code: c}} <- results, do: c)

  describe "parser" do
    test "it <mode> holds trigger blocks and attribution blocks" do
      {:ok, %{declarations: [%AST.Rule{body: [it]}]}} =
        Parser.parse(~S"""
        rule r {
          it away_mode {
            when DOOR_OPENED { log "door" }
            by meshid.ian that { log "duty" }
            as "night" { log "night" }
          }
        }
        """)

      assert %AST.It{modal_ref: {"away_mode", nil}, body: [%AST.When{}, by, %AST.As{}]} = it
      assert %AST.By{identity: "meshid.ian", body: [%AST.Log{}]} = by
    end

    test "it <mode> = <literal> names a valued mode" do
      {:ok, %{declarations: [%AST.Rule{body: [%AST.It{modal_ref: {"level", 2}}]}]}} =
        Parser.parse(~S|rule r { it level = 2 { when EV { log "x" } } }|)
    end

    test "a top-level it is a rule named for its mode" do
      {:ok, %{declarations: [%AST.Rule{name: "it_away_mode", body: [%AST.It{}]}]}} =
        Parser.parse(~S|it away_mode { when DOOR_OPENED { log "door" } }|)
    end

    test "an it body refuses plain statements" do
      assert syntax_error(~S|rule r { it m { log "x" } }|) =~ "it m"
    end

    test "as takes a quoted mode name" do
      {:ok, %{declarations: [%AST.Rule{body: [%AST.As{mode: "away", body: [_]}]}]}} =
        Parser.parse(~S|rule r { as "away" { log "x" } }|)
    end

    test "with each and with { } are fan-out statements" do
      {:ok, %{declarations: [%AST.Rule{body: [%AST.When{body: [each, block]}]}]}} =
        Parser.parse(~S"""
        rule r {
          when EV {
            with each x in ("a" "b") { log @x }
            with { log "1"  log "2" }
          }
        }
        """)

      assert %AST.With{var: "x", body: [%AST.Log{}]} = each
      assert %AST.With{var: nil, body: [%AST.Log{}, %AST.Log{}]} = block
    end

    test "with refuses set, and the group forms nothing backs" do
      assert syntax_error(~S|rule r { when EV { with { set n = 1 } } }|) =~ "set"
      assert syntax_error(~S|rule r { when EV { with agents [a] { log "x" } } }|) =~ "agents"

      assert syntax_error(~S|rule r { when EV { with lights tagged "g" { log "x" } } }|) =~
               "tagged"
    end
  end

  describe "runtime" do
    setup %{test: test} do
      name = :"modes_#{:erlang.phash2(test)}"
      start_supervised!({Runtime, name: name})
      %{rt: name}
    end

    @policy ~S"""
    rule switch {
      when AWAY { [MODE::set "away_mode"] }
      when HOME { [MODE::unset "away_mode"] }
    }

    it away_mode {
      when DOOR_OPENED { log "door opened while away" }
    }

    rule always { when DOOR_OPENED { log "door" } }
    """

    test "it triggers are live only while the mode is active", %{rt: rt} do
      :ok = Runtime.load(rt, @policy)

      {:ok, r} = Runtime.dispatch(rt, "DOOR_OPENED")
      assert logs(r) == ["door"]

      {:ok, _} = Runtime.dispatch(rt, "AWAY")
      {:ok, r} = Runtime.dispatch(rt, "DOOR_OPENED")
      assert Enum.sort(logs(r)) == ["door", "door opened while away"]

      {:ok, _} = Runtime.dispatch(rt, "HOME")
      {:ok, r} = Runtime.dispatch(rt, "DOOR_OPENED")
      assert logs(r) == ["door"]
    end

    test "as and by run once on entering the mode, in the setter's dispatch", %{rt: rt} do
      :ok =
        Runtime.load(rt, ~S"""
        rule switch { when AWAY { [MODE::set "away"] } when HOME { [MODE::unset "away"] } }
        rule lights { as "away" { log "lights off" } }
        it away { by meshid.ian that { log "arm alarm" } }
        """)

      {:ok, r} = Runtime.dispatch(rt, "AWAY")
      assert Enum.sort(logs(r)) == ["arm alarm", "lights off"]

      {:ok, r} = Runtime.dispatch(rt, "AWAY")
      assert logs(r) == []

      {:ok, _} = Runtime.dispatch(rt, "HOME")
      {:ok, r} = Runtime.dispatch(rt, "AWAY")
      assert Enum.sort(logs(r)) == ["arm alarm", "lights off"]
    end

    test "a valued mode gates on its value", %{rt: rt} do
      :ok =
        Runtime.load(rt, ~S"""
        rule switch { when SET { [MODE::set "level" ?v] } }
        it level = 2 { when EV { log "two" } as "level" { log "entered" } }
        """)

      {:ok, _} = Runtime.dispatch(rt, "SET", %{context_data: %{"v" => 1}})
      {:ok, r} = Runtime.dispatch(rt, "EV")
      assert logs(r) == []

      {:ok, r} = Runtime.dispatch(rt, "SET", %{context_data: %{"v" => 2}})
      assert logs(r) == ["entered"]
      {:ok, r} = Runtime.dispatch(rt, "EV")
      assert logs(r) == ["two"]
    end

    test "MODE::active and MODE::current read modes as values", %{rt: rt} do
      :ok =
        Runtime.load(rt, ~S"""
        rule switch { when SET { [MODE::set "away" "weekend"] } }
        rule ask {
          when ASK {
            if [MODE::active "away"] { log [MODE::current "away"] } else { log "home" }
          }
        }
        """)

      {:ok, r} = Runtime.dispatch(rt, "ASK")
      assert logs(r) == ["home"]
      {:ok, _} = Runtime.dispatch(rt, "SET")
      {:ok, r} = Runtime.dispatch(rt, "ASK")
      assert logs(r) == ["weekend"]
      assert %{modes: %{"away" => "weekend"}} = Runtime.describe(rt)
    end

    test "entering a mode respects the listener's context", %{rt: rt} do
      :ok =
        Runtime.load(rt, ~S"""
        rule switch { when AWAY { [MODE::set "away"] } }
        rule garage { context "garage" { as "away" { log "garage" } } }
        """)

      {:ok, r} = Runtime.dispatch(rt, "AWAY", %{context_path: "kitchen"})
      assert logs(r) == []
    end

    test "a bad MODE call is a structured error", %{rt: rt} do
      :ok =
        Runtime.load(rt, ~S"""
        rule bad { when EV { [MODE::set] } }
        rule worse { when EV2 { let x = [MODE::set "m"] } }
        """)

      {:ok, r} = Runtime.dispatch(rt, "EV")
      assert codes(r) == ["anemos.runtime/bad_mode_call"]
      {:ok, r} = Runtime.dispatch(rt, "EV2")
      assert codes(r) == ["anemos.runtime/bad_mode_call"]
    end

    test "with fans a body out over a collection, in order", %{rt: rt} do
      :ok =
        Runtime.load(rt, ~S"""
        rule fan {
          when EV {
            with each light in ("a" "b" "c") { log @light }
            with { log "one"  log "two" }
          }
        }
        """)

      {:ok, r} = Runtime.dispatch(rt, "EV")
      assert logs(r) == ["a", "b", "c", "one", "two"]
    end

    test "a branch that aborts stops the body at that branch", %{rt: rt} do
      :ok =
        Runtime.load(rt, ~S"""
        rule fan { when EV { with { log "one"  done  log "three" } log "after" } }
        rule bad { when EV2 { with each x in (1 2) { log [MODE::set "m"] } } }
        """)

      {:ok, r} = Runtime.dispatch(rt, "EV")
      assert logs(r) == ["one"]

      {:ok, r} = Runtime.dispatch(rt, "EV2")
      assert codes(r) == ["anemos.runtime/bad_mode_call"]
    end

    test "modes survive a dispatcher restart", %{rt: rt} do
      :ok = Runtime.load(rt, @policy)
      {:ok, _} = Runtime.dispatch(rt, "AWAY")

      pid = Process.whereis(:"#{rt}.dispatcher")
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, _, _, _}
      Process.sleep(50)

      assert %{modes: %{"away_mode" => true}} = Runtime.describe(rt)
    end
  end
end
