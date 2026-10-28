defmodule Anemos.Runtime.DispatcherDisclosureTest do
  use ExUnit.Case, async: false

  @moduledoc """
  A-52 — the three remaining disclosure sites in the dispatcher.

  Sibling of A-09. Each test puts a marker string somewhere a policy author
  or a failing subsystem controls, then asserts the marker never reaches the
  log. What replaces it must still be enough to investigate with, so each
  test also asserts that *something* identifying survives.
  """

  import ExUnit.CaptureLog

  alias Anemos.Compiler
  alias Anemos.Parser
  alias Anemos.Runtime.{Dispatcher, ModuleRegistry, SubscribableRegistry}

  # A subscribable whose subscribe/3 fails with a reason carrying a
  # credential — which is exactly the shape of a real broker rejection.
  defmodule LeakySubscribable do
    @moduledoc false
    @behaviour Anemos.Subscribable

    @impl true
    def subscribe(_protocol, _uri, _callback), do: {:error, {:auth_failed, "hunter2-secret"}}

    @impl true
    def unsubscribe(_ref), do: :ok
  end

  defp dispatcher_for(source, opts \\ []) do
    {:ok, ast} = Parser.parse(source)
    {:ok, compiled} = Compiler.compile(ast)
    {:ok, registry} = ModuleRegistry.start_link([])

    {:ok, dispatcher} =
      Anemos.Runtime.Standalone.start_link([rules: compiled.rules, registry: registry] ++ opts)

    {dispatcher, compiled}
  end

  describe "site 1 — the log operation" do
    # `log` prints verbatim by design; see the comment on the `:log` clause
    # in the dispatcher. The control on this path is `Anemos.Secret`, and
    # these two tests pin that it actually works here rather than in theory.

    test "an authored log value is printed, because that is what log is for" do
      {dispatcher, _} =
        dispatcher_for("""
        rule plain-log {
          when EV {
            log "starting sync"
          }
        }
        """)

      log = capture_log(fn -> Dispatcher.dispatch(dispatcher, "EV") end)
      assert log =~ "starting sync"
    end

    test "a wrapped secret interpolates as [REDACTED] on this exact path" do
      rule = %Anemos.CompiledRule{
        name: "secret-log",
        subscriptions: ["EV"],
        meta: %{},
        handler: fn _event, _ctx, bindings ->
          value = Anemos.Secret.new("hunter2-secret", label: "ddns-key")
          {:ok, [%{type: :log, value: value}], bindings}
        end
      }

      {:ok, registry} = ModuleRegistry.start_link([])

      {:ok, dispatcher} =
        Anemos.Runtime.Standalone.start_link(rules: [rule], registry: registry)

      log = capture_log(fn -> Dispatcher.dispatch(dispatcher, "EV") end)

      refute log =~ "hunter2-secret"
      assert log =~ "[REDACTED]"
    end
  end

  describe "site 2 — handler crash reporting" do
    setup do
      rule = %Anemos.CompiledRule{
        name: "crasher",
        subscriptions: ["EV"],
        meta: %{},
        handler: fn _event, _ctx, _bindings ->
          raise ArgumentError, "bad arg: hunter2-secret"
        end
      }

      {:ok, registry} = ModuleRegistry.start_link([])

      {:ok, dispatcher} =
        Anemos.Runtime.Standalone.start_link(rules: [rule], registry: registry)

      %{dispatcher: dispatcher}
    end

    test "the crash reason does not reach the returned error message", %{dispatcher: dispatcher} do
      {results, log} = with_log(fn -> Dispatcher.dispatch(dispatcher, "EV") end)

      assert [{:error, err}] = results
      assert err.code == "anemos.runtime/handler_crash"
      refute err.message =~ "hunter2-secret"

      # Whoever holds the error must still be able to find the detail.
      assert is_binary(err.request_id)
      assert err.message =~ err.request_id

      refute log =~ "hunter2-secret"
    end

    test "the crash detail is logged against the correlation id, redacted",
         %{dispatcher: dispatcher} do
      {[{:error, err}], log} = with_log(fn -> Dispatcher.dispatch(dispatcher, "EV") end)

      assert log =~ err.request_id
      assert log =~ "crasher"
      assert log =~ "ArgumentError"
    end

    test "detail is restored only by an explicit operator opt-in", %{dispatcher: dispatcher} do
      Application.put_env(:anemos, :log_crash_detail, true)
      on_exit(fn -> Application.delete_env(:anemos, :log_crash_detail) end)

      {_results, log} = with_log(fn -> Dispatcher.dispatch(dispatcher, "EV") end)
      assert log =~ "hunter2-secret"
    end
  end

  describe "site 3 — data block subscription failure" do
    test "a subscribe failure reason does not reach the log" do
      {:ok, registry} = ModuleRegistry.start_link([])
      {:ok, sub_registry} = SubscribableRegistry.start_link()
      :ok = SubscribableRegistry.register(sub_registry, "leaky", LeakySubscribable)

      {dispatcher, compiled} =
        dispatcher_for(
          """
          data feed {
            dynamic {
              subscribe leaky "test://feed"
            }
          }
          rule r {
            when EV { log "ok" }
          }
          """,
          subscribable_registry: sub_registry,
          registry: registry
        )

      log = capture_log(fn -> Dispatcher.load(dispatcher, compiled) end)

      refute log =~ "hunter2-secret"
      # The block name is the operator's handle on the problem and is
      # authored text, not runtime data — it must survive.
      assert log =~ "feed"
    end

    test "the structured failure returned to the caller names the failure, not its values" do
      {:ok, registry} = ModuleRegistry.start_link([])
      {:ok, sub_registry} = SubscribableRegistry.start_link()
      :ok = SubscribableRegistry.register(sub_registry, "leaky", LeakySubscribable)

      {dispatcher, compiled} =
        dispatcher_for(
          """
          data feed {
            dynamic {
              subscribe leaky "test://feed"
            }
          }
          rule r {
            when EV { log "ok" }
          }
          """,
          subscribable_registry: sub_registry,
          registry: registry
        )

      capture_log(fn ->
        assert {:error, [%Comn.Errors.ErrorStruct{} = failure]} =
                 Dispatcher.load(dispatcher, compiled)

        assert %{code: "anemos.data/subscribe_failed", field: "feed"} = failure
        assert failure.message =~ ":auth_failed"
        refute inspect(failure) =~ "hunter2-secret"
      end)
    end
  end
end
