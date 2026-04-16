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

defmodule Anemos.CompiledData do
  @moduledoc "A compiled data block."
  @enforce_keys [:name]
  defstruct [:name, :scope, :dataset, :format, :raw, :source, :transclude, :dynamic]

  @type t :: %__MODULE__{
          name: String.t(),
          scope: :local | :global | nil,
          dataset: MapSet.t() | nil,
          format: String.t() | nil,
          raw: String.t() | nil,
          source: String.t() | nil,
          transclude: tuple() | nil,
          dynamic: tuple() | nil
        }
end

defmodule Anemos.CompiledQuery do
  @moduledoc "A compiled query block."
  @enforce_keys [:name]
  defstruct [:name, :scope, :expect, :engine, :body, :return, :handler]

  @type t :: %__MODULE__{
          name: String.t(),
          scope: :local | :global | nil,
          expect: [atom()] | nil,
          engine: String.t() | nil,
          body: String.t() | nil,
          return: String.t() | nil,
          handler: fun() | nil
        }
end

defmodule Anemos.CompilationResult do
  @moduledoc """
  Result of compiling an Anemos program.

  All fields default to empty lists — no fields are required at construction.
  """
  @enforce_keys []
  defstruct rules: [], conditions: [], capabilities: [], schedules: [], data_blocks: [], query_blocks: []

  @type t :: %__MODULE__{
          rules: [Anemos.CompiledRule.t()],
          conditions: [Anemos.CompiledCondition.t()],
          capabilities: [Anemos.CompiledCapability.t()],
          schedules: [Anemos.CompiledSchedule.t()],
          data_blocks: [Anemos.CompiledData.t()],
          query_blocks: [Anemos.CompiledQuery.t()]
        }
end

