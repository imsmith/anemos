defmodule Anemos.ChannelTest do
  @moduledoc false
  use ExUnit.Case

  defmodule TestChannel do
    @moduledoc false
    @behaviour Anemos.Channel

    @doc "Sends envelope to the pid stored in :anemos_test_channel ETS table."
    @impl true
    def publish(channel, envelope) do
      [{_, pid}] = :ets.lookup(:anemos_test_channel, :test_pid)
      send(pid, {:published, channel, envelope})
      :ok
    end
  end

  setup do
    try do
      :ets.new(:anemos_test_channel, [:named_table, :public])
    rescue
      ArgumentError -> :ok
    end

    :ets.insert(:anemos_test_channel, {:test_pid, self()})
    :ok
  end

  test "emit to channel publishes through connector" do
    start_supervised!({Anemos.Runtime, name: :test_channel})

    Anemos.Runtime.connect(:test_channel, TestChannel)

    Anemos.Runtime.load(:test_channel, """
    rule notify {
      when ALERT {
        emit [EVENT::fire] to channel(security.firewall.update) as :alert.fired
      }
    }
    """)

    Anemos.Runtime.register(:test_channel, "EVENT", Anemos.Runtime.Modules.Example.Event)

    {:ok, _results} = Anemos.Runtime.dispatch(:test_channel, "ALERT")

    assert_receive {:published, "security.firewall.update", envelope}
    assert %Anemos.Envelope{} = envelope
    assert envelope.channel == "security.firewall.update"
    assert envelope.label == "alert.fired"
    assert envelope.source == "notify"
    assert envelope.timestamp != nil
    assert envelope.signature == nil
  end

  test "envelope source includes context path when present" do
    start_supervised!({Anemos.Runtime, name: :test_chan_src})

    Anemos.Runtime.connect(:test_chan_src, TestChannel)

    Anemos.Runtime.load(:test_chan_src, """
    rule scoped-notify {
      context infra.networking {
        when ALERT {
          emit [EVENT::fire] to channel(alerts) as :alert
        }
      }
    }
    """)

    Anemos.Runtime.register(:test_chan_src, "EVENT", Anemos.Runtime.Modules.Example.Event)

    {:ok, _} =
      Anemos.Runtime.dispatch(:test_chan_src, "ALERT", %{context_path: "infra.networking"})

    assert_receive {:published, "alerts", envelope}
    assert envelope.source == "scoped-notify@infra.networking"
  end

  test "emit with type carries type in envelope" do
    start_supervised!({Anemos.Runtime, name: :test_chan_type})

    Anemos.Runtime.connect(:test_chan_type, TestChannel)

    Anemos.Runtime.load(:test_chan_type, """
    rule telemetry {
      when READING {
        emit state [EVENT::reading] to channel(telemetry.sensors) as :sensor.update
      }
    }
    """)

    Anemos.Runtime.register(:test_chan_type, "EVENT", Anemos.Runtime.Modules.Example.Event)

    {:ok, _results} = Anemos.Runtime.dispatch(:test_chan_type, "READING")

    assert_receive {:published, "telemetry.sensors", envelope}
    assert envelope.type == :state
    assert envelope.label == "sensor.update"
  end

  test "emit without channel destination does not publish" do
    start_supervised!({Anemos.Runtime, name: :test_chan_none})

    Anemos.Runtime.connect(:test_chan_none, TestChannel)

    Anemos.Runtime.load(:test_chan_none, """
    rule quiet {
      when EV {
        emit [EVENT::fire] as :my.event
      }
    }
    """)

    Anemos.Runtime.register(:test_chan_none, "EVENT", Anemos.Runtime.Modules.Example.Event)

    {:ok, _results} = Anemos.Runtime.dispatch(:test_chan_none, "EV")

    refute_receive {:published, _, _}, 50
  end

  test "default connector logs to Logger" do
    start_supervised!({Anemos.Runtime, name: :test_chan_default})

    Anemos.Runtime.load(:test_chan_default, """
    rule notify {
      when ALERT {
        emit [EVENT::fire] to channel(alerts) as :alert
      }
    }
    """)

    Anemos.Runtime.register(:test_chan_default, "EVENT", Anemos.Runtime.Modules.Example.Event)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        {:ok, _results} = Anemos.Runtime.dispatch(:test_chan_default, "ALERT")
      end)

    assert log =~ "emit to alerts"
    assert log =~ "alert"
  end

  test "label still re-dispatches as event even with channel" do
    start_supervised!({Anemos.Runtime, name: :test_chan_redispatch})

    Anemos.Runtime.connect(:test_chan_redispatch, TestChannel)

    Anemos.Runtime.load(:test_chan_redispatch, """
    rule emitter {
      when SOURCE {
        emit [EVENT::fire] to channel(alerts) as :my.alert
      }
    }

    rule listener {
      when my.alert {
        log "caught the alert"
      }
    }
    """)

    Anemos.Runtime.register(:test_chan_redispatch, "EVENT", Anemos.Runtime.Modules.Example.Event)

    {:ok, results} = Anemos.Runtime.dispatch(:test_chan_redispatch, "SOURCE")

    # Channel publish happened
    assert_receive {:published, "alerts", _envelope}

    # Label re-dispatch also happened
    log_values = for %{type: :log, value: v} <- results, do: v
    assert "caught the alert" in log_values
  end
end
