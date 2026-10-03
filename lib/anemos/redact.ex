defmodule Anemos.Redact do
  @moduledoc """
  Shape summaries for values that must be observable without being disclosed.

  Anemos emits are deliberately never silent, but "not silent" must not mean
  "fully disclosed". `summarize/1` describes a term's type and size — enough
  to see that an emit happened and roughly what it carried — while never
  including the term's contents, keys, or any `Anemos.Secret` plaintext.
  """

  @doc """
  Describes a term by type and size, never by content.

  ## Examples

      iex> Anemos.Redact.summarize("hello")
      "binary(5 bytes)"

      iex> Anemos.Redact.summarize(%{a: 1, b: 2})
      "map(2 keys)"

      iex> Anemos.Redact.summarize(Anemos.Secret.new("hunter2"))
      "secret(redacted)"

  """
  @spec summarize(term()) :: String.t()
  def summarize(%Anemos.Secret{}), do: "secret(redacted)"
  def summarize(nil), do: "nil"
  def summarize(term) when is_boolean(term), do: "boolean"
  def summarize(term) when is_atom(term), do: "atom"
  def summarize(term) when is_binary(term), do: "binary(#{byte_size(term)} bytes)"
  def summarize(term) when is_bitstring(term), do: "bitstring(#{bit_size(term)} bits)"
  def summarize(term) when is_integer(term), do: "integer"
  def summarize(term) when is_float(term), do: "float"
  def summarize(term) when is_pid(term), do: "pid"
  def summarize(term) when is_reference(term), do: "reference"
  def summarize(term) when is_port(term), do: "port"
  def summarize(term) when is_function(term), do: "function"
  def summarize(term) when is_list(term), do: "list(#{length(term)} items)"
  def summarize(term) when is_tuple(term), do: "tuple(#{tuple_size(term)} elements)"

  def summarize(%module{} = term) do
    "%#{inspect(module)}{}(#{map_size(Map.from_struct(term))} fields)"
  end

  def summarize(term) when is_map(term), do: "map(#{map_size(term)} keys)"

  @doc """
  A value as the trace may keep it: every `Anemos.Secret` replaced by
  `"[REDACTED]"`, strings cut at #{1_000} bytes, lists and maps cut at
  #{50} entries, nesting cut at depth #{4}, and anything that is none of
  those described by `summarize/1`. The table the trace lives in is public
  and the ring holds hundreds of entries; what goes in has to be safe to
  read and small enough to keep.
  """
  @spec for_trace(term()) :: term()
  def for_trace(value), do: for_trace(value, 4)

  @max_string 1_000
  @max_entries 50

  defp for_trace(%Anemos.Secret{}, _depth), do: "[REDACTED]"
  defp for_trace(value, _depth) when is_atom(value) or is_number(value), do: value

  defp for_trace(value, _depth) when is_binary(value) do
    if byte_size(value) > @max_string,
      do: binary_part(value, 0, @max_string) <> "… (#{byte_size(value)} bytes)",
      else: value
  end

  defp for_trace(_value, 0), do: "…"

  defp for_trace(list, depth) when is_list(list) do
    kept = list |> Enum.take(@max_entries) |> Enum.map(&for_trace(&1, depth - 1))
    if length(list) > @max_entries, do: kept ++ ["… (#{length(list)} items)"], else: kept
  end

  defp for_trace(%_{} = struct, depth), do: struct |> Map.from_struct() |> for_trace(depth)

  defp for_trace(map, depth) when is_map(map) do
    kept =
      map |> Enum.take(@max_entries) |> Map.new(fn {k, v} -> {k, for_trace(v, depth - 1)} end)

    if map_size(map) > @max_entries, do: Map.put(kept, :"…", "#{map_size(map)} keys"), else: kept
  end

  defp for_trace(tuple, depth) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> for_trace(depth)

  defp for_trace(other, _depth), do: summarize(other)
end
