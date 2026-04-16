defmodule Anemos.Runtime.SubscribableRegistry do
  @moduledoc """
  Agent mapping protocol strings to `Anemos.Subscribable` handler modules.

  Unlike `DataModelRegistry` (which derives the key from the handler via
  `keyword/0`), the protocol string is supplied externally at registration
  time because `Subscribable` handlers receive the protocol as a parameter
  rather than owning it intrinsically.
  """

  use Agent

  @doc """
  Starts a subscribable registry.

  ## Options

    * `:name` — process registration name (optional)
  """
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name)
    Agent.start_link(fn -> %{} end, name: name)
  end

  @doc """
  Registers a handler module under the given protocol string.

  ## Examples

      iex> {:ok, reg} = Anemos.Runtime.SubscribableRegistry.start_link()
      iex> Anemos.Runtime.SubscribableRegistry.register(reg, "webhook", MyHandler)
      :ok

  """
  @spec register(pid() | atom(), String.t(), module()) :: :ok
  def register(registry, protocol, handler_module) do
    Agent.update(registry, &Map.put(&1, protocol, handler_module))
  end

  @doc """
  Looks up a handler module by protocol string.

  Returns `{:ok, module}` or `:error`.

  ## Examples

      iex> {:ok, reg} = Anemos.Runtime.SubscribableRegistry.start_link()
      iex> Anemos.Runtime.SubscribableRegistry.lookup(reg, "missing")
      :error

  """
  @spec lookup(pid() | atom(), String.t()) :: {:ok, module()} | :error
  def lookup(registry, protocol) do
    case Agent.get(registry, &Map.get(&1, protocol)) do
      nil -> :error
      module -> {:ok, module}
    end
  end

  @doc """
  Returns all registered protocol strings.

  ## Examples

      iex> {:ok, reg} = Anemos.Runtime.SubscribableRegistry.start_link()
      iex> Anemos.Runtime.SubscribableRegistry.list(reg)
      []

  """
  @spec list(pid() | atom()) :: [String.t()]
  def list(registry) do
    Agent.get(registry, &Map.keys/1)
  end
end
