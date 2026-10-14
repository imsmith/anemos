defmodule Anemos.Module do
  @moduledoc """
  Macro for defining Anemos modules — named sets of verb handlers.

  Most modules are thin wrappers around existing functions. This macro
  eliminates the boilerplate of implementing the `Anemos.Runtime.Module`
  behaviour by hand.

  ## Usage

      # lib/my_app/anemos/secret.ex — inside MyApp.Anemos.Secret
      use Anemos.Module, name: "SECRET"

      verb :unlock, &MyApp.Vault.unlock/2

  Then register it:

      Anemos.Runtime.register(:anemos, MyApp.Anemos.Secret)

  > #### Wrap secret-bearing return values {: .warning}
  >
  > A verb that returns credential material should wrap it in
  > `Anemos.Secret.new/2`. The wrapper redacts through `inspect/1`,
  > string interpolation and `Logger`, which is what keeps a secret out of
  > the application log when a policy does `log @token` or emits through
  > the default channel connector. Nothing else on that path will redact
  > it for you.

  The module carries its own name — no string to fat-finger at the call site.

  ## Verb functions

  Each verb function receives `(args, context)` where `args` is the list
  of resolved arguments from the policy and `context` is the dispatch context
  map. It should return `{:ok, result}` or `{:error, reason}`.

  If your function takes a different arity, wrap it:

      verb :get_ip, fn args, _ctx -> MyApp.Infra.get_ip(hd(args)) end
  """

  @doc false
  defmacro __using__(opts) do
    name = Keyword.fetch!(opts, :name)

    quote do
      @behaviour Anemos.Runtime.Module
      @behaviour Comn

      Module.register_attribute(__MODULE__, :anemos_verb_names, accumulate: true)
      @anemos_name unquote(name)

      import Anemos.Module, only: [verb: 2]

      @before_compile Anemos.Module
    end
  end

  @doc """
  Registers a verb handler.

  The function should accept `(args :: list(), context :: map())`.
  """
  defmacro verb(verb_name, func) do
    verb_str = Atom.to_string(verb_name)

    quote do
      @anemos_verb_names unquote(verb_name)

      @impl Anemos.Runtime.Module
      def handle_verb(unquote(verb_str), args, context) do
        unquote(func).(args, context)
      end
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    name = Module.get_attribute(env.module, :anemos_name)
    verb_names = Module.get_attribute(env.module, :anemos_verb_names) |> Enum.reverse()
    verb_strings = Enum.map(verb_names, &Atom.to_string/1)

    quote do
      @doc """
      Returns the module name as registered in Anemos (e.g., `"SECRET"`).
      """
      def __anemos_name__, do: unquote(name)

      @doc """
      Returns the list of verb names this module handles.
      """
      def __anemos_verbs__, do: unquote(verb_names)

      @impl Anemos.Runtime.Module
      def handle_verb(verb, _args, _context) do
        {:error,
         Comn.Errors.Registry.error!("anemos.runtime/unknown_verb",
           message: "Verb #{verb} not found on module #{unquote(name)}"
         )}
      end

      @impl Comn
      def look, do: unquote(name) <> " — Anemos verb handler module"

      @impl Comn
      def recon do
        %{
          type: :implementation,
          anemos_name: unquote(name),
          verbs: unquote(verb_names)
        }
      end

      @impl Comn
      def choices do
        %{verbs: unquote(verb_strings)}
      end

      @impl Comn
      def act(%{verb: verb, args: args, context: ctx}), do: handle_verb(verb, args, ctx)
      def act(%{verb: verb, args: args}), do: handle_verb(verb, args, %{})
      def act(_input), do: {:error, Comn.Errors.Registry.error!("anemos.runtime/unknown_action")}
    end
  end
end
