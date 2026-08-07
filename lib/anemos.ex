defmodule Anemos do
  @moduledoc """
  Anemos — event-driven automation DSL.

  Provides `run/2` to parse, compile, and dispatch a rule source string
  against a given event in a single call.
  """

  alias Anemos.Compiler
  alias Anemos.Runtime.{ContextScope, Dispatcher, ModuleRegistry, Standalone}
  alias Anemos.Runtime.LoadAuthority
  alias Anemos.Runtime.Modules

  # The runtime name this path presents to the load authority. `run/2` has
  # no named runtime — it builds a throwaway dispatcher and tears it down
  # again — so it says so rather than borrowing the name of a runtime it
  # is not touching. An authority that keys on `LoadRequest.runtime`
  # therefore sees the standalone path as its own thing and can refuse it
  # outright, which is the right default for a host that only means to
  # permit loads into a runtime it named. See `LoadAuthority.gate/3`.
  @standalone_runtime :standalone

  @default_modules %{
    "DEVICE" => Modules.Device,
    "FILE" => Modules.File
  }

  # Deliberately NOT defaults. A stub that answers `SECRET::unlock` with a
  # plausible-looking value is the one registration that must never be
  # ambient: it turns a rule that should have failed loudly into one that
  # appears to have unlocked something. Requiring an explicit opt-in keeps
  # "I am running against fakes" a decision someone made, not a default
  # they inherited. `Example.File` overrides the default `FILE` rather than
  # changing it, so the shipped stub keeps its documented behaviour.
  @example_modules %{
    "EVENT" => Modules.Example.Event,
    "FILE" => Modules.Example.File,
    "INFRA" => Modules.Example.Infra,
    "PDF" => Modules.Example.Pdf,
    "SECRET" => Modules.Example.Secret,
    "STRING" => Modules.Example.String
  }

  @typedoc """
  What a single `run/2` actually did, beyond the operations it produced.

  `:subscribed` and `:reachable` exist because an empty result list has
  three unrelated causes, and a caller that cannot tell them apart cannot
  act on any of them: nothing subscribed to the event, something subscribed
  but the context boundary denied it, or a rule ran and every branch was
  false. See `run_report/2`.
  """
  @type report :: %{
          event: String.t(),
          context_path: String.t() | nil,
          operations: list(),
          results: list(),
          errors: list(),
          subscribed: non_neg_integer(),
          reachable: non_neg_integer()
        }

  @doc """
  The default module registrations used by `run/2` and `run_report/2`.

  Every one of these is a development stub: it computes in memory and
  performs no I/O. They exist so the DSL and the shipped examples can be
  exercised, not so a rule file can manage real infrastructure.
  """
  @spec default_modules() :: %{String.t() => module()}
  def default_modules, do: @default_modules

  @doc """
  Fake module registrations that let `priv/examples/` run end to end.

  These are demonstration doubles, not implementations: they compute from
  their arguments and the supplied context data and touch nothing outside
  the VM. Pass them explicitly (`modules: Anemos.example_modules()`, or
  `mix anemos.run --stub-modules`) — they are not registered by default,
  because `SECRET` and `INFRA` answering plausibly is exactly the failure a
  policy author needs to see rather than sail past.
  """
  @spec example_modules() :: %{String.t() => module()}
  def example_modules, do: @example_modules

  @doc """
  Parse, compile, and dispatch an event against rules in `source`.

  Options:
    - `:event` — the event name to dispatch (required)
    - `:context` — optional raw runtime context map (default `%{}`)
    - `:context_path` — the context the caller occupies, for boundary
      matching against each rule's `context` block
    - `:context_data` — external key-value data that `?var` resolves against
    - `:modules` — extra module registrations, merged over `default_modules/0`
    - `:authorization` — passed through to the configured
      `Anemos.Runtime.LoadAuthority` as `LoadRequest.authorization`; a token,
      a peer identity, whatever the authority was written to check

  `:context_path` and `:context_data` are merged into `:context`; they are a
  convenience for callers that would otherwise hand-build the map. They are
  two different things: the first is the scope the caller is standing in,
  the second is the data it brought with it.

  ## The load is gated

  `source` goes through the same trust boundary as
  `Anemos.Runtime.load/3`: the unwaivable `:max_policy_bytes` ceiling, then
  the module configured as `config :anemos, :load_authority` (A-59). This
  is not a developer shortcut around the boundary — a host embedding this
  to execute policy it did not write gets the gate it configured, here as
  well as there.

  A refusal is `{:error, %Comn.Errors.ErrorStruct{}}` with code
  `anemos.runtime/load_denied`. The default authority is
  `LoadAuthority.Permissive`, so an embedder that has configured nothing
  sees no change.

  Returns `{:ok, results}` or `{:error, reason}`. Use `run_report/2` when an
  empty result list needs to be distinguished from a boundary denial.

  ## Examples

      iex> source = "rule t { when EV { [DEVICE::set \\"light\\" \\"on\\"] } }"
      iex> {:ok, [%{module: "DEVICE", verb: "set", args: ["light", "on"]}]} =
      ...>   Anemos.run(source, event: "EV")

      iex> source = "rule t { context \\"garage\\" { when EV { log \\"hi\\" } } }"
      iex> {:ok, []} = Anemos.run(source, event: "EV")
      iex> {:ok, [_]} = Anemos.run(source, event: "EV", context_path: "garage")

      iex> {:error, _} = Anemos.run("rule {", event: "EV")
  """
  @spec run(String.t(), keyword()) ::
          {:ok, list()} | {:error, String.t() | Comn.Errors.ErrorStruct.t()}
  def run(source, opts) do
    case run_report(source, opts) do
      {:ok, report} -> {:ok, report.operations}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Like `run/2`, but returns a `t:report/0` instead of a bare result list.

  ## Examples

      iex> source = "rule t { context \\"garage\\" { when EV { log \\"hi\\" } } }"
      iex> {:ok, denied} = Anemos.run_report(source, event: "EV")
      iex> {denied.subscribed, denied.reachable, denied.operations}
      {1, 0, []}

      iex> source = "rule t { when EV { log \\"hi\\" } }"
      iex> {:ok, silent} = Anemos.run_report(source, event: "OTHER")
      iex> {silent.subscribed, silent.reachable}
      {0, 0}
  """
  @spec run_report(String.t(), keyword()) ::
          {:ok, report()} | {:error, String.t() | Comn.Errors.ErrorStruct.t()}
  def run_report(source, opts) do
    event = Keyword.fetch!(opts, :event)
    context = build_context(opts)
    context_path = Map.get(context, :context_path)
    modules = Map.merge(@default_modules, Keyword.get(opts, :modules, %{}))

    # The same gate `Anemos.Runtime.load/3` goes through, because it is
    # the only way to get an AST for the compiler (A-59). This path used
    # to call `Parser.parse/1` itself, which is exactly how it ended up
    # with no ceiling and no authority while looking like it had both.
    with {:ok, ast} <- LoadAuthority.gate(@standalone_runtime, source, opts),
         {:ok, compiled} <- Compiler.compile(ast),
         {:ok, registry} <- ModuleRegistry.start_link([]) do
      try do
        Enum.each(modules, fn {name, mod} ->
          ModuleRegistry.register(registry, name, mod)
        end)

        with {:ok, dispatcher} <-
               Standalone.start_link(
                 rules: compiled.rules,
                 registry: registry,
                 conditions: compiled.conditions,
                 capabilities: compiled.capabilities,
                 data_blocks: compiled.data_blocks
               ) do
          try do
            raw_results = Dispatcher.dispatch(dispatcher, event, context)

            operations =
              Enum.map(raw_results, fn
                {:ok, value} -> value
                {:error, _} = err -> err
              end)

            {errors, results} = Enum.split_with(operations, &match?({:error, _}, &1))
            subscribed = subscribers(compiled.rules, event)

            {:ok,
             %{
               event: event,
               context_path: context_path,
               operations: operations,
               results: results,
               errors: errors,
               subscribed: length(subscribed),
               reachable: length(reachable(subscribed, context_path))
             }}
          after
            # Standalone.stop/1, not GenServer.stop/1: stopping the
            # dispatcher exits :normal, which every non-trapping linked
            # store ignores. That left the triple store, data store,
            # subscribable registry and one process per condition and
            # capability alive for the life of the VM.
            Standalone.stop(dispatcher)
          end
        end
      after
        Agent.stop(registry)
      end
    end
  end

  # --- Private ---

  # `:context` stays the authoritative map so callers that already build one
  # keep working; `:context_path` and `:context_data` are folded in on top.
  defp build_context(opts) do
    opts
    |> Keyword.get(:context, %{})
    |> put_unless_nil(:context_path, Keyword.get(opts, :context_path))
    |> merge_context_data(Keyword.get(opts, :context_data))
  end

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)

  defp merge_context_data(context, nil), do: context

  defp merge_context_data(context, data) when is_map(data) do
    Map.update(context, :context_data, data, &Map.merge(&1 || %{}, data))
  end

  defp subscribers(rules, event) do
    Enum.filter(rules, &(event in &1.subscriptions))
  end

  # The same predicate the dispatcher filters on, asked ahead of time. It is
  # a report of what the boundary will do, not a second boundary — nothing
  # is admitted or denied here.
  defp reachable(subscribed_rules, context_path) do
    Enum.filter(subscribed_rules, fn rule ->
      ContextScope.within?(context_path, get_in(rule, [Access.key(:meta), :context_path]))
    end)
  end
end
