defmodule Anemos.Runtime.Module do
  @moduledoc """
  Behaviour for Anemos runtime modules (DEVICE, FILE, etc.).

  Each module handles verbs dispatched from compiled rule operations.

  ## Argument validation

  `arg_schema/1` is optional. A module that implements it declares, per
  verb, what shape of argument list it is willing to receive; the
  dispatcher enforces that declaration *before* `handle_verb/3` is called,
  so a malformed or hostile argument never reaches host code. Returning
  `nil` for a verb — or not implementing the callback at all — leaves that
  verb unvalidated, which is what keeps modules written before A-11 working
  unchanged.

  The check lives in the framework rather than in each module on purpose:
  arguments come from untrusted policy text and untrusted event payloads,
  and a boundary that every host module author has to remember to build for
  themselves is a boundary that will be missing somewhere.

  See `Anemos.Runtime.ArgSchema` for the schema vocabulary, and
  `Anemos.Runtime.PathGuard` for confining a path-taking verb to a root.

      # in a module implementing this behaviour
      @impl true
      def arg_schema("read"), do: [[type: :string, path: :spool]]
      def arg_schema(_verb), do: nil

      @impl true
      def handle_verb("read", [path], _context), do: File.read(path)

  """

  @typedoc "What a verb answers: a host value, or a reason the verb refused."
  @type verb_result :: {:ok, any()} | {:error, any()}

  @doc "Executes `verb` with `args` already validated against `arg_schema/1`."
  @callback handle_verb(verb :: String.t(), args :: list(), context :: map()) :: verb_result()

  @doc "Returns the argument schema for `verb`, or `nil` to leave it unvalidated."
  @callback arg_schema(verb :: String.t()) :: Anemos.Runtime.ArgSchema.t()

  @optional_callbacks arg_schema: 1

  @doc """
  Returns `module`'s schema for `verb`, or `nil` when it declares none.

  Answers `nil` for a module that does not implement the optional callback,
  which is the pre-A-11 behaviour and is why old modules keep working.
  """
  @spec schema_for(module(), String.t()) :: Anemos.Runtime.ArgSchema.t()
  def schema_for(module, verb) do
    if function_exported?(module, :arg_schema, 1) do
      module.arg_schema(verb)
    else
      nil
    end
  end
end
