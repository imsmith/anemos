defmodule Anemos.EventTest do
  @moduledoc false
  use ExUnit.Case

  defmodule FakeMessage do
    @moduledoc false
    @enforce_keys [:topic, :body]
    defstruct [:topic, :body]
  end

  defimpl Anemos.Event, for: FakeMessage do
    def name(msg), do: msg.topic |> String.upcase() |> String.replace("/", "_")
    def context(msg), do: msg.topic
    def payload(msg), do: msg.body
  end

  test "protocol dispatch with custom type" do
    start_supervised!({Anemos.Runtime, name: :test_proto})

    Anemos.Runtime.load(:test_proto, """
    rule react {
      when SENSOR_MOTION {
        log ?confidence
      }
    }
    """)

    msg = %FakeMessage{topic: "sensor/motion", body: %{"confidence" => 0.95}}
    {:ok, results} = Anemos.Runtime.dispatch(:test_proto, msg)

    assert [%{type: :log, value: 0.95}] = results
  end

  test "protocol dispatch with map shorthand" do
    start_supervised!({Anemos.Runtime, name: :test_map_evt})

    Anemos.Runtime.load(:test_map_evt, """
    rule react {
      when TICK {
        log ?count
      }
    }
    """)

    {:ok, results} =
      Anemos.Runtime.dispatch(:test_map_evt, %{
        name: "TICK",
        context: "timers",
        payload: %{"count" => 42}
      })

    assert [%{type: :log, value: 42}] = results
  end

  test "protocol dispatch respects context filtering" do
    start_supervised!({Anemos.Runtime, name: :test_ctx_filter})

    Anemos.Runtime.load(:test_ctx_filter, """
    rule scoped {
      context "garage" {
        when MOTION {
          log "garage motion"
        }
      }
    }
    """)

    # Matching context
    {:ok, results} =
      Anemos.Runtime.dispatch(:test_ctx_filter, %{
        name: "MOTION",
        context: "garage",
        payload: %{}
      })

    assert [%{type: :log, value: "garage motion"}] = results

    # Wrong context
    {:ok, results} =
      Anemos.Runtime.dispatch(:test_ctx_filter, %{
        name: "MOTION",
        context: "kitchen",
        payload: %{}
      })

    assert results == []
  end

  test "string dispatch still works" do
    start_supervised!({Anemos.Runtime, name: :test_string})

    Anemos.Runtime.load(:test_string, """
    rule react {
      when PING {
        log "pong"
      }
    }
    """)

    {:ok, results} = Anemos.Runtime.dispatch(:test_string, "PING")
    assert [%{type: :log, value: "pong"}] = results
  end
end
