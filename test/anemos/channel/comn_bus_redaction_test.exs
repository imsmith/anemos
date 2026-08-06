defmodule Anemos.Channel.ComnBusRedactionTest do
  @moduledoc """
  A-09 regression guard for the ComnBus connector.

  ComnBus delivers the payload to subscribers — that is its whole job, and
  it is not a disclosure. What must never happen is a *second*, incidental
  copy of the payload landing in the application log, which is how the
  default connector leaked.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Anemos.Channel.ComnBus
  alias Anemos.Envelope
  alias Anemos.Secret

  @plaintext "did_key_67890_super_secret"

  test "publishing does not write the payload to the log" do
    Comn.EventBus.subscribe("creds/redaction")

    env = %Envelope{payload: %{"token" => @plaintext}, channel: "creds/redaction"}

    log = capture_log(fn -> assert :ok = ComnBus.publish("creds/redaction", env) end)

    refute log =~ @plaintext
    assert_receive {:event, "creds/redaction", ^env}
  end

  test "publishing with no subscribers does not write the payload to the log" do
    env = %Envelope{payload: @plaintext, channel: "creds/nowhere"}

    log = capture_log(fn -> assert :ok = ComnBus.publish("creds/nowhere", env) end)

    refute log =~ @plaintext
  end

  test "a wrapped secret survives delivery and is still redacted downstream" do
    Comn.EventBus.subscribe("creds/wrapped")

    env = %Envelope{payload: Secret.new(@plaintext, label: "ddns-key"), channel: "creds/wrapped"}

    assert :ok = ComnBus.publish("creds/wrapped", env)
    assert_receive {:event, "creds/wrapped", delivered}

    # The subscriber can still use the secret deliberately...
    assert Secret.expose(delivered.payload) == @plaintext
    # ...but cannot leak it by logging what it received.
    log =
      capture_log(fn ->
        require Logger
        Logger.info("got: #{inspect(delivered)}")
      end)

    refute log =~ @plaintext
  end
end
