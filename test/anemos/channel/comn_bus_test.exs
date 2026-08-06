defmodule Anemos.Channel.ComnBusTest do
  @moduledoc false
  use ExUnit.Case

  alias Anemos.Channel.ComnBus
  alias Anemos.Envelope

  # Comn.EventBus registry is started by Comn.Supervisor (OTP application)

  test "publish broadcasts envelope to subscribers" do
    Comn.EventBus.subscribe("sensors/temp")

    envelope = %Envelope{
      type: :state,
      payload: %{value: 72.5},
      source: "thermostat-rule",
      label: "temp.reading",
      channel: "sensors/temp",
      timestamp: DateTime.utc_now()
    }

    assert :ok = ComnBus.publish("sensors/temp", envelope)
    assert_receive {:event, "sensors/temp", ^envelope}
  end

  test "publish delivers to multiple subscribers" do
    parent = self()

    Comn.EventBus.subscribe("alerts")

    task =
      Task.async(fn ->
        Comn.EventBus.subscribe("alerts")
        send(parent, :subscribed)

        receive do
          {:event, "alerts", env} -> env
        after
          1000 -> :timeout
        end
      end)

    receive do
      :subscribed -> :ok
    end

    envelope = %Envelope{payload: "fire", channel: "alerts"}
    ComnBus.publish("alerts", envelope)

    assert_receive {:event, "alerts", ^envelope}
    assert ^envelope = Task.await(task)
  end

  test "publish with no subscribers does not error" do
    envelope = %Envelope{payload: "ignored", channel: "nowhere"}
    assert :ok = ComnBus.publish("nowhere", envelope)
  end

  test "end-to-end through runtime" do
    # Start Comn.EventBus registry is already up from setup
    start_supervised!({Anemos.Runtime, name: :test_comn_bus})

    Anemos.Runtime.connect(:test_comn_bus, ComnBus)

    Comn.EventBus.subscribe("security.firewall")

    Anemos.Runtime.load(:test_comn_bus, """
    rule fw-notify {
      when BREACH {
        emit [EVENT::block] to channel(security.firewall) as :fw.block
      }
    }
    """)

    Anemos.Runtime.register(:test_comn_bus, "EVENT", Anemos.Runtime.Modules.Example.Event)

    {:ok, _results} = Anemos.Runtime.dispatch(:test_comn_bus, "BREACH")

    assert_receive {:event, "security.firewall", %Envelope{} = env}
    assert env.channel == "security.firewall"
    assert env.label == "fw.block"
  end
end
