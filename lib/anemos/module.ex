defmodule Anemos.Module do
  @moduledoc """
  Macro for defining Anemos modules — named sets of verb handlers.

  Most modules are thin wrappers around existing functions. This macro
  eliminates the boilerplate of implementing the `Anemos.Runtime.Module`
  behaviour by hand.

  ## Usage

      # lib/my_app/anemos/secret.ex
      use Anemos.Module, name: "SECRET"

      verb :unlock, &Comn.Secret.unlock/2
      verb :rotate, &Comn.Secret.rotate/1

  Then register it:

      Anemos.Runtime.register(:anemos, MyApp.Anemos.Secret)

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
        {:error, {:unknown_verb, unquote(name), verb}}
      end
    end
  end
end
