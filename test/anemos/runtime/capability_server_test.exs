defmodule Anemos.Runtime.CapabilityServerTest do
  use ExUnit.Case, async: true
  @moduledoc false

  alias Anemos.Runtime.CapabilityServer

  doctest Anemos.Runtime.CapabilityServer

  test "starts and is addressable" do
    {:ok, pid} =
      CapabilityServer.start_link(
        name_str: "test-key",
        context: "infra.networking",
        handler: fn _ctx -> {:ok, [%{type: :emit, value: "unlocked"}]} end
      )

    assert Process.alive?(pid)
  end

  test "execute returns handler result" do
    {:ok, pid} =
      CapabilityServer.start_link(
        name_str: "test-key",
        context: "infra.networking",
        handler: fn _ctx -> {:ok, [%{type: :emit, value: "unlocked"}]} end
      )

    assert {:ok, [%{type: :emit, value: "unlocked"}]} =
             CapabilityServer.execute(pid, %{}, "infra.networking")
  end

  test "handler receives context" do
    {:ok, pid} =
      CapabilityServer.start_link(
        name_str: "ctx-cap",
        context: "infra",
        handler: fn ctx -> {:ok, [%{type: :emit, value: ctx[:user]}]} end
      )

    assert {:ok, [%{type: :emit, value: "ian"}]} =
             CapabilityServer.execute(pid, %{user: "ian"}, "infra")
  end

  test "handler error is returned, does not crash server" do
    {:ok, pid} =
      CapabilityServer.start_link(
        name_str: "fail-cap",
        context: "test",
        handler: fn _ctx -> {:error, :unavailable} end
      )

    assert {:error, :unavailable} = CapabilityServer.execute(pid, %{}, "test")
    assert Process.alive?(pid)
  end

  # A-07. The demanding context is a required argument in all but name: the
  # arity-2 form omits it, and a scoped capability treats that as "outside".
  test "a scoped capability refuses a demander that names no context" do
    {:ok, pid} =
      CapabilityServer.start_link(
        name_str: "scoped-cap",
        context: "infra.networking",
        handler: fn _ctx -> {:ok, [%{type: :emit, value: "unlocked"}]} end
      )

    assert {:error, {:context_denied, err}} = CapabilityServer.execute(pid, %{})
    assert err.code == "anemos.runtime/capability_context_denied"

    assert {:error, {:context_denied, _}} =
             CapabilityServer.execute(pid, %{}, "infra.networkingx")

    assert Process.alive?(pid)
  end
end
