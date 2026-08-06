defmodule Anemos.Runtime.CapabilityServer do
  @moduledoc """
  GenServer for a single named capability.
  Passive until demanded. Executes its `on demand` handler and returns the result.

  ## The context check lives here

  A capability's `context` line names who may demand it. The check is made
  in this process rather than in `Anemos.Runtime.Demand` because this is
  where the capability's own declared context lives: a caller cannot reach
  the handler without passing an argument that says where it is standing,
  and an argument it forgets to pass is a denial rather than a pass (A-07).
  """

  use GenServer

  alias Anemos.Runtime.ContextScope

  @doc """
  Starts a capability server.

  ## Options

    * `:name_str` — the capability name (required)
    * `:context` — the context scope, or `nil` for an unscoped capability (required)
    * `:handler` — 1-arity function `(context) -> {:ok, ops} | {:error, reason}` (required)
    * `:name` — process registration name (optional)
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Executes the capability's on-demand handler with the given context.

  `demanding_context` is the context path of the rule making the demand.
  It must lie within the capability's declared context — see
  `Anemos.Runtime.ContextScope`. A capability declared without a context is
  demandable from anywhere; a capability *with* one refuses a demander that
  names no context at all.

  Returns `{:ok, operations}`, `{:error, {:context_denied, error}}`, or
  `{:error, reason}` from the handler.

  ## Examples

      iex> {:ok, pid} = Anemos.Runtime.CapabilityServer.start_link(name_str: "k", context: nil, handler: fn _ -> {:ok, []} end)
      iex> Anemos.Runtime.CapabilityServer.execute(pid, %{})
      {:ok, []}

      iex> {:ok, pid} = Anemos.Runtime.CapabilityServer.start_link(name_str: "k", context: "infra.networking", handler: fn _ -> {:ok, [:secret]} end)
      iex> Anemos.Runtime.CapabilityServer.execute(pid, %{}, "infra.networking.dns")
      {:ok, [:secret]}
      iex> {:error, {:context_denied, _}} = Anemos.Runtime.CapabilityServer.execute(pid, %{}, nil)

  """
  @spec execute(pid() | atom(), map(), String.t() | nil) :: {:ok, list()} | {:error, term()}
  def execute(server, context, demanding_context \\ nil) do
    GenServer.call(server, {:execute, context, demanding_context})
  end

  @impl true
  def init(opts) do
    state = %{
      name: Keyword.fetch!(opts, :name_str),
      context: Keyword.fetch!(opts, :context),
      handler: Keyword.fetch!(opts, :handler)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:execute, context, demanding_context}, _from, state) do
    if ContextScope.within?(demanding_context, state.context) do
      {:reply, run(state, context), state}
    else
      {:reply, {:error, {:context_denied, denial(state, demanding_context)}}, state}
    end
  end

  defp run(state, context) do
    state.handler.(context)
  rescue
    e in [RuntimeError, ArgumentError, FunctionClauseError, KeyError] ->
      {:error, {:capability_crash, state.name, Exception.message(e)}}
  end

  defp denial(state, demanding_context) do
    Comn.Errors.Registry.error!("anemos.runtime/capability_context_denied",
      message:
        "Capability #{state.name} is scoped to context '#{state.context}' and was demanded " <>
          "from #{describe(demanding_context)}"
    )
  end

  defp describe(nil), do: "a rule that declares no context"
  defp describe(""), do: "a rule that declares no context"
  defp describe(path), do: "context '#{path}'"
end
