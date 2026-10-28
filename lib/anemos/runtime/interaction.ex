defmodule Anemos.Runtime.Interaction do
  @moduledoc """
  The vocabulary shared by `on <interaction>` blocks and the host.

  A `when` takes a *report*: an event with a truth at the time it arrives,
  which stands until the next report of the same event and feeds compound
  triggers, dwell timers and conditions. An `on` takes an *interaction*: an
  occurrence with no truth, never remembered, fired once per occurrence.
  Boot, shutdown, a keypress, a login — things that happen, not claims
  about the world.

  Interactions travel the same index as events under names in the reserved
  `ON_` namespace, which `when` may not subscribe to and `dispatch/4` may
  not send. The compiler and the runtime both derive those names here so a
  host's `interact(:rt, {:keypress, "ESC"})` meets the block compiled from
  `on keypress "ESC"`.
  """

  @prefix "ON_"

  @type t :: :boot | :shutdown | {:keypress, String.t()} | {:named, String.t()}

  @doc "The event name an interaction is indexed under."
  @spec event_name(t()) :: String.t()
  def event_name(:boot), do: @prefix <> "BOOT"
  def event_name(:shutdown), do: @prefix <> "SHUTDOWN"
  def event_name({:keypress, key}), do: @prefix <> "KEYPRESS_" <> sanitize(key)
  def event_name({:named, name}), do: @prefix <> name

  @doc "Whether an event name sits in the interaction namespace."
  @spec reserved?(String.t()) :: boolean()
  def reserved?(@prefix <> _), do: true
  def reserved?(_), do: false

  @doc """
  What a host may raise: a keypress, or a named interaction written like an
  event id. Boot and shutdown are the runtime's to raise, at the points a
  policy becomes active and stops being so.
  """
  @spec from_host(term()) :: {:ok, t()} | {:error, Comn.Errors.ErrorStruct.t()}
  def from_host({:keypress, key}) when is_binary(key) and key != "", do: {:ok, {:keypress, key}}

  def from_host(name) when is_binary(name) do
    if Regex.match?(~r/^[A-Z][A-Z0-9_]*$/, name) and not reserved?(name) do
      {:ok, {:named, name}}
    else
      not_an_interaction(name)
    end
  end

  def from_host(other), do: not_an_interaction(inspect(other))

  defp not_an_interaction(text) do
    {:error,
     Comn.Errors.Registry.error!("anemos.runtime/not_an_interaction",
       field: text,
       message:
         "an interaction is {:keypress, key} or an UPPER_CASE name outside the ON_ namespace"
     )}
  end

  # "ctrl+c" -> "CTRL_C". Keys are host text, so the name is bounded to the
  # event-id alphabet rather than trusted.
  defp sanitize(key) do
    key |> String.upcase() |> String.replace(~r/[^A-Z0-9]+/, "_") |> String.trim("_")
  end
end
