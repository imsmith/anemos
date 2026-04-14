defmodule Anemos.ComnContextsTest do
  @moduledoc false
  use ExUnit.Case

  defmodule ContextCapture do
    @moduledoc false
    use Anemos.Module, name: "CTXCAP"

    verb :capture, fn _args, _ctx ->
      comn_ctx = Comn.Contexts.get()
      {:ok, %{captured_context: comn_ctx}}
    end
  end

  describe "Comn.Contexts during dispatch" do
    test "context is set with request_id and parent_event_id" do
      start_supervised!({Anemos.Runtime, name: :test_ctx})

      Anemos.Runtime.register(:test_ctx, ContextCapture)

      Anemos.Runtime.load(:test_ctx, """
      rule ctx-test {
        when PING {
          [CTXCAP::capture]
        }
      }
      """)

      {:ok, results} = Anemos.Runtime.dispatch(:test_ctx, "PING")

      cap = Enum.find(results, &match?(%{captured_context: _}, &1))
      assert cap != nil
      ctx = cap.captured_context
      assert %Comn.Contexts.ContextStruct{} = ctx
      assert is_binary(ctx.request_id)
      assert ctx.parent_event_id == "PING"
    end

    test "caller-supplied correlation_id propagates" do
      start_supervised!({Anemos.Runtime, name: :test_ctx_corr})

      Anemos.Runtime.register(:test_ctx_corr, ContextCapture)

      Anemos.Runtime.load(:test_ctx_corr, """
      rule ctx-corr {
        when EV {
          [CTXCAP::capture]
        }
      }
      """)

      {:ok, results} =
        Anemos.Runtime.dispatch(:test_ctx_corr, "EV", %{correlation_id: "corr-42"})

      cap = Enum.find(results, &match?(%{captured_context: _}, &1))
      assert cap.captured_context.correlation_id == "corr-42"
    end

    test "caller-supplied trace_id and actor propagate" do
      start_supervised!({Anemos.Runtime, name: :test_ctx_trace})

      Anemos.Runtime.register(:test_ctx_trace, ContextCapture)

      Anemos.Runtime.load(:test_ctx_trace, """
      rule ctx-trace {
        when EV {
          [CTXCAP::capture]
        }
      }
      """)

      {:ok, results} =
        Anemos.Runtime.dispatch(:test_ctx_trace, "EV", %{
          trace_id: "trace-99",
          actor: "sensor-hub"
        })

      ctx = Enum.find(results, &match?(%{captured_context: _}, &1)).captured_context
      assert ctx.trace_id == "trace-99"
      assert ctx.actor == "sensor-hub"
    end

    test "context_path lands in metadata" do
      start_supervised!({Anemos.Runtime, name: :test_ctx_path})

      Anemos.Runtime.register(:test_ctx_path, ContextCapture)

      Anemos.Runtime.load(:test_ctx_path, """
      rule ctx-path {
        when EV {
          [CTXCAP::capture]
        }
      }
      """)

      {:ok, results} =
        Anemos.Runtime.dispatch(:test_ctx_path, "EV", %{context_path: "infra.net"})

      ctx = Enum.find(results, &match?(%{captured_context: _}, &1)).captured_context
      assert ctx.metadata.context_path == "infra.net"
    end

    test "context is cleaned up after dispatch" do
      start_supervised!({Anemos.Runtime, name: :test_ctx_clean})

      Anemos.Runtime.load(:test_ctx_clean, """
      rule noop {
        when EV {
          log "ok"
        }
      }
      """)

      # Set a context before dispatch to verify it's restored after
      Comn.Contexts.new(request_id: "pre-existing")

      {:ok, _} = Anemos.Runtime.dispatch(:test_ctx_clean, "EV")

      # Dispatch runs in the Dispatcher's process, not ours —
      # our process context should be untouched
      assert Comn.Contexts.fetch(:request_id) == "pre-existing"
    end
  end
end
