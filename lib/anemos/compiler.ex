defmodule Anemos.CompiledRule do
  @moduledoc """
  A compiled rule: name, event subscriptions, handler closure, and optional dwell duration.

  The handler takes `(event_name, context, persistent_bindings)` and returns
  `{:ok, [operation], updated_persistent_bindings}`. Persistent bindings hold
  `set` values that survive across firings.

  When `dwell_duration_ms` is non-nil, the rule is dispatched through the
  Dispatcher's dwell-timer state machine instead of being fired immediately.
  See `Anemos.Runtime.Dispatcher` for the state-machine semantics.
  """
  @enforce_keys [:name, :subscriptions, :handler]
  defstruct [:name, :subscriptions, :handler, :meta, :dwell_duration_ms]

  @type t :: %__MODULE__{
          name: String.t(),
          subscriptions: [String.t()],
          handler: (String.t(), map(), map() -> {:ok, [map()], map()}),
          meta: map() | nil,
          dwell_duration_ms: pos_integer() | nil
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

  # `expect` names are binaries, not atoms, and must stay that way (A-08).
  # They are arbitrary query bindings the policy author invents, so there is no
  # closed set to validate against and interning them from source text is
  # unbounded. `String.to_existing_atom/1` would be worse than the leak: whether
  # `expect :customer_id` parsed would depend on whether some unrelated module
  # happened to intern `:customer_id` first, making the language nondeterministic.
  @type t :: %__MODULE__{
          name: String.t(),
          scope: :local | :global | nil,
          expect: [String.t()] | nil,
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

  ## Boolean comparison (A-46)

  `true` and `false` are boolean literals. `?flag == true` compares against the
  boolean `true`, not the string `"true"`.

  **Comparison does not coerce.** `?flag == "true"` still means *the string*
  `"true"` and keeps working for a host whose payload is string-valued; it does
  not match a payload carrying the boolean. The two are different values and
  `==` says so.

  Coercion was rejected because the operand types are not knowable at compile
  time. Context data arrives from arbitrary host payloads, so a rule making
  `"true" == true` answer `true` would also have to make `"1"`, `"yes"` and
  `"TRUE"` answer something, and the choice would be invisible to the policy
  author. Making the mismatch a *compile* error was rejected for the same
  reason: the parser sees a literal on one side and an unresolved `?var` on the
  other, and cannot know what the host will send.

  What is not acceptable is the silent wrong answer that A-46 reported. So a
  comparison in which one side is a boolean and the other is the string
  `"true"` or `"false"` logs a warning at the moment it is evaluated, naming
  both operands, and then answers as the values dictate — `==` false, `!=`
  true. The author gets told the shapes disagree rather than reading a guard
  that never fires.
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
  @spec compile(AST.Program.t()) :: {:ok, Anemos.CompilationResult.t()} | {:error, String.t()}
  def compile(%AST.Program{declarations: declarations}) do
    try do
      result =
        Enum.reduce(declarations, %Anemos.CompilationResult{}, fn decl, acc ->
          case compile_declaration(decl) do
            {:rule, rules, schedules, inline_data, inline_queries} ->
              %{acc |
                rules: acc.rules ++ rules,
                schedules: acc.schedules ++ schedules,
                data_blocks: acc.data_blocks ++ inline_data,
                query_blocks: acc.query_blocks ++ inline_queries
              }
            {:condition, cond, schedules} ->
              %{acc | conditions: acc.conditions ++ [cond], schedules: acc.schedules ++ schedules}
            {:capability, cap} -> %{acc | capabilities: acc.capabilities ++ [cap]}
            {:data, compiled_data} -> %{acc | data_blocks: acc.data_blocks ++ [compiled_data]}
            {:query, compiled_query} -> %{acc | query_blocks: acc.query_blocks ++ [compiled_query]}
            :skip -> acc
          end
        end)

      {:ok, result}
    catch
      {:compile_error, msg} -> {:error, msg}
    end
  end

  # --- Declaration dispatch ---

  defp compile_declaration(%AST.Rule{} = rule) do
    {rules, schedules, inline_data, inline_queries} = compile_rule(rule)
    {:rule, rules, schedules, inline_data, inline_queries}
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
    predicates = extract_condition_predicates(body)

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
        fn context ->
          {ops, _bindings} = eval_body(all_bodies, context, %{})
          {:ok, ops}
        end
      end

    evaluator = build_condition_evaluator(when_blocks, at_blocks, predicates)

    condition = %Anemos.CompiledCondition{
      name: name,
      subscriptions: subscriptions ++ at_subscriptions,
      evaluator: evaluator,
      side_effects: all_bodies,
      side_effect_handler: side_effect_handler,
      # A-54. A condition's body runs operations of its own, so it is a
      # demanding party like any rule and must present the context it declared.
      # Left unfilled, every condition presented `nil` and the fail-closed
      # boundary denied it — the right answer for the wrong reason, and no way
      # for a condition to legitimately reach a scoped capability.
      context: extract_context_path(body)
    }

    {condition, at_schedules}
  end

  # A condition's truth is decided by its trigger blocks, evaluated against the
  # event that reached it:
  #
  #   * `when` / `at` blocks say *which* events can make it true. The condition
  #     is true when the incoming event matches one of them and that block's
  #     guard is satisfied.
  #   * a top-level `if` block is a predicate over the event context that must
  #     also hold — this is how "only when X" is expressed.
  #
  # `if` blocks nested inside a trigger body are control flow for the side
  # effects, not part of the trigger, and are not consulted here.
  #
  # A condition with no trigger blocks can never become true.
  defp build_condition_evaluator([], [], _predicates), do: fn _event_name, _context -> false end

  defp build_condition_evaluator(when_blocks, at_blocks, predicates) do
    triggers =
      Enum.map(when_blocks, fn %AST.When{event: event, guard: guard} ->
        {event_to_subscriptions(event), guard}
      end) ++
        Enum.map(at_blocks, fn %AST.At{time_spec: time_spec, guard: guard} ->
          {event_name, _spec, _recurrence} = at_spec_to_event(time_spec)
          {[event_name], guard}
        end)

    fn event_name, context ->
      triggered? =
        Enum.any?(triggers, fn {events, guard} ->
          event_name in events and trigger_guard_satisfied?(guard, context)
        end)

      triggered? and
        Enum.all?(predicates, fn expr -> truthy?(eval_condition(expr, context, %{})) end)
    end
  end

  defp trigger_guard_satisfied?(nil, _context), do: true

  defp trigger_guard_satisfied?({:unless, expr}, context),
    do: not truthy?(eval_condition(expr, context, %{}))

  # `until` on a condition trigger is evaluated without memory: the condition is
  # false while the guard holds, and becomes eligible again if it stops holding.
  # A rule's `until` latches permanently; a condition has nowhere to latch,
  # since its evaluator is a pure function of (event, context).
  defp trigger_guard_satisfied?({:until, expr}, context),
    do: not truthy?(eval_condition(expr, context, %{}))

  defp truthy?(value), do: !!value

  # Top-level `if` blocks in a condition body — predicates on the condition,
  # distinct from `if` used as control flow inside a trigger body.
  defp extract_condition_predicates(body) do
    Enum.flat_map(body, fn
      %AST.If{condition: condition} -> [condition]
      %AST.Context{body: ctx_body} -> extract_condition_predicates(ctx_body)
      _other -> []
    end)
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

    # Extract inline data/query declarations from the rule body and compile
    # them at load time (not as runtime ops) so they're in the DataStore
    # before any rule handler fires.
    inline_data = extract_inline_data(body, name)
    inline_queries = extract_inline_queries(body)

    compiled_meta = Map.merge(rule_meta || %{}, %{context_path: context_path})

    when_rules =
      Enum.map(when_blocks, fn %AST.When{event: event, body: when_body, guard: guard, duration: duration} ->
        subscriptions = event_to_subscriptions(event)
        handler = build_guarded_handler(when_body, guard)
        dwell_ms = duration_to_dwell_ms(duration)

        %CompiledRule{
          name: name,
          subscriptions: subscriptions,
          handler: handler,
          meta: compiled_meta,
          dwell_duration_ms: dwell_ms
        }
      end)

    {at_schedules, at_rules} =
      if at_blocks == [] do
        {[], []}
      else
        at_blocks
        |> Enum.map(&compile_at_block(&1, compiled_meta))
        |> Enum.unzip()
      end

    {when_rules ++ at_rules, at_schedules, inline_data, inline_queries}
  end

  defp extract_context_path(body) do
    Enum.find_value(body, nil, fn
      %AST.Context{path: path} -> path
      _ -> nil
    end)
  end

  # --- Extract inline data/query declarations from rule body ---

  defp extract_inline_data(body, rule_name) do
    Enum.flat_map(body, fn
      %AST.DataDecl{} = data ->
        compiled = compile_data(data)
        # For local scope, use rule name as discriminator
        scope = if compiled.scope == :local, do: {:local, rule_name}, else: compiled.scope
        [%{compiled | scope: scope}]
      %AST.Context{body: ctx_body} -> extract_inline_data(ctx_body, rule_name)
      _other -> []
    end)
  end

  defp extract_inline_queries(body) do
    Enum.flat_map(body, fn
      %AST.QueryDecl{} = query -> [compile_query(query)]
      %AST.Context{body: ctx_body} -> extract_inline_queries(ctx_body)
      _other -> []
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

  # --- Dwell duration ---

  defp duration_to_dwell_ms(nil), do: nil

  defp duration_to_dwell_ms({0, _unit}) do
    throw({:compile_error, "for <duration>: zero duration not allowed"})
  end

  # `to_ms!/1` rather than `to_ms/1`: the non-bang form returns an error tuple
  # for an unrecognised unit, which would be stored as if it were a duration.
  defp duration_to_dwell_ms({amount, unit} = dur) when amount > 0 do
    Anemos.Runtime.Duration.to_ms!(dur)
  rescue
    ArgumentError ->
      throw({:compile_error, "for <duration>: unknown unit #{inspect(unit)}"})
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

  # Flow control (return/done/nextevent/nextrule) aborts evaluation with a
  # throw, which discards the in-flight `Enum.reduce` accumulator. Rather than
  # stashing that accumulator in global state, each level of evaluation catches
  # the throw on its way out and prepends the operations it had accumulated
  # before the abort. The throw payload is therefore the complete op list by
  # the time it reaches `build_handler`, and no state outlives the call.
  defp eval_body(statements, context, bindings) do
    {ops_rev, final_bindings} =
      Enum.reduce(statements, {[], bindings}, fn stmt, {ops_acc, bindings_acc} ->
        {new_ops, new_bindings} =
          prepend_ops_on_abort(Enum.reverse(ops_acc), fn ->
            eval_statement(stmt, context, bindings_acc)
          end)

        {Enum.reverse(new_ops) ++ ops_acc, new_bindings}
      end)

    {Enum.reverse(ops_rev), final_bindings}
  end

  # Run `fun`; if a flow-control throw unwinds through it, re-throw the same
  # signal with `prefix` prepended to the operations it carries. Any other
  # throw (e.g. `{:compile_error, _}`) propagates untouched.
  defp prepend_ops_on_abort([], fun), do: fun.()

  defp prepend_ops_on_abort(prefix, fun) do
    fun.()
  catch
    {:anemos_return, ops, bindings} ->
      throw({:anemos_return, prefix ++ ops, bindings})

    {:anemos_done, ops, bindings} ->
      throw({:anemos_done, prefix ++ ops, bindings})

    {:anemos_nextevent, target, ops, bindings} ->
      throw({:anemos_nextevent, target, prefix ++ ops, bindings})

    {:anemos_nextrule, target, args, ops, bindings} ->
      throw({:anemos_nextrule, target, args, prefix ++ ops, bindings})
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

  # Prior iterations' ops are prepended to any flow-control throw so an early
  # exit from the loop body still reports what earlier iterations produced.
  defp eval_statement(%AST.For{var: var, iterable: iterable, body: body}, context, bindings) do
    collection = resolve_iterable(iterable, context, bindings)

    Enum.reduce(collection, {[], bindings}, fn item, {ops_acc, bindings_acc} ->
      iter_bindings = Map.put(bindings_acc, {:let, var}, item)

      {new_ops, new_bindings} =
        prepend_ops_on_abort(ops_acc, fn -> eval_body(body, context, iter_bindings) end)

      cleaned = Map.delete(new_bindings, {:let, var})
      {ops_acc ++ new_ops, cleaned}
    end)
  end

  # Flow control throws carry the ops accumulated so far. Each enclosing body
  # and loop prepends its own accumulation as the throw unwinds — see
  # `prepend_ops_on_abort/2`.
  defp eval_statement(%AST.Return{}, _context, bindings) do
    throw({:anemos_return, [], bindings})
  end

  defp eval_statement(%AST.Done{}, _context, bindings) do
    throw({:anemos_done, [], bindings})
  end

  defp eval_statement(%AST.NextEvent{target: target}, _context, bindings) do
    throw({:anemos_nextevent, target, [], bindings})
  end

  defp eval_statement(%AST.NextRule{target: target, args: args}, context, bindings) do
    resolved_args = case args do
      %AST.BlockArgs{pairs: pairs} ->
        Map.new(pairs, fn {k, v} -> {k, resolve_expr(v, context, bindings)} end)
      _ -> nil
    end

    throw({:anemos_nextrule, target, resolved_args, [], bindings})
  end

  # Inline data/query declarations are extracted and registered at compile/load
  # time (see extract_inline_data/2), not at runtime. Skip them here.
  defp eval_statement(%AST.DataDecl{}, _context, bindings), do: {[], bindings}
  defp eval_statement(%AST.QueryDecl{}, _context, bindings), do: {[], bindings}

  defp eval_statement(_other, _context, bindings) do
    {[], bindings}
  end

  # --- While loop helpers ---

  defp eval_while(_condition, _body, _context, bindings, ops_acc, iteration)
       when iteration >= @while_limit do
    {ops_acc, bindings}
  end

  # Ops from prior iterations are prepended to any flow-control throw so an
  # early exit from the loop body still reports what earlier iterations produced.
  defp eval_while(condition, body, context, bindings, ops_acc, iteration) do
    if eval_condition(condition, context, bindings) do
      {new_ops, new_bindings} =
        prepend_ops_on_abort(ops_acc, fn -> eval_body(body, context, bindings) end)

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

  defp resolve_expr(%AST.BuiltinCall{} = call, _context, _bindings), do: call

  defp resolve_expr(other, _context, _bindings), do: other

  defp resolve_triple_element(%AST.Literal{value: value}, _context, _bindings), do: value
  defp resolve_triple_element(%AST.VarRef{sigil: "?", name: name}, _context, _bindings), do: {:var, name}
  defp resolve_triple_element(%AST.VarRef{} = ref, context, bindings), do: resolve_expr(ref, context, bindings)
  defp resolve_triple_element(other, _context, _bindings), do: other

  # --- Condition evaluation ---

  # Pipe operator: resolve left side, keep right side as AST for eval_pipe
  defp eval_condition(%AST.BinaryOp{op: :|>, left: left, right: right}, context, bindings) do
    collection = resolve_expr(left, context, bindings)
    eval_pipe(collection, right, context, bindings)
  end

  defp eval_condition(%AST.BinaryOp{op: op, left: left, right: right}, context, bindings) do
    l = resolve_expr(left, context, bindings)
    r = resolve_expr(right, context, bindings)

    case op do
      # Comparison
      op when op in [:eq, :==] ->
        warn_boolean_mismatch(op, l, r)
        l == r

      op when op in [:ne, :!=] ->
        warn_boolean_mismatch(op, l, r)
        l != r

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
      :memberof ->
        names = if is_list(r), do: r, else: [r]
        data_store = Map.get(context, :data_store)
        if data_store do
          rule_name = Map.get(context, :_rule_name)
          opts = if rule_name, do: [scope_hint: rule_name], else: []
          Anemos.Runtime.DataStore.member_any?(data_store, names, l, opts)
        else
          false
        end
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

  # A-46. Equality does not coerce, so a boolean on one side and a
  # boolean-shaped string on the other can never be equal. That is the exact
  # shape of the mistake A-46 reported — a policy written against a boolean and
  # a host sending a string, or the reverse — and the whole defect was that it
  # produced no signal. The comparison still answers honestly; the author hears
  # about it. Narrow on purpose: `?name == "alpha"` is an ordinary string
  # comparison and says nothing.
  defp warn_boolean_mismatch(op, l, r) do
    if boolean_string_mismatch?(l, r) do
      Logger.warning(
        "[anemos] boolean/string mismatch in #{op}: #{inspect(l)} and #{inspect(r)} are " <>
          "different types and can never be equal. Boolean literals are `true`/`false`; " <>
          "the quoted forms are strings."
      )
    end

    :ok
  end

  defp boolean_string_mismatch?(l, r) when is_boolean(l), do: r in ["true", "false"]
  defp boolean_string_mismatch?(l, r) when is_boolean(r), do: l in ["true", "false"]
  defp boolean_string_mismatch?(_l, _r), do: false

  # --- Pipe evaluation ---

  defp eval_pipe(collection, %AST.BuiltinCall{name: :filter, args: [var_name, predicate]}, context, bindings) do
    predicate_fn = fn ctx, bnd -> eval_condition(predicate, ctx, bnd) end
    Anemos.Runtime.Builtins.filter(collection, var_name, predicate_fn, context, bindings)
  end

  defp eval_pipe(collection, %AST.BuiltinCall{name: :map, args: [var_name, transform]}, context, bindings) do
    transform_fn = fn ctx, bnd -> resolve_expr(transform, ctx, bnd) end
    Anemos.Runtime.Builtins.map(collection, var_name, transform_fn, context, bindings)
  end

  defp eval_pipe(collection, %AST.BuiltinCall{name: :reduce, args: [acc_name, initial_expr, var_name, body]}, context, bindings) do
    initial = resolve_expr(initial_expr, context, bindings)
    body_fn = fn ctx, bnd -> resolve_expr(body, ctx, bnd) end
    Anemos.Runtime.Builtins.reduce(collection, acc_name, initial, var_name, body_fn, context, bindings)
  end

  defp eval_pipe(collection, %AST.BuiltinCall{name: :emit, args: [command]}, context, bindings) do
    command_fn = fn element, ctx, bnd ->
      case command do
        %AST.Command{module: mod, verb: verb, args: args} ->
          resolved_args = [element | Enum.map(args, &resolve_expr(&1, ctx, bnd))]
          %{type: :command, module: mod, verb: verb, args: resolved_args}

        other ->
          resolve_expr(other, ctx, bnd)
      end
    end

    Anemos.Runtime.Builtins.emit(collection, command_fn, context, bindings)
  end

  # Pipe with a command: prepend collection to args
  defp eval_pipe(collection, %AST.Command{module: mod, verb: verb, args: args}, context, bindings) do
    resolved_args = [collection | Enum.map(args, &resolve_expr(&1, context, bindings))]
    %{type: :command, module: mod, verb: verb, args: resolved_args}
  end

  # Pipe with any other expression
  defp eval_pipe(collection, other, context, bindings) do
    _ = collection
    resolve_expr(other, context, bindings)
  end
end
