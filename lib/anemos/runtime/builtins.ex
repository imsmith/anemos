defmodule Anemos.Runtime.Builtins do
  @moduledoc """
  Built-in collection-processing functions for pipeline expressions.

  Called directly by the compiler when evaluating pipe expressions
  with filter/map/reduce/emit. Not user-facing — no module registration.
  """

  def filter(collection, var_name, predicate_fn, context, bindings) do
    context = ensure_context_data(context)

    collection
    |> List.wrap()
    |> Enum.filter(fn element ->
      iter_context = put_in(context, [:context_data, var_name], element)
      predicate_fn.(iter_context, bindings)
    end)
  end

  def map(collection, var_name, transform_fn, context, bindings) do
    context = ensure_context_data(context)

    collection
    |> List.wrap()
    |> Enum.map(fn element ->
      iter_context = put_in(context, [:context_data, var_name], element)
      transform_fn.(iter_context, bindings)
    end)
  end

  def reduce(collection, acc_name, initial, var_name, body_fn, context, bindings) do
    context = ensure_context_data(context)

    collection
    |> List.wrap()
    |> Enum.reduce(initial, fn element, acc ->
      iter_context = put_in(context, [:context_data, var_name], element)
      iter_bindings = Map.put(bindings, {:set, acc_name}, acc)

      body_fn.(iter_context, iter_bindings)
    end)
  end

  def emit(collection, command_fn, context, bindings) do
    wrapped = List.wrap(collection)

    Enum.each(wrapped, fn element ->
      command_fn.(element, context, bindings)
    end)

    wrapped
  end

  defp ensure_context_data(%{context_data: _} = context), do: context
  defp ensure_context_data(context), do: Map.put(context, :context_data, %{})
end
