defmodule Anemos do
  @moduledoc """
  Anemos — event-driven automation DSL.

  Provides `run/2` to parse, compile, and dispatch a rule source string
  against a given event in a single call.
  """

  alias Anemos.Parser
  alias Anemos.Compiler
  alias Anemos.Runtime.{Dispatcher, ModuleRegistry}
  alias Anemos.Runtime.Modules

  @default_modules %{
    "DEVICE" => Modules.Device,
    "FILE" => Modules.File
  }

  @doc """
  Parse, compile, and dispatch an event against rules in `source`.

  Options:
    - `:event` — the event name to dispatch (required)
    - `:context` — optional context map (default `%{}`)

  Returns `{:ok, results}` or `{:error, reason}`.
  """
  @spec run(String.t(), keyword()) :: {:ok, list()} | {:error, String.t()}
  def run(source, opts) do
    event = Keyword.fetch!(opts, :event)
    context = Keyword.get(opts, :context, %{})

    with {:ok, ast} <- Parser.parse(source),
         {:ok, rules} <- Compiler.compile(ast) do
      {:ok, registry} = ModuleRegistry.start_link([])

      try do
        Enum.each(@default_modules, fn {name, mod} ->
          ModuleRegistry.register(registry, name, mod)
        end)

        {:ok, dispatcher} = Dispatcher.start_link(rules: rules, registry: registry)

        try do
          raw_results = Dispatcher.dispatch(dispatcher, event, context)

          results =
            Enum.flat_map(raw_results, fn
              {:ok, value} -> [value]
              {:error, _} = err -> [err]
            end)

          {:ok, results}
        after
          GenServer.stop(dispatcher)
        end
      after
        Agent.stop(registry)
      end
    end
  end
end