defmodule Anemos.Compiler do
  @moduledoc """
  Walks the AST produced by `Anemos.Parser` and produces `%Anemos.CompiledRule{}`,
  `%Anemos.CompiledCondition{}`, and `%Anemos.CompiledCapability{}` structs with
  executable closures. No code generation, no Module.create.
  """

  require Logger

  alias Anemos.AST
  alias Anemos.CompiledRule

  @doc """
  Compile an AST into an `%Anemos.CompilationResult{}` containing compiled rules,
  conditions, and capabilities.

  Each rule with `when` blocks produces one `CompiledRule` per event subscription.
  The handler closure takes `(event_name, context, persistent_bindings)` and
  returns `{:ok, [operation], updated_persistent_bindings}`.
  Persistent bindings hold `set` values that survive across firings.

  Supported statement types: `let`, `set`, `log`, `emit`, `demand`, `if`,
  `while`, `for`/`each`/`every`/`foreach`, `return`, `done`, `nextevent`,
  `nextrule`, `context`, commands (`[MODULE::verb ...]`), and triple patterns.
  Guard modifiers (`unless`, `until`) on `when`, `if`, and `at` blocks.

  ## Examples

      iex> {:ok, ast} = Anemos.Parser.parse("rule r { when EV { log \\"hi\\" } }")
      iex> {:ok, %{rules: [compiled]}} = Anemos.Compiler.compile(ast)
      iex> compiled.name
      "r"
      iex> compiled.subscriptions
      ["EV"]
      iex> {:ok, [%{type: :log, value: "hi"}], %{}} = compiled.handler.("EV", %{}, %{})

      iex> {:ok, ast} = Anemos.Parser.parse("rule r { when EV { set i = 0 while $i < 3 { set i = $i + 1 } log $i } }")
      iex> {:ok, %{rules: [compiled]}} = Anemos.Compiler.compile(ast)
      iex> {:ok, [%{type: :log, value: 3}], _} = compiled.handler.("EV", %{}, %{})
  """
  # TODO: Add {:error, String.t()} return when the compiler needs to reject invalid AST.
  # For v0.1.0, the catch-all clauses silently drop unknown nodes.
  @spec compile(AST.Program.t()) :: {:ok, Anemos.CompilationResult.t()}
  def compile(%AST.Program{declarations: declarations}) do
    result =
      Enum.reduce(declarations, %Anemos.CompilationResult{}, fn decl, acc ->
        case compile_declaration(decl) do
          {:rule, rules, schedules} ->
            %{acc | rules: acc.rules ++ rules, schedules: acc.schedules ++ schedules}
          {:condition, cond, schedules} ->
            %{acc | conditions: acc.conditions ++ [cond], schedules: acc.schedules ++ schedules}
          {:capability, cap} -> %{acc | capabilities: acc.capabilities ++ [cap]}
          {:data, compiled_data} -> %{acc | data_blocks: acc.data_blocks ++ [compiled_data]}
          {:query, compiled_query} -> %{acc | query_blocks: acc.query_blocks ++ [compiled_query]}
          :skip -> acc
        end
      end)

    {:ok, result}
  end

  # --- Declaration dispatch ---

  defp compile_declaration(%AST.Rule{} = rule) do
    {rules, schedules} = compile_rule(rule)
    {:rule, rules, schedules}
  end

  defp compile_declaration(%AST.Condition{} = cond_decl) do
    {condition, schedules} = compile_condition(cond_decl)
    {:condition, condition, schedules}
  end

  defp compile_declaration(%AST.Capability{} = cap) do
    {:capability, compile_capability(cap)}
  end

  defp compile_declaration(%AST.DataDecl{} = data) do
    {:data, compile_data(data)}
  end

  defp compile_declaration(%AST.QueryDecl{} = query) do
    {:query, compile_query(query)}
  end

  defp compile_declaration(_other), do: :skip

  # --- Condition compilation ---

  defp compile_condition(%AST.Condition{name: name, body: body}) do
    when_blocks = extract_when_blocks(body)
    at_blocks = extract_at_blocks(body)

    subscriptions =
      Enum.flat_map(when_blocks, fn %AST.When{event: event} ->
        event_to_subscriptions(event)
      end)

    {at_schedules, at_subscriptions} =
      if at_blocks == [] do
        {[], []}
      else
        {scheds, _rules} = at_blocks |> Enum.map(&compile_at_block(&1, %{})) |> Enum.unzip()
        {scheds, Enum.map(scheds, & &1.event_name)}
      end

    all_bodies =
      Enum.flat_map(when_blocks, fn %AST.When{body: b} -> b end) ++
        Enum.flat_map(at_blocks, fn %AST.At{body: b} -> b end)

    side_effect_handler =
      if all_bodies == [] do
        nil
      else
        fn ->
          {ops, _bindings} = eval_body(all_bodies, %{}, %{})
          {:ok, ops}
        end
      end

    evaluator = fn _event_name, _context -> true end

    condition = %Anemos.CompiledCondition{
      name: name,
      subscriptions: subscriptions ++ at_subscriptions,
      evaluator: evaluator,
      side_effects: all_bodies,
      side_effect_handler: side_effect_handler
    }

    {condition, at_schedules}
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

  # --- Data compilation ---

  defp compile_data(%AST.DataDecl{name: name, source: source, content: content, transclude: transclude, scope: scope}) do
    case content do
      {:simple_list, values} ->
        %Anemos.CompiledData{
          name: name,
          scope: scope,
          dataset: MapSet.new(values),
          source: source,
          transclude: transclude
        }

      {:format_block, keyword, raw} ->
        %Anemos.CompiledData{
          name: name,
          scope: scope,
          format: keyword,
          raw: raw,
          source: source,
          transclude: transclude
        }

      {:dynamic, subscribe, periodic} ->
        %Anemos.CompiledData{
          name: name,
          scope: scope,
          dynamic: {subscribe, periodic},
          source: source,
          transclude: transclude
        }
    end
  end

  # --- Query compilation ---

  defp compile_query(%AST.QueryDecl{name: name, expect: expect, engine: engine, body: body, return: ret, scope: scope}) do
    handler = fn bindings, context ->
      {:ok, %{engine: engine, body: body, bindings: bindings, context: context}}
    end

    %Anemos.CompiledQuery{
      name: name,
      scope: scope,
      expect: expect,
      engine: engine,
      body: body,
      return: ret,
      handler: handler
    }
  end

  # --- Rule compilation ---

  defp compile_rule(%AST.Rule{name: name, body: body, meta: rule_meta}) do
    Enum.each(body, fn
      %AST.DataDecl{} = data ->
        compiled = compile_data(data)

        if compiled.dynamic && compiled.scope == :local do
          Logger.warning(
            "data block '#{compiled.name}' is dynamic and inline-scoped — " <>
              "subscription lifecycle is tied to rule process (will reconnect on rule restart)"
          )
        end

      _ ->
        :ok
    end)

    context_path = extract_context_path(body)
    when_blocks = extract_when_blocks(body)
    at_blocks = extract_at_blocks(body)

    compiled_meta = Map.merge(rule_meta || %{}, %{context_path: context_path})

    when_rules =
      Enum.map(when_blocks, fn %AST.When{event: event, body: when_body, guard: guard} ->
        subscriptions = event_to_subscriptions(event)
        handler = build_guarded_handler(when_body, guard)
        %CompiledRule{name: name, subscriptions: subscriptions, handler: handler, meta: compiled_meta}
      end)

    {at_schedules, at_rules} =
      if at_blocks == [] do
        {[], []}
      else
        at_blocks
        |> Enum.map(&compile_at_block(&1, compiled_meta))
        |> Enum.unzip()
      end

    {when_rules ++ at_rules, at_schedules}
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

  # --- Extract at blocks from rule/condition body ---

  defp extract_at_blocks(body) do
    Enum.flat_map(body, fn
      %AST.At{} = a -> [a]
      %AST.Context{body: ctx_body} -> extract_at_blocks(ctx_body)
      _other -> []
    end)
  end

  # --- Compile a single at block into {schedule, rule} ---

  defp compile_at_block(%AST.At{time_spec: time_spec, body: body, guard: guard}, compiled_meta) do
    {event_name, parsed_spec, recurrence} = at_spec_to_event(time_spec)
    handler = build_guarded_handler(body, guard)
    context_path = Map.get(compiled_meta, :context_path)

    schedule = %Anemos.CompiledSchedule{
      event_name: event_name,
      time_spec: parsed_spec,
      recurrence: recurrence,
      context: context_path
    }

    rule = %Anemos.CompiledRule{
      name: "at_#{event_name}",
      subscriptions: [event_name],
      handler: handler,
      meta: compiled_meta
    }

    {schedule, rule}
  end

  # --- at time_spec → {event_name, parsed_spec, recurrence} ---

  defp at_spec_to_event({:time, {h, m}}) do
    name = "AT_#{String.pad_leading("#{h}", 2, "0")}_#{String.pad_leading("#{m}", 2, "0")}"
    {name, {:time, {h, m}}, nil}
  end

  defp at_spec_to_event({:interval, {amount, unit} = dur}) do
    {"AT_INTERVAL_#{amount}#{unit}", {:interval, dur}, :interval}
  end

  defp at_spec_to_event({:recurring, {:time, {h, m}}, recurrence}) do
    name = "AT_#{String.pad_leading("#{h}", 2, "0")}_#{String.pad_leading("#{m}", 2, "0")}"
    {name, {:time, {h, m}}, recurrence}
  end

  defp at_spec_to_event({:date, {y, m, d} = date}) do
    name = "AT_DATE_#{y}_#{String.pad_leading("#{m}", 2, "0")}_#{String.pad_leading("#{d}", 2, "0")}"
    {name, {:date, date}, nil}
  end

  defp at_spec_to_event({:day, day}) do
    {"AT_DAY_#{day}", {:day, day}, nil}
  end

  defp at_spec_to_event({:nld, text}) do
    safe_name = text |> String.replace(".", "_")
    {"AT_NLD_#{safe_name}", {:nld, text}, nil}
  end

  # --- Event to subscriptions ---

  defp event_to_subscriptions({:compound, _op, events}), do: events
  defp event_to_subscriptions(event) when is_binary(event), do: [event]

  # --- Handler builder ---

  defp build_guarded_handler(body, nil), do: build_handler(body)

  defp build_guarded_handler(body, {:unless, guard_expr}) do
    inner = build_handler(body)

    fn event_name, context, persistent_bindings ->
      if eval_condition(guard_expr, context, persistent_bindings) do
        {:ok, [], persistent_bindings}
      else
        inner.(event_name, context, persistent_bindings)
      end
    end
  end

  defp build_guarded_handler(body, {:until, guard_expr}) do
    inner = build_handler(body)

    fn event_name, context, persistent_bindings ->
      if Map.get(persistent_bindings, {:until_tripped}, false) do
        {:ok, [], persistent_bindings}
      else
        if eval_condition(guard_expr, context, persistent_bindings) do
          {:ok, [], Map.put(persistent_bindings, {:until_tripped}, true)}
        else
          inner.(event_name, context, persistent_bindings)
        end
      end
    end
  end

  defp build_handler(body) do
    fn _event_name, context, persistent_bindings ->
      {ops, final_bindings} =
        try do
          eval_body(body, context, persistent_bindings)
        catch
          {:anemos_return, ops, bindings} -> {ops, bindings}
          {:anemos_done, ops, bindings} -> {ops, bindings}
          {:anemos_nextevent, target, ops, bindings} ->
            {ops ++ [%{type: :nextevent, target: target}], bindings}
          {:anemos_nextrule, target, args, ops, bindings} ->
            {ops ++ [%{type: :nextrule, target: target, args: args}], bindings}
        end

      # Extract set bindings to persist across firings
      updated_persistent =
        final_bindings
        |> Enum.filter(fn {{:set, _}, _} -> true; _ -> false end)
        |> Map.new()

      {:ok, ops, updated_persistent}
    end
  end

  # --- Body evaluation ---

  # Process dictionary (:anemos_accumulated_ops) is used intentionally here.
  # When return/done throws to abort Enum.reduce, the in-flight accumulator
  # is lost. The process dictionary lets the throw clause capture ops built
  # so far. The key is saved/restored around each eval_body call so nested
  # bodies (if/while) compose correctly.
  defp eval_body(statements, context, bindings) do
    # Process dict: save previous ops for nested eval_body restore
    prev_ops = Process.get(:anemos_accumulated_ops, [])

    {ops_rev, final_bindings} =
      Enum.reduce(statements, {[], bindings}, fn stmt, {ops_acc, bindings_acc} ->
        # Process dict: snapshot current ops so throw can capture them
        Process.put(:anemos_accumulated_ops, prev_ops ++ Enum.reverse(ops_acc))
        {new_ops, new_bindings} = eval_statement(stmt, context, bindings_acc)
        {Enum.reverse(new_ops) ++ ops_acc, new_bindings}
      end)

    # Process dict: restore previous ops after body completes normally
    Process.put(:anemos_accumulated_ops, prev_ops)
    {Enum.reverse(ops_rev), final_bindings}
  end

  # --- Guard checking (for if blocks) ---

  defp check_guard(nil, _context, _bindings), do: nil

  defp check_guard({:unless, expr}, context, bindings) do
    if eval_condition(expr, context, bindings), do: {[], bindings}, else: nil
  end

  # until on an if block has no meaningful semantics (if blocks don't persist) — ignore
  defp check_guard({:until, _expr}, _context, _bindings), do: nil

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

  # let [triple assertion] — assert a fact
  defp eval_statement(%AST.Let{name: nil, value: %AST.Triple{} = triple}, context, bindings) do
    s = resolve_triple_element(triple.subject, context, bindings)
    p = resolve_triple_element(triple.predicate, context, bindings)
    o = resolve_triple_element(triple.object, context, bindings)
    {[%{type: :assert_triple, subject: s, predicate: p, object: o}], bindings}
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
         %AST.If{condition: condition, guard: guard, body: body, else_body: else_body},
         context,
         bindings
       ) do
    case check_guard(guard, context, bindings) do
      {[], ^bindings} = guarded ->
        guarded

      nil ->
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

  @while_limit 10_000

  defp eval_statement(%AST.While{condition: condition, body: body}, context, bindings) do
    eval_while(condition, body, context, bindings, [], 0)
  end

  # Process dict: snapshot ops before each for-loop iteration so throw/catch
  # early exit (return/done) captures results from prior iterations.
  defp eval_statement(%AST.For{var: var, iterable: iterable, body: body}, context, bindings) do
    collection = resolve_iterable(iterable, context, bindings)
    # Process dict: save outer accumulated ops for restore after iteration
    outer_ops = Process.get(:anemos_accumulated_ops, [])

    Enum.reduce(collection, {[], bindings}, fn item, {ops_acc, bindings_acc} ->
      # Process dict: include prior iteration ops so throw captures them
      Process.put(:anemos_accumulated_ops, outer_ops ++ ops_acc)
      iter_bindings = Map.put(bindings_acc, {:let, var}, item)
      {new_ops, new_bindings} = eval_body(body, context, iter_bindings)
      # Process dict: restore to pre-iteration state
      Process.put(:anemos_accumulated_ops, outer_ops)
      cleaned = Map.delete(new_bindings, {:let, var})
      {ops_acc ++ new_ops, cleaned}
    end)
  end

  # Flow control throws: each captures the accumulated ops snapshot from the
  # process dict so build_handler's catch clause can return them. See the
  # comment on eval_body for why the process dict is used here.
  defp eval_statement(%AST.Return{}, _context, bindings) do
    # Process dict: snapshot ops accumulated so far for early exit
    ops = Process.get(:anemos_accumulated_ops, [])
    throw({:anemos_return, ops, bindings})
  end

  defp eval_statement(%AST.Done{}, _context, bindings) do
    # Process dict: snapshot ops accumulated so far for early exit
    ops = Process.get(:anemos_accumulated_ops, [])
    throw({:anemos_done, ops, bindings})
  end

  defp eval_statement(%AST.NextEvent{target: target}, _context, bindings) do
    # Process dict: snapshot ops accumulated so far for early exit
    ops = Process.get(:anemos_accumulated_ops, [])
    throw({:anemos_nextevent, target, ops, bindings})
  end

  defp eval_statement(%AST.NextRule{target: target, args: args}, context, bindings) do
    resolved_args = case args do
      %AST.BlockArgs{pairs: pairs} ->
        Map.new(pairs, fn {k, v} -> {k, resolve_expr(v, context, bindings)} end)
      _ -> nil
    end
    # Process dict: snapshot ops accumulated so far for early exit
    ops = Process.get(:anemos_accumulated_ops, [])
    throw({:anemos_nextrule, target, resolved_args, ops, bindings})
  end

  defp eval_statement(%AST.DataDecl{} = data, _context, bindings) do
    compiled = compile_data(data)
    op = %{type: :register_data, data: compiled}
    {[op], bindings}
  end

  defp eval_statement(%AST.QueryDecl{} = query, _context, bindings) do
    compiled = compile_query(query)
    op = %{type: :register_query, query: compiled}
    {[op], bindings}
  end

  defp eval_statement(_other, _context, bindings) do
    {[], bindings}
  end

  # --- While loop helpers ---

  defp eval_while(_condition, _body, _context, bindings, ops_acc, iteration)
       when iteration >= @while_limit do
    {ops_acc, bindings}
  end

  # Process dict: snapshot loop-accumulated ops before each iteration so
  # throw/catch early exit (return/done) captures results from prior iterations.
  defp eval_while(condition, body, context, bindings, ops_acc, iteration) do
    if eval_condition(condition, context, bindings) do
      # Process dict: save outer state, set loop ops for throw capture
      outer = Process.get(:anemos_accumulated_ops, [])
      Process.put(:anemos_accumulated_ops, outer ++ ops_acc)
      {new_ops, new_bindings} = eval_body(body, context, bindings)
      # Process dict: restore to pre-iteration state
      Process.put(:anemos_accumulated_ops, outer)
      eval_while(condition, body, context, new_bindings, ops_acc ++ new_ops, iteration + 1)
    else
      {ops_acc, bindings}
    end
  end

  # --- For loop helpers ---

  defp resolve_iterable(nil, _context, _bindings), do: []

  defp resolve_iterable(expr, context, bindings) do
    result = resolve_expr(expr, context, bindings)
    List.wrap(result)
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
      :"~" -> Bitwise.bnot(val)
    end
  end

  defp resolve_expr(%AST.ListLiteral{elements: elements}, context, bindings) do
    Enum.map(elements, &resolve_expr(&1, context, bindings))
  end

  # Triple pattern in expression context — return as a query descriptor
  defp resolve_expr(%AST.Triple{subject: s, predicate: p, object: o}, context, bindings) do
    %{
      type: :triple_query,
      subject: resolve_triple_element(s, context, bindings),
      predicate: resolve_triple_element(p, context, bindings),
      object: resolve_triple_element(o, context, bindings)
    }
  end

  defp resolve_expr(other, _context, _bindings), do: other

  defp resolve_triple_element(%AST.Literal{value: value}, _context, _bindings), do: value
  defp resolve_triple_element(%AST.VarRef{sigil: "?", name: name}, _context, _bindings), do: {:var, name}
  defp resolve_triple_element(%AST.VarRef{} = ref, context, bindings), do: resolve_expr(ref, context, bindings)
  defp resolve_triple_element(other, _context, _bindings), do: other

  # --- Condition evaluation ---

  defp eval_condition(%AST.BinaryOp{op: op, left: left, right: right}, context, bindings) do
    l = resolve_expr(left, context, bindings)
    r = resolve_expr(right, context, bindings)

    case op do
      # Comparison
      op when op in [:eq, :==] -> l == r
      op when op in [:ne, :!=] -> l != r
      :=== -> l === r
      :!== -> l !== r
      op when op in [:gt, :>] -> l > r
      op when op in [:lt, :<] -> l < r
      op when op in [:ge, :>=] -> l >= r
      op when op in [:le, :<=] -> l <= r
      # Logical
      op when op in [:and, :&&] -> l && r
      op when op in [:or, :||] -> l || r
      # Membership / string
      :in -> l in List.wrap(r)
      :notin -> l not in List.wrap(r)
      :contains -> String.contains?(to_string(l), to_string(r))
      :starts_with -> String.starts_with?(to_string(l), to_string(r))
      :ends_with -> String.ends_with?(to_string(l), to_string(r))
      :matches_regex -> String.match?(to_string(l), Regex.compile!(to_string(r)))
      # Arithmetic
      :+ -> l + r
      :- -> l - r
      :* -> l * r
      :/ -> l / r
      :% -> rem(l, r)
      # Bitwise
      :& -> Bitwise.band(l, r)
      :| -> Bitwise.bor(l, r)
      :^ -> Bitwise.bxor(l, r)
      :"<<" -> Bitwise.bsl(l, r)
      :">>" -> Bitwise.bsr(l, r)
      _ -> false
    end
  end

  defp eval_condition(%AST.UnaryOp{op: op, operand: operand}, context, bindings) do
    val = resolve_expr(operand, context, bindings)

    case op do
      :not -> !val
      :! -> !val
      :"~" -> Bitwise.bnot(val)
    end
  end

  defp eval_condition(expr, context, bindings) do
    resolve_expr(expr, context, bindings)
  end
end
