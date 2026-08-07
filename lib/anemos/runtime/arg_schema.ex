defmodule Anemos.Runtime.ArgSchema do
  @moduledoc """
  Validates the arguments of a `[MODULE::verb ...]` command before they
  reach a host module.

  Arguments arrive from two untrusted places — policy literals and event
  payloads — and used to be handed to `handle_verb/3` verbatim (A-11). This
  module is the check, and the dispatcher is the only caller, so a host
  module cannot be reached by a path that skipped it.

  ## The schema format, and why it is this small

  A schema is a **list of positional argument specs**, one per argument.
  Each spec is a keyword list drawn from a fixed five-key vocabulary:

    * `:type` — `:string`, `:integer`, `:float`, `:number`, `:boolean`,
      `:atom` or `:any` (default `:any`)
    * `:max_bytes` — upper bound on a string argument's byte size
    * `:in` — allow-list of permitted values
    * `:path` — the name of a root from `config :anemos, :path_roots`; the
      argument is confined to it by `Anemos.Runtime.PathGuard`
    * `:optional` — the argument may be absent (only meaningful on a
      trailing run of specs)

  Plus one whole-schema form: a trailing spec carrying `rest: true` applies
  to every remaining argument, for genuinely variadic verbs.

      def arg_schema("read"),  do: [[type: :string, path: :spool]]
      def arg_schema("set"),   do: [[type: :string, max_bytes: 128], [type: :any]]
      def arg_schema("mode"),  do: [[type: :string, in: ["on", "off"]]]
      def arg_schema("log"),   do: [[type: :string, max_bytes: 4096, rest: true]]
      def arg_schema(_verb),   do: nil

  There is no nesting, no predicate function, no cross-argument
  dependency and no custom error text. That is deliberate: the vocabulary
  is exactly what an untrusted-input boundary needs — *is it the right
  shape, is it bounded, is it one of the values I allow, and if it names a
  file does it stay in its root* — and nothing beyond it. A schema
  expressive enough to encode business rules would be a second policy
  language inside the policy engine, and every key added to it is another
  key a reviewer has to reason about when auditing whether a verb is safe.
  Anything a host module needs past this vocabulary belongs in that host
  module's own body, where it can return a domain error.

  Arity is `length(schema)` less any trailing `optional: true` specs; a
  `rest: true` tail makes the upper bound unlimited.

  ## Validation is normalizing for paths only

  `validate/3` returns the argument list to pass onward. For every spec but
  `:path` that list is the input unchanged. A `:path` argument is replaced
  by its expanded, confined absolute path, because passing the original
  string on would let the host module re-resolve it and undo the check.

  ## Messages never quote the value

  A rejection names the position and the rule it broke, and describes the
  offending value only through `Anemos.Redact.summarize/1`. The value is
  attacker-controlled and the error text ends up in logs.
  """

  alias Anemos.Redact
  alias Anemos.Runtime.PathGuard

  @typedoc "One positional argument spec."
  @type spec :: keyword()

  @typedoc "A verb's argument schema, or `nil` for an unvalidated verb."
  @type t :: [spec()] | nil

  @doc """
  Checks `args` against `schema`, returning the arguments to pass onward.

  `nil` means the verb declared no schema and the arguments pass through
  unchanged — that is what keeps existing modules working.

  ## Examples

      iex> Anemos.Runtime.ArgSchema.validate(nil, ["anything", 5], "v")
      {:ok, ["anything", 5]}

      iex> Anemos.Runtime.ArgSchema.validate([[type: :string]], ["ok"], "v")
      {:ok, ["ok"]}

      iex> {:error, msg} = Anemos.Runtime.ArgSchema.validate([[type: :integer]], ["nope"], "v")
      iex> msg
      "verb 'v' argument 1: expected integer, got binary(4 bytes)"

  """
  @spec validate(t(), list(), String.t()) :: {:ok, list()} | {:error, String.t()}
  def validate(nil, args, _verb), do: {:ok, args}

  def validate(schema, args, verb) when is_list(schema) and is_list(args) do
    with :ok <- check_arity(schema, args, verb) do
      walk(schema, args, verb, 1, [])
    end
  end

  def validate(_schema, args, verb) when is_list(args) do
    {:error, "verb '#{verb}': malformed argument schema"}
  end

  # --- arity ---

  defp check_arity(schema, args, verb) do
    given = length(args)
    {min, max} = arity_bounds(schema)

    cond do
      given < min ->
        {:error, "verb '#{verb}': expected #{describe(min, max)}, got #{given}"}

      max != :infinity and given > max ->
        {:error, "verb '#{verb}': expected #{describe(min, max)}, got #{given}"}

      true ->
        :ok
    end
  end

  defp arity_bounds(schema) do
    required = Enum.count(schema, fn spec -> not optional?(spec) and not rest?(spec) end)
    max = if Enum.any?(schema, &rest?/1), do: :infinity, else: length(schema)
    {required, max}
  end

  defp describe(n, n), do: "#{n} argument(s)"
  defp describe(min, :infinity), do: "at least #{min} argument(s)"
  defp describe(min, max), do: "#{min}..#{max} argument(s)"

  defp optional?(spec), do: Keyword.get(spec, :optional, false) == true
  defp rest?(spec), do: Keyword.get(spec, :rest, false) == true

  # --- per-argument ---

  # A `rest: true` spec is the last one and applies to everything left.
  defp walk([spec], args, verb, position, acc) when args != [] do
    if rest?(spec) do
      Enum.reduce_while(args, {:ok, acc, position}, fn arg, {:ok, acc, pos} ->
        case check(spec, arg, verb, pos) do
          {:ok, value} -> {:cont, {:ok, [value | acc], pos + 1}}
          {:error, _} = err -> {:halt, err}
        end
      end)
      |> case do
        {:ok, acc, _pos} -> {:ok, Enum.reverse(acc)}
        {:error, _} = err -> err
      end
    else
      [arg | rest] = args
      one(spec, arg, rest, [], verb, position, acc)
    end
  end

  defp walk([spec | specs], [arg | args], verb, position, acc) do
    one(spec, arg, args, specs, verb, position, acc)
  end

  # Fewer args than specs — check_arity/3 already accepted this, so the
  # remaining specs are optional and there is nothing left to check.
  defp walk(_specs, [], _verb, _position, acc), do: {:ok, Enum.reverse(acc)}

  # More args than specs cannot happen: check_arity/3 rejects it unless a
  # `rest: true` spec is present, and that clause is handled above.
  defp walk([], args, _verb, _position, acc), do: {:ok, Enum.reverse(acc) ++ args}

  defp one(spec, arg, args, specs, verb, position, acc) do
    case check(spec, arg, verb, position) do
      {:ok, value} -> walk(specs, args, verb, position + 1, [value | acc])
      {:error, _} = err -> err
    end
  end

  defp check(spec, arg, verb, position) do
    with :ok <- check_type(Keyword.get(spec, :type, :any), arg, verb, position),
         :ok <- check_max_bytes(Keyword.get(spec, :max_bytes), arg, verb, position),
         :ok <- check_in(Keyword.get(spec, :in), arg, verb, position) do
      check_path(Keyword.get(spec, :path), arg, verb, position)
    end
  end

  defp check_type(:any, _arg, _verb, _position), do: :ok
  defp check_type(:string, arg, _v, _p) when is_binary(arg), do: :ok
  defp check_type(:integer, arg, _v, _p) when is_integer(arg), do: :ok
  defp check_type(:float, arg, _v, _p) when is_float(arg), do: :ok
  defp check_type(:number, arg, _v, _p) when is_number(arg), do: :ok
  defp check_type(:boolean, arg, _v, _p) when is_boolean(arg), do: :ok
  # is_atom/1 admits booleans and nil; :boolean is the narrower spec and is
  # checked above, so an :atom spec deliberately accepts them too.
  defp check_type(:atom, arg, _v, _p) when is_atom(arg), do: :ok

  defp check_type(type, arg, verb, position) do
    {:error,
     "verb '#{verb}' argument #{position}: expected #{type}, got #{Redact.summarize(arg)}"}
  end

  defp check_max_bytes(nil, _arg, _verb, _position), do: :ok

  defp check_max_bytes(max, arg, verb, position) when is_binary(arg) do
    if byte_size(arg) <= max do
      :ok
    else
      {:error,
       "verb '#{verb}' argument #{position}: exceeds #{max} bytes " <>
         "(#{Redact.summarize(arg)})"}
    end
  end

  # A :max_bytes spec on a non-binary is a bound that cannot be applied.
  # Refuse rather than pass: the schema author asked for a size limit.
  defp check_max_bytes(_max, arg, verb, position) do
    {:error,
     "verb '#{verb}' argument #{position}: :max_bytes requires a string, got " <>
       Redact.summarize(arg)}
  end

  defp check_in(nil, _arg, _verb, _position), do: :ok

  defp check_in(allowed, arg, verb, position) do
    if arg in allowed do
      :ok
    else
      {:error,
       "verb '#{verb}' argument #{position}: not in the allowed set of " <>
         "#{length(allowed)} value(s) (got #{Redact.summarize(arg)})"}
    end
  end

  defp check_path(nil, arg, _verb, _position), do: {:ok, arg}

  defp check_path(root_name, arg, verb, position) do
    case PathGuard.confine_root(arg, root_name) do
      {:ok, confined} ->
        {:ok, confined}

      {:error, {:unknown_root, name}} ->
        {:error,
         "verb '#{verb}' argument #{position}: path root #{inspect(name)} is not configured"}

      {:error, reason} ->
        {:error,
         "verb '#{verb}' argument #{position}: path escapes root #{inspect(root_name)} " <>
           "(#{reason})"}
    end
  end
end
