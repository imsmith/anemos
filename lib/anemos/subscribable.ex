defmodule Anemos.Subscribable do
  @moduledoc """
  Behaviour for data sources that support dynamic subscription.

  Implementations register a protocol identifier (e.g., "webhook",
  "rss", "amqp") used in `dynamic { subscribe <protocol> <uri> }` blocks.
  """

  @doc "Subscribes to the given URI using the named protocol. Returns `{:ok, ref}` on success or `{:error, reason}` on failure."
  @callback subscribe(protocol :: String.t(), uri :: String.t(), callback :: fun()) :: {:ok, reference()} | {:error, atom()}

  @doc "Cancels an active subscription identified by `ref`. Always returns `:ok`."
  @callback unsubscribe(ref :: reference()) :: :ok

  @doc "Returns `true` if this source is polled on a schedule rather than push-based."
  @callback periodic?() :: boolean()

  @doc "Converts a human-readable interval spec (e.g., `\"5m\"`) to milliseconds."
  @callback interval(spec :: String.t()) :: pos_integer()
end
