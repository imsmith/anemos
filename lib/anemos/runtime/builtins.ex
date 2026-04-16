defmodule Anemos.Runtime.Builtins do
  @moduledoc """
  Built-in collection-processing functions for pipeline expressions.

  Called directly by the compiler when evaluating pipe expressions
  with filter/map/reduce/emit. Not user-facing — no module registration.
  """

  def filter(collection, var_name, predicate_fn, context, bindings) do
    collection
    |> List.wrap()
    |> Enum.filter(fn element ->
      iter_bindings = Map.put(bindings, {:let, var_name}, element)
      predicate_fn.(context, iter_bindings)
    end)
  end

  def map(collection, var_name, transform_fn, context, bindings) do
    collection
    |> List.wrap()
    |> Enum.map(fn element ->
      iter_bindings = Map.put(bindings, {:let, var_name}, element)
      transform_fn.(context, iter_bindings)
    end)
  end

  def reduce(collection, acc_name, initial, var_name, body_fn, context, bindings) do
    collection
    |> List.wrap()
    |> Enum.reduce(initial, fn element, acc ->
      iter_bindings =
        bindings
        |> Map.put({:let, var_name}, element)
        |> Map.put({:set, acc_name}, acc)

      body_fn.(context, iter_bindings)
    end)
  end

  def emit(collection, command_fn, context, bindings) do
    wrapped = List.wrap(collection)

    Enum.each(wrapped, fn element ->
      command_fn.(element, context, bindings)
    end)

    wrapped
  end
end
