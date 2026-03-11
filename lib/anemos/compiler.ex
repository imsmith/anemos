defmodule Anemos.CompiledRule do
  @moduledoc """
  A compiled rule: name, event subscriptions, and a handler closure.

  The handler takes `(event_name, context)` and returns `{:ok, [operation]}`
  where each operation is a map describing what to do.
  """
  defstruct [:name, :subscriptions, :handler, :meta]
end

defmodule Anemos.Compiler do
  @moduledoc """
  Walks the AST produced by `Anemos.Parser` and produces `%Anemos.CompiledRule{}`
  structs with executable closures. No code generation, no Module.create.
  """

  alias Anemos.AST
  alias Anemos.CompiledRule

  # TODO: Add {:error, String.t()} return when the compiler needs to reject invalid AST.
  # For v0.1.0, the catch-all clauses silently drop unknown nodes.
  @spec compile(AST.Program.t()) :: {:ok, [CompiledRule.t()]}
  def compile(%AST.Program{declarations: declarations}) do
    compiled =
      declarations
      |> Enum.flat_map(&compile_declaration/1)

    {:ok, compiled}
  end

  # --- Declaration dispatch ---

  defp compile_declaration(%AST.Rule{} = rule) do
    compile_rule(rule)
  end

  # Skip non-rule declarations for now (conditions, capabilities).
  # They'll be referenced by rules but don't produce handlers directly.
  defp compile_declaration(_other), do: []

  # --- Rule compilation ---

  defp compile_rule(%AST.Rule{name: name, body: body}) do
    # Collect all when blocks (possibly nested inside context blocks)
    when_blocks = extract_when_blocks(body)

    Enum.map(when_blocks, fn %AST.When{event: event, body: when_body} ->
      subscriptions = event_to_subscriptions(event)
      handler = build_handler(when_body)

      %CompiledRule{
        name: name,
        subscriptions: subscriptions,
        handler: handler,
        meta: %{}
      }
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
    fn _event_name, _context ->
      # TODO: context will be used when runtime provides event payload / state lookups
      {ops, _bindings} = eval_body(body, %{}, %{})
      {:ok, ops}
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
          {[cmd_op], Map.put(bindings, name, cmd_op)}

        other ->
          {[], Map.put(bindings, name, other)}
      end

    {ops, new_bindings}
  end

  defp eval_statement(%AST.Set{name: name, value: value}, context, bindings) do
    resolved = resolve_expr(value, context, bindings)
    {[%{type: :set, name: name, value: resolved}], bindings}
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

  defp eval_statement(%AST.Demand{capability: cap}, _context, bindings) do
    {[%{type: :demand, capability: cap}], bindings}
  end

  defp eval_statement(%AST.Context{body: body}, context, bindings) do
    eval_body(body, context, bindings)
  end

  defp eval_statement(_other, _context, bindings) do
    {[], bindings}
  end

  # --- Expression resolution ---

  defp resolve_expr(%AST.Literal{value: value}, _context, _bindings), do: value

  # TODO: VarRef sigil ($/@/?) distinction is currently ignored — all resolve
  # the same way via bindings lookup. Differentiate when runtime semantics require it.
  defp resolve_expr(%AST.VarRef{name: name}, _context, bindings) do
    Map.get(bindings, name)
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
