defmodule Anemos.Runtime.TripleStore do
  @moduledoc """
  Agent-based triple store for RDF-like facts.

  Stores `{subject, predicate, object}` triples and supports
  pattern matching with query variables (`?` bindings).

  ## Asserting facts

      TripleStore.assert(store, "p001", "knows", "p002")

  ## Querying facts

      TripleStore.query(store, :_, "knows", :_)
      # => [{"p001", "knows", "p002"}]

      TripleStore.match(store, :_, "worksOn", :_)
      # => [%{"?a" => "p001", "?p" => "proj1"}, ...]

  Use `:_` as a wildcard in queries.
  """

  use Agent

  @doc """
  Starts a triple store.

  ## Options

    * `:name` — process registration name (optional)
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name)
    Agent.start_link(fn -> [] end, name: name)
  end

  @doc """
  Asserts a triple (fact) into the store.
  """
  @spec assert_triple(pid() | atom(), term(), term(), term()) :: :ok
  def assert_triple(store, subject, predicate, object) do
    Agent.update(store, fn triples ->
      triple = {subject, predicate, object}
      if triple in triples, do: triples, else: [triple | triples]
    end)
  end

  @doc """
  Queries the store for triples matching a pattern.

  Use `:_` as a wildcard for any position. Returns matching triples.

  ## Examples

      iex> {:ok, store} = Anemos.Runtime.TripleStore.start_link()
      iex> Anemos.Runtime.TripleStore.assert_triple(store, "p001", "knows", "p002")
      iex> Anemos.Runtime.TripleStore.query(store, "p001", "knows", :_)
      [{"p001", "knows", "p002"}]

      iex> {:ok, store} = Anemos.Runtime.TripleStore.start_link()
      iex> Anemos.Runtime.TripleStore.query(store, :_, :_, :_)
      []

  """
  @spec query(pid() | atom(), term(), term(), term()) :: [{term(), term(), term()}]
  def query(store, s_pattern, p_pattern, o_pattern) do
    Agent.get(store, fn triples ->
      Enum.filter(triples, fn {s, p, o} ->
        matches?(s, s_pattern) and matches?(p, p_pattern) and matches?(o, o_pattern)
      end)
    end)
  end

  @doc """
  Matches triples against a pattern with named bindings.

  Takes a pattern as `{subject, predicate, object}` where each element is
  either a literal value (matches exactly) or a `{:var, name}` tuple
  (binds the matched value to that name).

  Returns a list of binding maps.

  ## Examples

      iex> {:ok, store} = Anemos.Runtime.TripleStore.start_link()
      iex> Anemos.Runtime.TripleStore.assert_triple(store, "p001", "worksOn", "proj1")
      iex> Anemos.Runtime.TripleStore.assert_triple(store, "p002", "worksOn", "proj1")
      iex> Anemos.Runtime.TripleStore.match(store, {:var, "a"}, "worksOn", {:var, "p"})
      [%{"a" => "p002", "p" => "proj1"}, %{"a" => "p001", "p" => "proj1"}]

  """
  @spec match(pid() | atom(), term(), term(), term()) :: [map()]
  def match(store, s_pattern, p_pattern, o_pattern) do
    Agent.get(store, fn triples ->
      Enum.flat_map(triples, fn {s, p, o} ->
        case bind_triple({s, p, o}, {s_pattern, p_pattern, o_pattern}) do
          {:ok, bindings} -> [bindings]
          :no_match -> []
        end
      end)
    end)
  end

  # --- Private ---

  defp matches?(_value, :_), do: true
  defp matches?(value, pattern), do: value == pattern

  defp bind_triple({s, p, o}, {sp, pp, op}) do
    with {:ok, b1} <- bind_element(s, sp, %{}),
         {:ok, b2} <- bind_element(p, pp, b1),
         {:ok, b3} <- bind_element(o, op, b2) do
      {:ok, b3}
    end
  end

  defp bind_element(value, {:var, name}, bindings) do
    case Map.fetch(bindings, name) do
      {:ok, ^value} -> {:ok, bindings}
      {:ok, _other} -> :no_match
      :error -> {:ok, Map.put(bindings, name, value)}
    end
  end

  defp bind_element(_value, :_, bindings), do: {:ok, bindings}
  defp bind_element(value, value, bindings), do: {:ok, bindings}
  defp bind_element(_value, _pattern, _bindings), do: :no_match
end
