defmodule Anemos.Runtime.Modes do
  @moduledoc """
  Modes (PRD §3.13): named, runtime-wide, each active with a value or not
  active at all. `[MODE::set "away"]` makes `away` active with the value
  `true`, `[MODE::set "level" 2]` with the value `2`, and
  `[MODE::unset "away"]` makes it inactive.

  `it <mode> { ... }` gates the triggers inside it on the mode holding,
  and `as "<mode>"` and `by ... that` run when theirs comes to hold. A
  modal reference is `{mode, value}`. It holds when the mode is active and,
  for a non-nil `value`, when the mode's value equals it.

  `MODE` is the runtime's own module, not a host one. Its state is the
  dispatcher's, so a change runs in statement position where the
  dispatcher can act on it. `active` and `current` may be read anywhere.
  """

  @type t :: %{optional(String.t()) => term()}
  @type ref :: {String.t(), term()}

  @doc """
  Whether every modal reference holds.

      iex> Anemos.Runtime.Modes.holds?(%{"away" => true}, [{"away", nil}])
      true

      iex> Anemos.Runtime.Modes.holds?(%{"level" => 1}, [{"level", 2}])
      false
  """
  @spec holds?(t(), [ref()]) :: boolean()
  def holds?(modes, refs), do: Enum.all?(refs, &holds_one?(modes, &1))

  defp holds_one?(modes, {mode, nil}), do: Map.has_key?(modes, mode)
  defp holds_one?(modes, {mode, value}), do: Map.fetch(modes, mode) == {:ok, value}

  @doc """
  Runs a `MODE` verb in statement position: `{:ok, modes, result}`.
  """
  @spec change(t(), String.t(), list()) :: {:ok, t(), term()} | {:error, term()}
  def change(modes, "set", [mode]) when is_binary(mode),
    do: {:ok, Map.put(modes, mode, true), true}

  def change(modes, "set", [mode, value]) when is_binary(mode),
    do: {:ok, Map.put(modes, mode, value), value}

  def change(modes, "unset", [mode]) when is_binary(mode),
    do: {:ok, Map.delete(modes, mode), nil}

  def change(_modes, verb, args) when verb in ["set", "unset"], do: misuse(verb, args)

  def change(modes, verb, args) do
    with {:ok, value} <- read(modes, verb, args), do: {:ok, modes, value}
  end

  @doc """
  Runs a `MODE` verb in value position. Only `active` and `current` read;
  `set` and `unset` are refused here.

      iex> Anemos.Runtime.Modes.read(%{"away" => "weekend"}, "current", ["away"])
      {:ok, "weekend"}

      iex> Anemos.Runtime.Modes.read(%{"b" => true, "a" => 1}, "current", [])
      {:ok, ["a", "b"]}
  """
  @spec read(t(), String.t(), list()) :: {:ok, term()} | {:error, term()}
  def read(modes, "active", [mode]) when is_binary(mode), do: {:ok, Map.has_key?(modes, mode)}
  def read(modes, "current", []), do: {:ok, modes |> Map.keys() |> Enum.sort()}
  def read(modes, "current", [mode]) when is_binary(mode), do: {:ok, Map.get(modes, mode)}

  def read(_modes, verb, _args) when verb in ["set", "unset"] do
    bad("MODE::#{verb}", "MODE::#{verb} changes a mode; write it as a statement, not a value")
  end

  def read(_modes, verb, args), do: misuse(verb, args)

  defp misuse(verb, args) do
    bad(
      "MODE::#{verb}",
      "MODE::#{verb} with #{length(args)} argument(s) is not a mode call: use " <>
        "set \"<mode>\" [value], unset \"<mode>\", active \"<mode>\" or current [\"<mode>\"]"
    )
  end

  defp bad(field, message) do
    {:error,
     Comn.Errors.Registry.error!("anemos.runtime/bad_mode_call", field: field, message: message)}
  end
end
