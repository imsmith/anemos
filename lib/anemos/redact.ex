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
end
