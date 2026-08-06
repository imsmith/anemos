defmodule Anemos.Runtime.DemandTest do
  use ExUnit.Case, async: true
  @moduledoc false

  alias Anemos.Runtime.{Demand, CapabilityServer}
  alias Comn.Errors.ErrorStruct

  doctest Anemos.Runtime.Demand

  defp start_capability(name, result) do
    {:ok, pid} = CapabilityServer.start_link(
      name_str: name,
      context: "test",
      handler: fn _ctx -> result end
    )
    pid
  end

  test "single bare demand (requisite) — success" do
    pid = start_capability("key", {:ok, [%{type: :emit, value: "unlocked"}]})
    registry = %{"key" => pid}
    demands = [%{capability: "key", flag: :requisite}]
    assert {:ok, results} = Demand.evaluate(demands, registry, %{})
    assert [%{type: :emit, value: "unlocked"}] = results
  end

  test "single bare demand (requisite) — failure stops immediately" do
    pid = start_capability("key", {:error, :denied})
    registry = %{"key" => pid}
    demands = [%{capability: "key", flag: :requisite}]
    assert {:error, {:demand_failed, "key", :denied}} = Demand.evaluate(demands, registry, %{})
  end

  test "missing capability — requisite fails" do
    demands = [%{capability: "nonexistent", flag: :requisite}]

    assert {:error, %ErrorStruct{code: "anemos.runtime/unknown_capability"} = err} =
             Demand.evaluate(demands, %{}, %{})

    assert err.message =~ "nonexistent"
  end

  # A missing capability is a configuration error, not an authorization
  # failure. PAM flag semantics govern how FAILURE is handled; they must not
  # let a typo'd or unloaded capability be skipped.
  for flag <- [:requisite, :required, :optional, :sufficient] do
    test "missing capability is fatal under #{flag}" do
      demands = [%{capability: "ghost", flag: unquote(flag)}]

      assert {:error, %ErrorStruct{code: "anemos.runtime/unknown_capability"}} =
               Demand.evaluate(demands, %{}, %{})
    end
  end

  test "all-optional stack of missing capabilities does not authorize" do
    demands = [
      %{capability: "ghost-a", flag: :optional},
      %{capability: "ghost-b", flag: :optional}
    ]

    refute match?({:ok, _}, Demand.evaluate(demands, %{}, %{}))

    assert {:error, %ErrorStruct{code: "anemos.runtime/unknown_capability"} = err} =
             Demand.evaluate(demands, %{}, %{})

    assert err.message =~ "ghost-a"
  end

  test "missing capability is fatal even when a later demand succeeds" do
    ok_pid = start_capability("real-key", {:ok, [%{type: :emit, value: "done"}]})

    demands = [
      %{capability: "typo-key", flag: :optional},
      %{capability: "real-key", flag: :requisite}
    ]

    assert {:error, %ErrorStruct{code: "anemos.runtime/unknown_capability"}} =
             Demand.evaluate(demands, %{"real-key" => ok_pid}, %{})
  end

  test "optional demand — failure continues" do
    fail_pid = start_capability("optional-key", {:error, :unavailable})
    ok_pid = start_capability("main-key", {:ok, [%{type: :emit, value: "done"}]})
    registry = %{"optional-key" => fail_pid, "main-key" => ok_pid}
    demands = [
      %{capability: "optional-key", flag: :optional},
      %{capability: "main-key", flag: :requisite}
    ]
    assert {:ok, results} = Demand.evaluate(demands, registry, %{})
    assert [%{type: :emit, value: "done"}] = results
  end

  test "required demand — deferred failure after stack" do
    fail_pid = start_capability("req-key", {:error, :denied})
    ok_pid = start_capability("other-key", {:ok, [%{type: :emit, value: "ok"}]})
    registry = %{"req-key" => fail_pid, "other-key" => ok_pid}
    demands = [
      %{capability: "req-key", flag: :required},
      %{capability: "other-key", flag: :requisite}
    ]
    assert {:error, {:demand_failed, "req-key", :denied}} = Demand.evaluate(demands, registry, %{})
  end

  test "sufficient demand — success skips rest of stack" do
    ok_pid = start_capability("suf-key", {:ok, [%{type: :emit, value: "enough"}]})
    registry = %{"suf-key" => ok_pid}
    demands = [
      %{capability: "suf-key", flag: :sufficient},
      %{capability: "nonexistent", flag: :requisite}
    ]
    assert {:ok, results} = Demand.evaluate(demands, registry, %{})
    assert [%{type: :emit, value: "enough"}] = results
  end
end
