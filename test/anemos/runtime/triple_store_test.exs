defmodule Anemos.Runtime.TripleStoreTest do
  @moduledoc """
  A-23: the triple store was a plain list with an `in` membership check
  before every prepend, making insert O(n) and building n triples O(n²).
  """
  use ExUnit.Case, async: true

  alias Anemos.Runtime.TripleStore

  # Growth test rather than a wall-clock bound: absolute timings vary by
  # machine, but the *shape* of the curve does not. A linear-insert store
  # (MapSet) doubles its work when n doubles; an O(n²) one quadruples it.
  # The threshold is set at 2.5x to leave room for scheduler noise while
  # still failing decisively on quadratic growth (which measures ~4x).
  #
  # Taking a *single* timing of each size made this test flaky: the suite is
  # `async: true`, so the two measurements land at different moments under
  # different amounts of concurrent load, and the ratio measures scheduler
  # contention as much as it measures algorithmic growth. It failed 5 runs in
  # 8 in-suite at ratios around 2.65x, while passing 12 of 12 in isolation.
  #
  # Fix: alternate the two sizes across several rounds and keep the minimum
  # for each. The fastest observed run is the one that competed with the least
  # other work, so min-of-N estimates the uncontended cost — the quantity this
  # assertion is actually about. Quadratic growth still shows up ~4x, because
  # a real O(n²) store is slower in its *best* round too.
  @rounds 5

  @tag :perf
  test "insert cost grows linearly, not quadratically, in the number of triples" do
    {small, large} =
      Enum.reduce(1..@rounds, {nil, nil}, fn _round, {s, l} ->
        # Interleaved, so a burst of load cannot hit only one of the two.
        {min_time(s, time_inserts(4_000)), min_time(l, time_inserts(8_000))}
      end)

    ratio = large / max(small, 1)

    assert ratio < 2.5,
           "doubling the triple count multiplied insert time by #{Float.round(ratio, 2)}x — " <>
             "expected ~2x for a linear store, ~4x indicates O(n^2) insert " <>
             "(best of #{@rounds} rounds: #{small}us for 4k, #{large}us for 8k)"
  end

  defp min_time(nil, t), do: t
  defp min_time(prev, t), do: min(prev, t)

  defp time_inserts(n) do
    {:ok, store} = TripleStore.start_link()

    {micros, :ok} =
      :timer.tc(fn ->
        Enum.each(1..n, fn i ->
          TripleStore.assert_triple(store, "s#{i}", "p", "o#{i}")
        end)
      end)

    Agent.stop(store)
    micros
  end

  test "deduplicates identical triples" do
    {:ok, store} = TripleStore.start_link()

    TripleStore.assert_triple(store, "a", "b", "c")
    TripleStore.assert_triple(store, "a", "b", "c")

    assert TripleStore.size(store) == 1
  end

  test "size/1 reports the number of distinct triples" do
    {:ok, store} = TripleStore.start_link()

    assert TripleStore.size(store) == 0
    TripleStore.assert_triple(store, "a", "b", "c")
    TripleStore.assert_triple(store, "a", "b", "d")
    assert TripleStore.size(store) == 2
  end

  test "retract_triple/4 removes a fact and is idempotent" do
    {:ok, store} = TripleStore.start_link()

    TripleStore.assert_triple(store, "a", "b", "c")
    assert TripleStore.query(store, "a", "b", :_) == [{"a", "b", "c"}]

    assert :ok = TripleStore.retract_triple(store, "a", "b", "c")
    assert TripleStore.query(store, "a", "b", :_) == []

    # Retracting an absent triple is not an error.
    assert :ok = TripleStore.retract_triple(store, "a", "b", "c")
    assert TripleStore.size(store) == 0
  end

  test "query and match still find every asserted triple" do
    {:ok, store} = TripleStore.start_link()

    TripleStore.assert_triple(store, "p001", "worksOn", "proj1")
    TripleStore.assert_triple(store, "p002", "worksOn", "proj1")
    TripleStore.assert_triple(store, "p003", "worksOn", "proj2")

    assert Enum.sort(TripleStore.query(store, :_, "worksOn", "proj1")) ==
             [{"p001", "worksOn", "proj1"}, {"p002", "worksOn", "proj1"}]

    who =
      store
      |> TripleStore.match({:var, "who"}, "worksOn", "proj1")
      |> Enum.map(& &1["who"])
      |> Enum.sort()

    assert who == ["p001", "p002"]
  end
end
