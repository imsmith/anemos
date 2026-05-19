defmodule Anemos.Runtime.Duration do
  @moduledoc """
  Converts duration tuples (e.g., `{5, :min}`) to milliseconds.

  Supported units: `:ms`, `:s`, `:seconds`, `:min`, `:minutes`,
  `:h`, `:hours`, `:d`, `:days`.
  """

  @doc """
  Converts a duration tuple to milliseconds.

  ## Examples

      iex> Anemos.Runtime.Duration.to_ms({5, :min})
      300_000

      iex> Anemos.Runtime.Duration.to_ms({2, :s})
      2_000
  """
  @spec to_ms({non_neg_integer(), atom()}) :: non_neg_integer()
  def to_ms({amount, :ms}), do: amount
  def to_ms({amount, :s}), do: amount * 1_000
  def to_ms({amount, :seconds}), do: amount * 1_000
  def to_ms({amount, :min}), do: amount * 60_000
  def to_ms({amount, :minutes}), do: amount * 60_000
  def to_ms({amount, :h}), do: amount * 3_600_000
  def to_ms({amount, :hours}), do: amount * 3_600_000
  def to_ms({amount, :d}), do: amount * 86_400_000
  def to_ms({amount, :days}), do: amount * 86_400_000
end
