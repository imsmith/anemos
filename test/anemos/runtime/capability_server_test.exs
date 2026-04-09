defmodule Anemos.Runtime.CapabilityServerTest do
  use ExUnit.Case, async: true
  @moduledoc false

  alias Anemos.Runtime.CapabilityServer

  test "starts and is addressable" do
    {:ok, pid} = CapabilityServer.start_link(
      name_str: "test-key",
      context: "infra.networking",
      handler: fn _ctx -> {:ok, [%{type: :emit, value: "unlocked"}]} end
    )
    assert Process.alive?(pid)
  end

  test "execute returns handler result" do
    {:ok, pid} = CapabilityServer.start_link(
      name_str: "test-key",
      context: "infra.networking",
      handler: fn _ctx -> {:ok, [%{type: :emit, value: "unlocked"}]} end
    )
    assert {:ok, [%{type: :emit, value: "unlocked"}]} = CapabilityServer.execute(pid, %{})
  end

  test "handler receives context" do
    {:ok, pid} = CapabilityServer.start_link(
      name_str: "ctx-cap",
      context: "infra",
      handler: fn ctx -> {:ok, [%{type: :emit, value: ctx[:user]}]} end
    )
    assert {:ok, [%{type: :emit, value: "ian"}]} = CapabilityServer.execute(pid, %{user: "ian"})
  end

  test "handler error is returned, does not crash server" do
    {:ok, pid} = CapabilityServer.start_link(
      name_str: "fail-cap",
      context: "test",
      handler: fn _ctx -> {:error, :unavailable} end
    )
    assert {:error, :unavailable} = CapabilityServer.execute(pid, %{})
    assert Process.alive?(pid)
  end
end
