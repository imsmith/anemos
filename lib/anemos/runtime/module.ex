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

  @doc """
  What a policy learns from `show NAME`, `explain NAME` and `list NAME`:
  `%{look: String.t(), recon: map(), choices: map()}`, Comn's three
  questions. For a module bound under several names — a bridge that serves
  every discovered tool — this answers per name, which Comn's own
  nullary callbacks cannot.
  """
  @callback describe(name :: String.t()) :: %{look: String.t(), recon: map(), choices: map()}

  @optional_callbacks arg_schema: 1, describe: 1

  @doc """
  A module's card for the name it is bound under: `describe/1` if it has
  one, else its `Comn` callbacks, else what the runtime knows — the name,
  the Elixir module, and the verbs declared with `use Anemos.Module`.

  The module's own code runs in a process of its own with a deadline
  (1000 ms): it is host code, called from inside the dispatcher on a
  policy's say-so, and a card that raises, blocks or comes back in the
  wrong shape is a card the runtime did not get, not a dead dispatcher.
  """
  @card_timeout_ms 1_000

  @spec card(module(), String.t()) :: %{look: String.t(), recon: map(), choices: map()}
  def card(module, name) do
    asked =
      cond do
        function_exported?(module, :describe, 1) ->
          isolated(fn -> module.describe(name) end)

        function_exported?(module, :look, 0) and function_exported?(module, :recon, 0) and
            function_exported?(module, :choices, 0) ->
          isolated(fn ->
            %{look: module.look(), recon: module.recon(), choices: module.choices()}
          end)

        true ->
          :none
      end

    case asked do
      {:ok, %{look: look, recon: recon, choices: choices}}
      when is_binary(look) and is_map(recon) and is_map(choices) ->
        %{look: look, recon: recon, choices: choices}

      {:ok, _other_shape} ->
        default_card(module, name, "did not answer in the expected shape")

      {:error, reason} ->
        default_card(module, name, reason)

      :none ->
        default_card(module, name, nil)
    end
  end

  defp default_card(module, name, trouble) do
    verbs =
      if function_exported?(module, :__anemos_verbs__, 0),
        do: module.__anemos_verbs__(),
        else: :any

    look = "#{name} — #{inspect(module)}" <> if(trouble, do: " (#{trouble})", else: "")

    %{
      look: look,
      recon: %{type: :implementation, module: module, verbs: verbs},
      choices: %{verbs: verbs}
    }
  end

  defp isolated(fun) do
    parent = self()
    tag = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        result =
          try do
            {:ok, fun.()}
          rescue
            exception -> {:error, "raised #{inspect(exception.__struct__)}"}
          catch
            kind, _ -> {:error, "#{kind} while answering"}
          end

        send(parent, {tag, result})
      end)

    receive do
      {^tag, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        {:error, "died while answering"}
    after
      @card_timeout_ms ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])
        {:error, "did not answer within #{@card_timeout_ms} ms"}
    end
  end

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
