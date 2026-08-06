defmodule Anemos.Runtime.ContextStoreTest do
  use ExUnit.Case, async: true
  @moduledoc false

  alias Anemos.Runtime.ContextStore

  doctest Anemos.Runtime.ContextStore

  test "stores and retrieves a key-value pair" do
    {:ok, store} = ContextStore.start_link([])
    ContextStore.put(store, "infra.networking.dns.fqdn", "host.example.tld")
    assert {:ok, "host.example.tld"} = ContextStore.resolve(store, "infra.networking.dns", "fqdn")
  end

  test "resolves key against context path prefix" do
    {:ok, store} = ContextStore.start_link([])
    ContextStore.put(store, "infra.networking.dns.fqdn", "host.example.tld")
    ContextStore.put(store, "infra.networking.gateway", "192.168.1.1")
    assert {:ok, "host.example.tld"} = ContextStore.resolve(store, "infra.networking.dns", "fqdn")
    assert {:ok, "192.168.1.1"} = ContextStore.resolve(store, "infra.networking", "gateway")
  end

  test "returns :error for missing key" do
    {:ok, store} = ContextStore.start_link([])
    assert :error = ContextStore.resolve(store, "infra.networking.dns", "missing")
  end

  test "context scoping: narrower context does not see sibling keys" do
    {:ok, store} = ContextStore.start_link([])
    ContextStore.put(store, "storage.backups.path", "/mnt/backup")
    assert :error = ContextStore.resolve(store, "infra.networking", "path")
  end

  test "bulk load from keyword list" do
    {:ok, store} =
      ContextStore.start_link(
        data: [
          {"infra.networking.dns.fqdn", "host.example.tld"},
          {"infra.networking.dns.ttl", "300"}
        ]
      )

    assert {:ok, "host.example.tld"} = ContextStore.resolve(store, "infra.networking.dns", "fqdn")
    assert {:ok, "300"} = ContextStore.resolve(store, "infra.networking.dns", "ttl")
  end
end
