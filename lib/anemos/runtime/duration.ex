defmodule Anemos.Runtime.Duration do
  @moduledoc """
  Converts duration tuples (e.g., `{5, :min}`) to milliseconds.

  Supported units: `:ms`, `:s`, `:seconds`, `:min`, `:minutes`,
  `:h`, `:hours`, `:d`, `:days`.

  `to_ms/1` never raises: an unrecognised unit or a malformed term yields an
  error tuple. This matters because callers run inside long-lived processes —
  a `FunctionClauseError` here would take the scheduler down rather than
  reject one bad schedule. Use `to_ms!/1` where a bad unit should abort the
  caller instead (compile time, say).
  """

  @doc """
  Converts a duration tuple to milliseconds.

  Returns the millisecond count, or `{:error, {:unknown_duration_unit, unit}}`
  for an unrecognised unit, or `{:error, {:invalid_duration, term}}` for
  anything that is not a `{amount, unit}` pair.

  ## Examples

      iex> Anemos.Runtime.Duration.to_ms({5, :min})
      300_000

      iex> Anemos.Runtime.Duration.to_ms({2, :s})
      2_000

      iex> Anemos.Runtime.Duration.to_ms({2, :fortnights})
      {:error, {:unknown_duration_unit, :fortnights}}
  """
  @spec to_ms(term()) ::
          non_neg_integer()
          | {:error, {:unknown_duration_unit, atom()} | {:invalid_duration, term()}}
  def to_ms({amount, :ms}), do: amount
  def to_ms({amount, :s}), do: amount * 1_000
  def to_ms({amount, :seconds}), do: amount * 1_000
  def to_ms({amount, :min}), do: amount * 60_000
  def to_ms({amount, :minutes}), do: amount * 60_000
  def to_ms({amount, :h}), do: amount * 3_600_000
  def to_ms({amount, :hours}), do: amount * 3_600_000
  def to_ms({amount, :d}), do: amount * 86_400_000
  def to_ms({amount, :days}), do: amount * 86_400_000
  def to_ms({_amount, unit}) when is_atom(unit), do: {:error, {:unknown_duration_unit, unit}}
  def to_ms(other), do: {:error, {:invalid_duration, other}}

  @doc """
  Converts a duration tuple to milliseconds, raising on anything unrecognised.

  ## Examples

      iex> Anemos.Runtime.Duration.to_ms!({5, :min})
      300_000
  """
  @spec to_ms!(term()) :: non_neg_integer()
  def to_ms!(duration) do
    case to_ms(duration) do
      {:error, {:unknown_duration_unit, unit}} ->
        raise ArgumentError, "unknown duration unit #{inspect(unit)}"

      {:error, {:invalid_duration, term}} ->
        raise ArgumentError, "invalid duration #{inspect(term)}"

      ms ->
        ms
    end
  end
end
