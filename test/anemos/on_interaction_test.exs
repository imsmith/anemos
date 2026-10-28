defmodule Anemos.OnInteractionTest do
  # `on <interaction>` versus `when <event>` (decided 2026-10-28). A `when`
  # takes a report: it has a truth, stands until the next report, feeds
  # compound triggers, dwell and conditions. An `on` takes an interaction:
  # an occurrence with no truth, never remembered, fired once per occurrence.
  use ExUnit.Case

  import ExUnit.CaptureLog

  alias Anemos.{AST, Parser, Runtime}

  defp on_blocks(source) do
    {:ok, %{declarations: [%AST.Rule{body: body}]}} = Parser.parse(source)
    for %AST.On{} = on <- body, do: on
  end

  defp syntax_error(source) do
    {:error, %Comn.Errors.ErrorStruct{code: "anemos.parser/syntax_error", message: msg}} =
      Parser.parse(source)

    msg
  end

  describe "parser" do
    test "the four invocation forms" do
      assert [%AST.On{invocation: :boot}] = on_blocks(~S|rule r { on boot { log "b" } }|)
      assert [%AST.On{invocation: :shutdown}] = on_blocks(~S|rule r { on shutdown { log "s" } }|)

      assert [%AST.On{invocation: {:keypress, "ESC"}}] =
               on_blocks(~S|rule r { on keypress "ESC" { log "k" } }|)

      assert [%AST.On{invocation: {:named, "USER_LOGIN"}}] =
               on_blocks(~S|rule r { on USER_LOGIN { log "n" } }|)
    end

    test "unless applies, the report-only modifiers do not" do
      assert [%AST.On{guard: {:unless, _}}] =
               on_blocks(~S|rule r { on boot unless ?quiet { log "b" } }|)

      assert syntax_error(~S|rule r { on boot for 5min { log "b" } }|) =~ "for"
      assert syntax_error(~S|rule r { on boot until ?x { log "b" } }|) =~ "until"
      assert syntax_error(~S|rule r { on (A AND B) { log "b" } }|) =~ "compound"
    end

    test "on demand belongs to a capability" do
      assert syntax_error(~S|rule r { on demand { log "d" } }|) =~ "capability"
    end

    test "ON_ is the interaction namespace, closed to when" do
      assert syntax_error(~S|rule r { when ON_BOOT { log "x" } }|) =~ "on boot"
      assert syntax_error(~S|rule r { when ON_KEYPRESS_ESC { log "x" } }|) =~ "`on`"
    end

    test "on blocks live inside context blocks too" do
      {:ok, %{declarations: [%AST.Rule{body: [%AST.Context{body: [%AST.On{}]}]}]}} =
        Parser.parse(~S|rule r { context "garage" { on boot { log "b" } } }|)
    end
  end

  describe "runtime" do
    setup %{test: test} do
      name = :"on_#{:erlang.phash2(test)}"
      start_supervised!({Runtime, name: name})
      %{rt: name}
    end

    test "boot fires when the policy becomes active, inside its own context", %{rt: rt} do
      log =
        capture_log(fn ->
          :ok =
            Runtime.load(rt, ~S"""
            rule plain { on boot { log "plain booted" } }
            rule scoped { context "garage" { on boot { log "garage booted" } } }
            rule quiet { when EV { log "not an interaction" } }
            """)
        end)

      assert log =~ "plain booted"
      assert log =~ "garage booted"
      refute log =~ "not an interaction"
    end

    test "a keypress and a named interaction reach their on blocks", %{rt: rt} do
      :ok =
        Runtime.load(rt, ~S"""
        rule keys { on keypress "ESC" { log "escape" } }
        rule names { on USER_LOGIN { log "login" } }
        """)

      assert {:ok, [%{type: :log, value: "escape"}]} = Runtime.interact(rt, {:keypress, "ESC"})
      assert {:ok, [%{type: :log, value: "login"}]} = Runtime.interact(rt, "USER_LOGIN")
      assert {:ok, []} = Runtime.interact(rt, {:keypress, "F1"})
    end

    test "an interaction carries payload and honours context", %{rt: rt} do
      :ok =
        Runtime.load(rt, ~S"""
        rule who { context "console" { on USER_LOGIN { log ?user } } }
        """)

      assert {:ok, []} = Runtime.interact(rt, "USER_LOGIN", %{context_data: %{"user" => "ada"}})

      assert {:ok, [%{type: :log, value: "ada"}]} =
               Runtime.interact(rt, "USER_LOGIN", %{
                 context_path: "console",
                 context_data: %{"user" => "ada"}
               })
    end

    test "the report path refuses the interaction namespace", %{rt: rt} do
      :ok = Runtime.load(rt, ~S|rule keys { on keypress "ESC" { log "escape" } }|)

      assert {:ok, [{:error, %Comn.Errors.ErrorStruct{code: "anemos.runtime/reserved_event"}}]} =
               Runtime.dispatch(rt, "ON_KEYPRESS_ESC")

      assert {:ok,
              [{:error, %Comn.Errors.ErrorStruct{code: "anemos.runtime/not_an_interaction"}}]} =
               Runtime.interact(rt, "not-an-ident")
    end

    test "shutdown fires when the policy is unloaded", %{rt: rt} do
      :ok = Runtime.load(rt, ~S|rule r { on shutdown { log "bye" } }|, policy: "p")

      log = capture_log(fn -> :ok = Runtime.unload(rt, "p") end)
      assert log =~ "bye"
      assert {:ok, []} = Runtime.interact(rt, "ANYTHING")
    end

    test "redeploying a changed rule is a shutdown then a boot; unchanged is neither", %{rt: rt} do
      v1 = ~S|rule r { on boot { log "boot v1" } on shutdown { log "bye v1" } }|
      v2 = ~S|rule r { on boot { log "boot v2" } on shutdown { log "bye v2" } }|

      assert capture_log(fn -> :ok = Runtime.load(rt, v1, policy: "p") end) =~ "boot v1"

      same = capture_log(fn -> :ok = Runtime.load(rt, v1, policy: "p") end)
      refute same =~ "boot v1"
      refute same =~ "bye v1"

      changed = capture_log(fn -> :ok = Runtime.load(rt, v2, policy: "p") end)
      assert changed =~ "bye v1"
      assert changed =~ "boot v2"
      refute changed =~ "boot v1"
    end

    test "interactions are not remembered: the same one fires every time", %{rt: rt} do
      :ok = Runtime.load(rt, ~S|rule r { on USER_LOGIN { log "again" } }|)
      assert {:ok, [_]} = Runtime.interact(rt, "USER_LOGIN")
      assert {:ok, [_]} = Runtime.interact(rt, "USER_LOGIN")
    end
  end
end
