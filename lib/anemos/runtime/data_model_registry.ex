defmodule Anemos.Runtime.DataModelRegistry do
  @moduledoc """
  Agent mapping data model keyword strings to handler modules.

  Handler modules must implement the `Anemos.DataModel` behaviour and
  expose a `keyword/0` function that returns their format identifier.
  """

  use Agent

  @doc """
  Starts a data model registry.

  ## Options

    * `:name` — process registration name (optional)
  """
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name)
    Agent.start_link(fn -> %{} end, name: name)
  end

  @doc """
  Registers a handler module under its own keyword.

  The module must implement `Anemos.DataModel` and return a keyword from `keyword/0`.

  ## Examples

      iex> {:ok, reg} = Anemos.Runtime.DataModelRegistry.start_link()
      iex> Anemos.Runtime.DataModelRegistry.register(reg, MyHandler)
      :ok

  """
  @spec register(pid() | atom(), module()) :: :ok
  def register(registry, handler_module) do
    keyword = handler_module.keyword()
    Agent.update(registry, &Map.put(&1, keyword, handler_module))
  end

  @doc """
  Looks up a handler module by keyword string.

  Returns `{:ok, module}` or `:error`.

  ## Examples

      iex> {:ok, reg} = Anemos.Runtime.DataModelRegistry.start_link()
      iex> Anemos.Runtime.DataModelRegistry.lookup(reg, "missing")
      :error

  """
  @spec lookup(pid() | atom(), String.t()) :: {:ok, module()} | :error
  def lookup(registry, keyword) do
    case Agent.get(registry, &Map.get(&1, keyword)) do
      nil -> :error
      module -> {:ok, module}
    end
  end

  @doc """
  Returns all registered keyword strings.

  ## Examples

      iex> {:ok, reg} = Anemos.Runtime.DataModelRegistry.start_link()
      iex> Anemos.Runtime.DataModelRegistry.list(reg)
      []

  """
  @spec list(pid() | atom()) :: [String.t()]
  def list(registry) do
    Agent.get(registry, &Map.keys/1)
  end
end
