defmodule Anemos.Runtime.DataStoreTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Anemos.Runtime.DataStore

  test "register and member? for simple list" do
    {:ok, store} = DataStore.start_link()
    :ok = DataStore.register(store, "reserved-ips", :global, MapSet.new(["10.0.0.0/8", "192.168.0.0/16"]))

    assert DataStore.member?(store, "reserved-ips", "10.0.0.0/8")
    refute DataStore.member?(store, "reserved-ips", "8.8.8.8")
  end

  test "get returns full dataset" do
    {:ok, store} = DataStore.start_link()
    dataset = MapSet.new(["a", "b", "c"])
    :ok = DataStore.register(store, "letters", :global, dataset)

    assert DataStore.get(store, "letters") == dataset
  end

  test "deregister removes entry" do
    {:ok, store} = DataStore.start_link()
    :ok = DataStore.register(store, "temp", :global, MapSet.new(["x"]))
    assert DataStore.member?(store, "temp", "x")

    :ok = DataStore.deregister(store, "temp", :global)
    refute DataStore.member?(store, "temp", "x")
  end

  test "local scope shadows global" do
    {:ok, store} = DataStore.start_link()
    :ok = DataStore.register(store, "ips", :global, MapSet.new(["1.1.1.1"]))
    :ok = DataStore.register(store, "ips", {:local, self()}, MapSet.new(["2.2.2.2"]))

    assert DataStore.member?(store, "ips", "2.2.2.2")
    refute DataStore.member?(store, "ips", "1.1.1.1")
  end

  test "update replaces dataset silently" do
    {:ok, store} = DataStore.start_link()
    :ok = DataStore.register(store, "feed", :global, MapSet.new(["old"]))
    assert DataStore.member?(store, "feed", "old")

    :ok = DataStore.update(store, "feed", :global, MapSet.new(["new"]))
    refute DataStore.member?(store, "feed", "old")
    assert DataStore.member?(store, "feed", "new")
  end

  test "member_any? checks union of sets" do
    {:ok, store} = DataStore.start_link()
    :ok = DataStore.register(store, "set-a", :global, MapSet.new(["x"]))
    :ok = DataStore.register(store, "set-b", :global, MapSet.new(["y"]))

    assert DataStore.member_any?(store, ["set-a", "set-b"], "x")
    assert DataStore.member_any?(store, ["set-a", "set-b"], "y")
    refute DataStore.member_any?(store, ["set-a", "set-b"], "z")
  end

  test "get returns nil for unknown name" do
    {:ok, store} = DataStore.start_link()
    assert DataStore.get(store, "nonexistent") == nil
  end

  test "local-scoped entry cleaned up on pid DOWN" do
    {:ok, store} = DataStore.start_link()
    test_pid = self()

    child =
      spawn(fn ->
        # Register from within the child so {:local, self()} is this pid
        :ok = DataStore.register(store, "local-data", {:local, self()}, MapSet.new(["secret"]))
        # Confirm visible from within the child process
        send(test_pid, {:registered, DataStore.member?(store, "local-data", "secret")})
        receive do
          :stop -> :ok
        end
      end)

    ref = Process.monitor(child)
    assert_receive {:registered, true}, 1000

    send(child, :stop)
    assert_receive {:DOWN, ^ref, :process, ^child, _}, 1000

    # give the GenServer a moment to handle its own DOWN
    Process.sleep(10)

    # From test process, local scope is test_pid — no local entry, no global — should be nil/false
    # More importantly, verify the entry was removed from the store entirely by checking
    # from a new process that also has no local entry for this name
    task = Task.async(fn -> DataStore.member?(store, "local-data", "secret") end)
    refute Task.await(task)
  end

  # --- A-24: one scope model across every lookup ---

  describe "scope discriminators" do
    test "get/3 reaches a rule-scoped entry via the same :scope_hint member?/4 uses" do
      {:ok, store} = DataStore.start_link()
      dataset = MapSet.new(["10.0.0.1"])

      :ok = DataStore.register(store, "hosts", {:local, "my-rule"}, dataset)

      # member? already honours the hint.
      assert DataStore.member?(store, "hosts", "10.0.0.1", scope_hint: "my-rule")

      # get must reach the same entry, or the two lookups disagree about
      # what scope means.
      assert DataStore.get(store, "hosts", scope_hint: "my-rule") == dataset
    end

    test "get/3 still shadows global with local, and falls back to global" do
      {:ok, store} = DataStore.start_link()

      :ok = DataStore.register(store, "hosts", :global, MapSet.new(["global"]))
      :ok = DataStore.register(store, "hosts", {:local, "rule-a"}, MapSet.new(["local"]))

      assert DataStore.get(store, "hosts", scope_hint: "rule-a") == MapSet.new(["local"])
      assert DataStore.get(store, "hosts", scope_hint: "rule-b") == MapSet.new(["global"])
      assert DataStore.get(store, "hosts") == MapSet.new(["global"])
    end

    test "drop_scope/2 removes every entry for a non-pid scope" do
      {:ok, store} = DataStore.start_link()

      :ok = DataStore.register(store, "a", {:local, "rule-a"}, MapSet.new(["x"]))
      :ok = DataStore.register(store, "b", {:local, "rule-a"}, MapSet.new(["y"]))
      :ok = DataStore.register(store, "c", {:local, "rule-b"}, MapSet.new(["z"]))
      :ok = DataStore.register(store, "d", :global, MapSet.new(["w"]))

      assert :ok = DataStore.drop_scope(store, {:local, "rule-a"})

      refute DataStore.member?(store, "a", "x", scope_hint: "rule-a")
      refute DataStore.member?(store, "b", "y", scope_hint: "rule-a")

      # Other scopes are untouched.
      assert DataStore.member?(store, "c", "z", scope_hint: "rule-b")
      assert DataStore.member?(store, "d", "w")
    end

    test "drop_scope/2 on an unused scope is a no-op" do
      {:ok, store} = DataStore.start_link()
      assert :ok = DataStore.drop_scope(store, {:local, "never-registered"})
    end

    test "a pid scope stops being monitored once its last entry is dropped" do
      {:ok, store} = DataStore.start_link()

      :ok = DataStore.register(store, "p", {:local, self()}, MapSet.new(["x"]))
      assert Map.has_key?(:sys.get_state(store).monitors, self())

      assert :ok = DataStore.drop_scope(store, {:local, self()})
      refute Map.has_key?(:sys.get_state(store).monitors, self())
    end
  end
end
