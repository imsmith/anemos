defmodule Anemos.Channel.LoggerTest do
  @moduledoc false
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Anemos.Channel.Logger, as: LoggerChannel
  alias Anemos.Envelope
  alias Anemos.Secret

  @plaintext "did_key_67890_super_secret"

  test "emits remain observable — channel, type and label are still logged" do
    env = %Envelope{payload: "anything", type: :effect, label: "alert"}

    log = capture_log(fn -> assert :ok = LoggerChannel.publish("alerts", env) end)

    assert log =~ "emit to alerts"
    assert log =~ "effect"
    assert log =~ "as alert"
  end

  test "the payload's contents are never logged — only its shape" do
    env = %Envelope{payload: @plaintext}

    log = capture_log(fn -> LoggerChannel.publish("alerts", env) end)

    refute log =~ @plaintext
    assert log =~ "binary(#{byte_size(@plaintext)} bytes)"
  end

  test "payload contents nested in a map are never logged" do
    env = %Envelope{payload: %{"token" => @plaintext, "user" => "operator"}}

    log = capture_log(fn -> LoggerChannel.publish("creds", env) end)

    refute log =~ @plaintext
    refute log =~ "operator"
    refute log =~ "token"
    assert log =~ "map(2 keys)"
  end

  test "a wrapped secret payload logs as redacted" do
    env = %Envelope{payload: Secret.new(@plaintext, label: "ddns-key")}

    log = capture_log(fn -> LoggerChannel.publish("keys", env) end)

    refute log =~ @plaintext
    assert log =~ "secret(redacted)"
  end

  test "envelope source and signature are not disclosed" do
    env = %Envelope{
      payload: "x",
      source: "rule/secret_handler",
      signature: <<1, 2, 3, 4>>
    }

    log = capture_log(fn -> LoggerChannel.publish("alerts", env) end)

    refute log =~ "signature"
    refute log =~ "1, 2, 3, 4"
  end

  test "the default connector in a live runtime does not disclose payloads" do
    start_supervised!({Anemos.Runtime, name: :test_logger_redact})

    Anemos.Runtime.load(:test_logger_redact, """
    rule leak {
      when ALERT {
        emit [EVENT::fire "#{@plaintext}"] to channel(alerts) as :alert
      }
    }
    """)

    Anemos.Runtime.register(:test_logger_redact, "EVENT", Anemos.Runtime.Modules.Device)

    log =
      capture_log(fn ->
        {:ok, _results} = Anemos.Runtime.dispatch(:test_logger_redact, "ALERT")
      end)

    assert log =~ "emit to alerts"
    refute log =~ @plaintext
  end
end
