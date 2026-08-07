defmodule Anemos.Runtime.ContextScope do
  @moduledoc """
  The one comparison that decides whether one context path lies inside another.

  Under the 2026-08-06 multi-tenant decision `context` is a security
  boundary, so this predicate is the boundary check itself, and two
  properties matter more than convenience:

  **It compares path segments, not string prefixes.** `garage` and
  `garageband.amp` share a prefix and share no context; treating
  `String.starts_with?/2` as containment let the second reach rules scoped
  to the first (A-06).

  **It fails closed.** An absent inner path is not "unscoped and therefore
  allowed" — it is a caller that did not say where it was standing, and a
  declared boundary has to refuse it. The one direction that opens is an
  absent *outer* path, which means no boundary was declared at all.

  Both the dispatcher's rule filter (A-06, A-39) and the capability
  server's demand gate (A-07) call this, deliberately: two copies of a
  boundary check are two chances to fix only one of them.
  """

  @doc """
  True when `inner` names the same context as `outer` or a context beneath it.

  `outer` is the declared boundary — a rule's `context` block, or a
  capability's `context` line. `inner` is whoever is trying to cross it —
  the event's `:context_path`, or the demanding rule's context.

  ## Examples

      iex> alias Anemos.Runtime.ContextScope
      iex> ContextScope.within?("garage", "garage")
      true
      iex> ContextScope.within?("garage.door", "garage")
      true
      iex> ContextScope.within?("garageband.amp", "garage")
      false
      iex> ContextScope.within?(nil, "garage")
      false
      iex> ContextScope.within?(nil, nil)
      true

  """
  @spec within?(String.t() | nil, String.t() | nil) :: boolean()
  def within?(inner, outer), do: check(normalize(inner), normalize(outer))

  # No boundary declared: nothing to enforce.
  defp check(_inner, nil), do: true

  # A boundary was declared and the caller named no context. Deny — this is
  # the default-shaped call (`Anemos.Runtime.dispatch(:anemos, "EVENT")`)
  # and it must not be the one that disables isolation.
  defp check(nil, _outer), do: false

  defp check(same, same), do: true
  defp check(inner, outer), do: String.starts_with?(inner, outer <> ".")

  defp normalize(nil), do: nil
  defp normalize(""), do: nil
  defp normalize(path) when is_binary(path), do: path
end
