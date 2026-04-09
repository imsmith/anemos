defmodule Anemos.CompiledRule do
  @moduledoc """
  A compiled rule: name, event subscriptions, and a handler closure.

  The handler takes `(event_name, context, persistent_bindings)` and returns
  `{:ok, [operation], updated_persistent_bindings}`. Persistent bindings hold
  `set` values that survive across firings.
  """
  @enforce_keys [:name, :subscriptions, :handler]
  defstruct [:name, :subscriptions, :handler, :meta]

  @type t :: %__MODULE__{
          name: String.t(),
          subscriptions: [String.t()],
          handler: (String.t(), map(), map() -> {:ok, [map()], map()}),
          meta: map() | nil
        }
end

defmodule Anemos.CompilationResult do
  @moduledoc """
  Result of compiling an Anemos program.

  All fields default to empty lists — no fields are required at construction.
  """
  @enforce_keys []
  defstruct rules: [], conditions: [], capabilities: [], schedules: []

  @type t :: %__MODULE__{
          rules: [Anemos.CompiledRule.t()],
          conditions: [Anemos.CompiledCondition.t()],
          capabilities: [Anemos.CompiledCapability.t()],
          schedules: [Anemos.CompiledSchedule.t()]
        }
end

defmodule Anemos.Compiler do
  @moduledoc """
  Walks the AST produced by `Anemos.Parser` and produces `%Anemos.CompiledRule{}`,
  `%Anemos.CompiledCondition{}`, and `%Anemos.CompiledCapability{}` structs with
  executable closures. No code generation, no Module.create.
  """

  alias Anemos.AST
  alias Anemos.CompiledRule

  @doc """
  Compile an AST into an `%Anemos.CompilationResult{}` containing compiled rules,
  conditions, and capabilities.

  Each rule with `when` blocks produces one `CompiledRule` per event subscription.
  The handler closure takes `(event_name, context, persistent_bindings)` and
  returns `{:ok, [operation], updated_persistent_bindings}`.
  Persistent bindings hold `set` values that survive across firings.

  ## Examples

      iex> {:ok, ast} = Anemos.Parser.parse("rule r { when EV { log \\"hi\\" } }")
      iex> {:ok, %{rules: [compiled]}} = Anemos.Compiler.compile(ast)
      iex> compiled.name
      "r"
      iex> compiled.subscriptions
      ["EV"]
      iex> {:ok, [%{type: :log, value: "hi"}], %{}} = compiled.handler.("EV", %{}, %{})
  """
  # TODO: Add {:error, String.t()} return when the compiler needs to reject invalid AST.
  # For v0.1.0, the catch-all clauses silently drop unknown nodes.
  @spec compile(AST.Program.t()) :: {:ok, Anemos.CompilationResult.t()}
  def compile(%AST.Program{declarations: declarations}) do
    result =
      Enum.reduce(declarations, %Anemos.CompilationResult{}, fn decl, acc ->
        case compile_declaration(decl) do
          {:rule, rules} -> %{acc | rules: acc.rules ++ rules}
          {:condition, cond} -> %{acc | conditions: acc.conditions ++ [cond]}
          {:capability, cap} -> %{acc | capabilities: acc.capabilities ++ [cap]}
          :skip -> acc
        end
      end)

    {:ok, result}
  end

  # --- Declaration dispatch ---

  defp compile_declaration(%AST.Rule{} = rule), do: {:rule, compile_rule(rule)}

  defp compile_declaration(%AST.Condition{} = cond_decl) do
    {:condition, compile_condition(cond_decl)}
  end

  defp compile_declaration(%AST.Capability{} = cap) do
    {:capability, compile_capability(cap)}
  end

  defp compile_declaration(_other), do: :skip

  # --- Condition compilation ---

  defp compile_condition(%AST.Condition{name: name, body: body}) do
    when_blocks = extract_when_blocks(body)

    subscriptions =
      Enum.flat_map(when_blocks, fn %AST.When{event: event} ->
        event_to_subscriptions(event)
      end)

    side_effect_body = Enum.flat_map(when_blocks, fn %AST.When{body: when_body} -> when_body end)

    side_effect_handler =
      if side_effect_body == [] do
        nil
      else
        fn ->
          {ops, _bindings} = eval_body(side_effect_body, %{}, %{})
          {:ok, ops}
        end
      end

    evaluator = fn _event_name, _context -> true end

    %Anemos.CompiledCondition{
      name: name,
      subscriptions: subscriptions,
      evaluator: evaluator,
      side_effects: side_effect_body,
      side_effect_handler: side_effect_handler
    }
  end

  # --- Capability compilation ---

  defp compile_capability(%AST.Capability{name: name, context: context, body: body}) do
    handler = fn _context ->
      {ops, _bindings} = eval_body(body, %{}, %{})
      {:ok, ops}
    end

    %Anemos.CompiledCapability{
      name: name,
      context: context,
      handler: handler
    }
  end

  # --- Rule compilation ---

  defp compile_rule(%AST.Rule{name: name, body: body}) do
    context_path = extract_context_path(body)
    # Collect all when blocks (possibly nested inside context blocks)
    when_blocks = extract_when_blocks(body)

    Enum.map(when_blocks, fn %AST.When{event: event, body: when_body} ->
      subscriptions = event_to_subscriptions(event)
      handler = build_handler(when_body)

      %CompiledRule{
        name: name,
        subscriptions: subscriptions,
        handler: handler,
        meta: %{context_path: context_path}
      }
    end)
  end

  defp extract_context_path(body) do
    Enum.find_value(body, nil, fn
      %AST.Context{path: path} -> path
      _ -> nil
    end)
  end

  # --- Extract when blocks from rule body (traversing context blocks) ---

  defp extract_when_blocks(body) do
    Enum.flat_map(body, fn
      %AST.When{} = w -> [w]
      %AST.Context{body: ctx_body} -> extract_when_blocks(ctx_body)
      _other -> []
    end)
  end

  # --- Event to subscriptions ---

  defp event_to_subscriptions({:compound, _op, events}), do: events
  defp event_to_subscriptions(event) when is_binary(event), do: [event]

  # --- Handler builder ---

  defp build_handler(body) do
    fn _event_name, context, persistent_bindings ->
      {ops, final_bindings} = eval_body(body, context, persistent_bindings)

      # Extract set bindings to persist across firings
      updated_persistent =
        final_bindings
        |> Enum.filter(fn {{:set, _}, _} -> true; _ -> false end)
        |> Map.new()

      {:ok, ops, updated_persistent}
    end
  end

  # --- Body evaluation ---

  defp eval_body(statements, context, bindings) do
    {ops_rev, final_bindings} =
      Enum.reduce(statements, {[], bindings}, fn stmt, {ops_acc, bindings_acc} ->
        {new_ops, new_bindings} = eval_statement(stmt, context, bindings_acc)
        {Enum.reverse(new_ops) ++ ops_acc, new_bindings}
      end)

    {Enum.reverse(ops_rev), final_bindings}
  end

  # --- Statement evaluation ---

  defp eval_statement(%AST.Command{module: mod, verb: verb, args: args}, context, bindings) do
    resolved_args = Enum.map(args, &resolve_expr(&1, context, bindings))
    op = %{type: :command, module: mod, verb: verb, args: resolved_args}
    {[op], bindings}
  end

  defp eval_statement(%AST.Log{expression: expr}, context, bindings) do
    value = resolve_expr(expr, context, bindings)
    {[%{type: :log, value: value}], bindings}
  end

  defp eval_statement(%AST.Let{name: name, value: value}, context, bindings) do
    resolved = resolve_expr(value, context, bindings)

    {ops, new_bindings} =
      case resolved do
        %{type: :command} = cmd_op ->
          {[cmd_op], Map.put(bindings, {:let, name}, cmd_op)}

        other ->
          {[], Map.put(bindings, {:let, name}, other)}
      end

    {ops, new_bindings}
  end

  defp eval_statement(%AST.Set{name: name, value: value}, context, bindings) do
    resolved = resolve_expr(value, context, bindings)
    {[], Map.put(bindings, {:set, name}, resolved)}
  end

  defp eval_statement(
         %AST.If{condition: condition, body: body, else_body: else_body},
         context,
         bindings
       ) do
    if eval_condition(condition, context, bindings) do
      eval_body(body, context, bindings)
    else
      if else_body do
        eval_body(else_body, context, bindings)
      else
        {[], bindings}
      end
    end
  end

  defp eval_statement(
         %AST.Emit{type: emit_type, value: value, destination: dest, label: label},
         context,
         bindings
       ) do
    resolved_value = resolve_expr(value, context, bindings)
    op = %{type: :emit, value: resolved_value}
    op = if emit_type, do: Map.put(op, :emit_type, emit_type), else: op
    op = if dest, do: Map.put(op, :destination, dest), else: op
    op = if label, do: Map.put(op, :label, label), else: op
    {[op], bindings}
  end

  defp eval_statement(%AST.Demand{capability: cap, flag: flag}, _context, bindings) do
    {[%{type: :demand, capability: cap, flag: flag || :requisite}], bindings}
  end

  defp eval_statement(%AST.Context{body: body}, context, bindings) do
    eval_body(body, context, bindings)
  end

  defp eval_statement(_other, _context, bindings) do
    {[], bindings}
  end

  # --- Expression resolution ---

  defp resolve_expr(%AST.Literal{value: value}, _context, _bindings), do: value

  # ? — resolve from context data (external, from the event context map)
  defp resolve_expr(%AST.VarRef{sigil: "?", name: name}, context, _bindings) do
    get_in(context, [:context_data, name])
  end

  # @ — resolve from let bindings (immutable/ephemeral)
  defp resolve_expr(%AST.VarRef{sigil: "@", name: name}, _context, bindings) do
    Map.get(bindings, {:let, name})
  end

  # $ — resolve from set bindings (mutable/persistent)
  defp resolve_expr(%AST.VarRef{sigil: "$", name: name}, _context, bindings) do
    Map.get(bindings, {:set, name})
  end

  defp resolve_expr(%AST.Command{module: mod, verb: verb, args: args}, context, bindings) do
    resolved_args = Enum.map(args, &resolve_expr(&1, context, bindings))
    %{type: :command, module: mod, verb: verb, args: resolved_args}
  end

  defp resolve_expr(%AST.BinaryOp{} = op, context, bindings) do
    eval_condition(op, context, bindings)
  end

  defp resolve_expr(%AST.UnaryOp{op: op, operand: operand}, context, bindings) do
    val = resolve_expr(operand, context, bindings)

    case op do
      :not -> !val
      :! -> !val
    end
  end

  defp resolve_expr(%AST.ListLiteral{elements: elements}, context, bindings) do
    Enum.map(elements, &resolve_expr(&1, context, bindings))
  end

  defp resolve_expr(other, _context, _bindings), do: other

  # --- Condition evaluation ---

  defp eval_condition(%AST.BinaryOp{op: op, left: left, right: right}, context, bindings) do
    l = resolve_expr(left, context, bindings)
    r = resolve_expr(right, context, bindings)

    case op do
      op when op in [:eq, :==] -> l == r
      op when op in [:ne, :!=] -> l != r
      op when op in [:gt, :>] -> l > r
      op when op in [:lt, :<] -> l < r
      op when op in [:ge, :>=] -> l >= r
      op when op in [:le, :<=] -> l <= r
      op when op in [:and, :&&] -> l && r
      op when op in [:or, :||] -> l || r
      :in -> l in List.wrap(r)
      :contains -> String.contains?(to_string(l), to_string(r))
      :starts_with -> String.starts_with?(to_string(l), to_string(r))
      :ends_with -> String.ends_with?(to_string(l), to_string(r))
      _ -> false
    end
  end

  defp eval_condition(%AST.UnaryOp{op: op, operand: operand}, context, bindings) do
    val = resolve_expr(operand, context, bindings)

    case op do
      :not -> !val
      :! -> !val
    end
  end

  defp eval_condition(expr, context, bindings) do
    resolve_expr(expr, context, bindings)
  end
end
