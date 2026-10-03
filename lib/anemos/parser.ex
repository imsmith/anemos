defmodule Anemos.Parser do
  @introspection ~w(show list graph trace explain exists infer assert)a
  @catalogues %{
    "rules" => :rules,
    "conditions" => :conditions,
    "modules" => :modules,
    "events" => :events,
    "policies" => :policies,
    "schedules" => :schedules
  }

  @moduledoc """
  Recursive descent parser for the Anemos DSL.

  Consumes the token stream from `Anemos.Lexer.tokenize/1` and produces
  an `Anemos.AST.Program` struct.

  Supported declarations: `rule`, `condition`, `capability`, `data`, `query`,
  and source-level `signed_by` (A-60).

  Supported trigger blocks: `when`, `if`, `at`, `context`.
  Guard modifiers: `unless`, `until` (on `when`, `if`, `at`).

  Supported statements: `let`, `set`, `log`, `emit`, `demand`,
  `while`, `for`, `each`, `every`, `foreach`,
  `return`, `done`, `nextevent`, `nextrule`,
  and `[MODULE::verb ...]` command expressions.

  ## `parse/1` is total, and that is a security property

  For **any** binary, `parse/1` answers `{:ok, %AST.Program{}}` or
  `{:error, message}`. It does not raise, and it terminates.

  This is not tidiness. `parse/1` is the only path from source text to an AST —
  `Anemos.Runtime.LoadAuthority.gate/3` runs it *before* deciding whether the
  source may be trusted — and under the multi-tenant decision that text is
  untrusted input. Every caller matching `{:error, _}` gets an exception
  instead if a clause is missing, and a truncated or hostile `.rule` file is
  exactly the input this boundary is most likely to meet.

  Totality has been broken three times (A-65, A-74, A-75), so the rule is
  written down:

  > **Whoever knows what must come next owns the end-of-input check.**

  A function that dispatches on token shape must therefore be total over
  *both* an empty token list **and** a token it does not expect. Missing either
  is the same defect: `collect_simple_list/2` had its `[]` clause and still
  crashed, on a token type it had no clause for (A-75).

  The converse matters too, or the rule just breeds dead code. Where a caller
  selects a function by matching the token itself, the caller has already
  answered and the callee must *not* answer again. Exactly three functions here
  have no `[]` clause for that reason — `parse_declaration/1`,
  `parse_bracket_expr/1` and `parse_format_block/1` — and each carries a
  comment saying which caller answered, so a totality sweep does not "fix"
  them. When in doubt, add the clause and let Dialyzer adjudicate: it reports
  an unreachable pattern, which is precisely the question being asked (A-71).

  Both classes are covered by tests rather than by inspection —
  `Anemos.ParserTruncationTest` sweeps every prefix of every shipped example,
  and `Anemos.ParserFuzzTest` mutates them.
  """

  alias Anemos.AST

  # Operator precedence, from spec section 7.1, inverted so higher = tighter binding.
  #
  # Declared one level per entry so the grouping is data rather than typography;
  # `@precedence` (operator => level) is derived from it at compile time. Add an
  # operator by putting it in its level's list — nothing else needs to change.
  @precedence_levels [
    {0, [:|>]},
    {1,
     [:in, :notin, :contains, :starts_with, :ends_with, :matches_glob, :matches_regex, :memberof]},
    {2, [:||, :or]},
    {3, [:&&, :and]},
    {4, [:|]},
    {5, [:^]},
    {6, [:&]},
    {7, [:==, :!=, :===, :!==, :eq, :ne]},
    {8, [:<, :<=, :>, :>=, :lt, :le, :gt, :ge]},
    {9, [:"<<", :">>"]},
    {10, [:+, :-]},
    {11, [:*, :/, :%]}
  ]

  @precedence Map.new(
                for {level, operators} <- @precedence_levels,
                    operator <- operators,
                    do: {operator, level}
              )

  # An operator listed at two levels would be silently resolved by map-build
  # order, which is exactly the kind of transcription slip a precedence table
  # must not tolerate. Fail the build instead.
  @operator_count Enum.sum(for {_level, operators} <- @precedence_levels, do: length(operators))
  if @operator_count != map_size(@precedence) do
    raise "@precedence_levels lists an operator at more than one precedence level"
  end

  @doc false
  # Exposed for tests: the derived operator => precedence-level map.
  @spec precedence_table() :: %{atom() => non_neg_integer()}
  def precedence_table, do: @precedence

  # --- Public API ---

  @doc """
  Parse a source string into an AST.

  Returns `{:ok, %Anemos.AST.Program{}}` or `{:error, message}`.

  ## Examples

      iex> {:ok, %Anemos.AST.Program{declarations: [rule]}} =
      ...>   Anemos.Parser.parse("rule test { when EVENT { log \\"hello\\" } }")
      iex> rule.name
      "test"
      iex> [%Anemos.AST.When{event: "EVENT", body: [%Anemos.AST.Log{}]}] = rule.body

      iex> {:error, _msg} = Anemos.Parser.parse("rule { }")

  A source-level `signed_by` is a declaration in its own right, so a file
  carrying no `rule` can still make a provenance claim (A-60):

      iex> {:ok, %Anemos.AST.Program{declarations: declarations}} =
      ...>   Anemos.Parser.parse("signed_by :operator\\ncondition c { when EV { log \\"x\\" } }")
      iex> Enum.find(declarations, &match?(%Anemos.AST.SignedBy{}, &1))
      %Anemos.AST.SignedBy{signer: "operator", line: 1}

  Truncated input returns an error rather than raising. `parse/1` is total over
  binaries because it runs before the trust boundary, not after it:

      iex> Anemos.Parser.parse("rule r { when")
      {:error, "Expected event name after 'when' but got end of input"}

      iex> {:ok, %Anemos.AST.Program{declarations: []}} = Anemos.Parser.parse("")
  """
  @spec parse(String.t()) :: {:ok, AST.Program.t()} | {:error, String.t()}
  def parse(source) when is_binary(source) do
    case Anemos.Lexer.tokenize(source) do
      {:ok, tokens} ->
        parse_program(tokens)

      {:error, message, line, _col} ->
        {:error, "Lexer error on line #{line}: #{message}"}
    end
  end

  # --- Program ---

  defp parse_program(tokens) do
    case parse_declarations(tokens, []) do
      {:ok, declarations, []} ->
        {:ok, %AST.Program{declarations: Enum.reverse(declarations)}}

      {:ok, _declarations, remaining} ->
        line = tokens_line(remaining)
        {:error, "Unexpected token #{inspect(elem(hd(remaining), 0))} on line #{line}"}

      {:error, _} = err ->
        err
    end
  end

  # A-71. Two different questions look like one here, and only one of them is
  # this clause's.
  #
  # "Is there anything left to walk?" is loop termination, and it is this
  # clause. "Is running out of input acceptable *at this point*?" is a question
  # about the language, and it belongs to whoever knows what must come next —
  # which is why `parse_rule/1`, `parse_when/1` and their siblings each answer
  # it for their own position with an `[]` clause of their own. At the top of a
  # source nothing is required to follow, so a file may end after any complete
  # declaration and the two answers happen to coincide: empty means both "stop"
  # and "fine".
  #
  # Because this clause gives that answer, `parse_declaration/1` — which is
  # called only from the clause below, and so only on a non-empty list — never
  # needs one. It used to carry an `[]` clause reading "Unexpected end of
  # input", which contradicted the answer already given and was unreachable
  # from the commit that introduced it. Proven so before deleting: armed to
  # raise, it was not hit by the suite or by 5,955 truncated sources.
  defp parse_declarations([], acc), do: {:ok, acc, []}

  defp parse_declarations(tokens, acc) do
    case parse_declaration(tokens) do
      {:ok, node, rest} ->
        parse_declarations(rest, [node | acc])

      {:error, _} = err ->
        if acc == [] do
          err
        else
          # Could be end of parseable declarations
          {:ok, acc, tokens}
        end
    end
  end

  # --- Declaration dispatch ---

  # A-60. `signed_by` at source level, outside any declaration. It was
  # rule-only syntax, reachable from `parse_rule/1` alone, so a source of
  # conditions, capabilities or data blocks could not make a provenance claim
  # and `:strict` could never load one. The signature covers the whole source
  # regardless, so this placement is also the one that describes what is
  # actually being claimed.
  defp parse_declaration([{:keyword, meta, :signed_by}, {:atom, _, signer} | rest]) do
    {:ok, %AST.SignedBy{signer: signer, line: meta[:line]}, rest}
  end

  defp parse_declaration([{:keyword, meta, :signed_by} | _]) do
    {:error, "Expected a signer name after 'signed_by' on line #{meta[:line]}"}
  end

  defp parse_declaration([{:keyword, _, :rule} | rest]) do
    parse_rule(rest)
  end

  defp parse_declaration([{:keyword, _, :condition} | rest]) do
    parse_condition_decl(rest)
  end

  defp parse_declaration([{:keyword, _, :capability} | rest]) do
    parse_capability(rest)
  end

  defp parse_declaration([{:keyword, _, :data} | rest]) do
    parse_data(rest)
  end

  defp parse_declaration([{:keyword, _, :query} | rest]) do
    parse_query(rest)
  end

  defp parse_declaration([{type, meta, _} | _]) do
    {:error, "Expected declaration (rule, condition, ...) but got #{type} on line #{meta[:line]}"}
  end

  # --- Rule ---

  defp parse_rule([{:identifier, meta, name} | rest]) do
    with {:ok, rest} <- expect(rest, :lbrace),
         {rule_meta, rest} <- parse_rule_metadata(rest, %{}),
         {:ok, body, rest} <- parse_rule_body(rest, []),
         {:ok, rest} <- expect(rest, :rbrace) do
      rule_meta = if rule_meta == %{}, do: nil, else: rule_meta

      {:ok, %AST.Rule{name: name, body: Enum.reverse(body), meta: rule_meta, line: meta[:line]},
       rest}
    end
  end

  # Allow keywords used as rule names (e.g. "rule global { }", "rule query { }")
  defp parse_rule([{:keyword, meta, kw} | rest]) do
    parse_rule([{:identifier, meta, Atom.to_string(kw)} | rest])
  end

  defp parse_rule([{type, meta, _} | _]) do
    {:error, "Expected rule name (identifier) but got #{type} on line #{meta[:line]}"}
  end

  defp parse_rule([]) do
    {:error, "Expected rule name but got end of input"}
  end

  # Rule metadata: version, signed_by, scope — parsed before body
  defp parse_rule_metadata([{:keyword, _, :version}, {:string, _, version} | rest], acc) do
    parse_rule_metadata(rest, Map.put(acc, :version, version))
  end

  defp parse_rule_metadata([{:keyword, _, :version}, {:identifier, _, version} | rest], acc) do
    parse_rule_metadata(rest, Map.put(acc, :version, version))
  end

  defp parse_rule_metadata([{:keyword, _, :signed_by}, {:atom, _, signer} | rest], acc) do
    parse_rule_metadata(rest, Map.put(acc, :signed_by, signer))
  end

  defp parse_rule_metadata([{:keyword, _, :scope}, {:identifier, _, scope} | rest], acc)
       when scope in ["local", "global", "mesh"] do
    parse_rule_metadata(rest, Map.put(acc, :scope, String.to_atom(scope)))
  end

  # "global" is now a keyword token; accept keyword in scope position too
  defp parse_rule_metadata([{:keyword, _, :scope}, {:keyword, _, scope} | rest], acc)
       when scope in [:local, :global, :mesh] do
    parse_rule_metadata(rest, Map.put(acc, :scope, scope))
  end

  defp parse_rule_metadata(tokens, acc), do: {acc, tokens}

  # Rule body: context blocks, when blocks, or statements
  defp parse_rule_body([{:rbrace, _, _} | _] = tokens, acc), do: {:ok, acc, tokens}

  defp parse_rule_body([{:keyword, _, :context} | rest], acc) do
    case parse_context(rest) do
      {:ok, node, rest} -> parse_rule_body(rest, [node | acc])
      {:error, _} = err -> err
    end
  end

  defp parse_rule_body([{:keyword, _, :when} | rest], acc) do
    case parse_when(rest) do
      {:ok, node, rest} -> parse_rule_body(rest, [node | acc])
      {:error, _} = err -> err
    end
  end

  defp parse_rule_body([{:keyword, _, :at} | rest], acc) do
    case parse_at(rest) do
      {:ok, node, rest} -> parse_rule_body(rest, [node | acc])
      {:error, _} = err -> err
    end
  end

  defp parse_rule_body(tokens, acc) do
    case parse_statement(tokens) do
      {:ok, node, rest} -> parse_rule_body(rest, [node | acc])
      {:error, _} = err -> err
    end
  end

  # --- Context ---

  defp parse_context([{:string, meta, path} | rest]) do
    with {:ok, rest} <- expect(rest, :lbrace),
         {:ok, body, rest} <- parse_context_body(rest, []),
         {:ok, rest} <- expect(rest, :rbrace) do
      {:ok, %AST.Context{path: path, body: Enum.reverse(body), line: meta[:line]}, rest}
    end
  end

  defp parse_context([{:identifier, meta, path} | [{:lbrace, _, _} | _] = rest]) do
    with {:ok, rest} <- expect(rest, :lbrace),
         {:ok, body, rest} <- parse_context_body(rest, []),
         {:ok, rest} <- expect(rest, :rbrace) do
      {:ok, %AST.Context{path: path, body: Enum.reverse(body), line: meta[:line]}, rest}
    end
  end

  # Standalone context (no braces) — just sets the context path
  defp parse_context([{:identifier, meta, path} | rest]) do
    {:ok, %AST.Context{path: path, body: [], line: meta[:line]}, rest}
  end

  defp parse_context([{_, meta, _} | _]) do
    {:error, "Expected context path on line #{meta[:line]}"}
  end

  defp parse_context([]) do
    {:error, "Expected context path but got end of input"}
  end

  # Context body: when blocks or statements
  defp parse_context_body([{:rbrace, _, _} | _] = tokens, acc), do: {:ok, acc, tokens}

  defp parse_context_body([{:keyword, _, :when} | rest], acc) do
    case parse_when(rest) do
      {:ok, node, rest} -> parse_context_body(rest, [node | acc])
      {:error, _} = err -> err
    end
  end

  defp parse_context_body(tokens, acc) do
    case parse_statement(tokens) do
      {:ok, node, rest} -> parse_context_body(rest, [node | acc])
      {:error, _} = err -> err
    end
  end

  # --- When ---

  # MODULE::name pattern (e.g. CONDITION::networkchanged)
  defp parse_when([{:module_id, meta, mod}, {:double_colon, _, _}, {:identifier, _, name} | rest]) do
    event = "#{mod}::#{name}"
    {duration, rest} = parse_optional_duration(rest)
    {guard, rest} = parse_optional_guard(rest)

    with {:ok, rest} <- expect(rest, :lbrace),
         {:ok, body, rest} <- parse_statements_until_rbrace(rest, []),
         {:ok, rest} <- expect(rest, :rbrace) do
      {:ok,
       %AST.When{
         event: event,
         duration: duration,
         guard: guard,
         body: Enum.reverse(body),
         line: meta[:line]
       }, rest}
    end
  end

  # Simple module_id event (e.g. SENSOR_MOTION_DETECTED)
  defp parse_when([{:module_id, meta, event} | rest]) do
    {duration, rest} = parse_optional_duration(rest)
    {guard, rest} = parse_optional_guard(rest)

    with {:ok, rest} <- expect(rest, :lbrace),
         {:ok, body, rest} <- parse_statements_until_rbrace(rest, []),
         {:ok, rest} <- expect(rest, :rbrace) do
      {:ok,
       %AST.When{
         event: event,
         duration: duration,
         guard: guard,
         body: Enum.reverse(body),
         line: meta[:line]
       }, rest}
    end
  end

  # Identifier event name (e.g. my.event — used for emit label re-dispatch targets)
  defp parse_when([{:identifier, meta, event} | rest]) do
    {duration, rest} = parse_optional_duration(rest)
    {guard, rest} = parse_optional_guard(rest)

    with {:ok, rest} <- expect(rest, :lbrace),
         {:ok, body, rest} <- parse_statements_until_rbrace(rest, []),
         {:ok, rest} <- expect(rest, :rbrace) do
      {:ok,
       %AST.When{
         event: event,
         duration: duration,
         guard: guard,
         body: Enum.reverse(body),
         line: meta[:line]
       }, rest}
    end
  end

  # Compound event in parens: (EVENT1 OR EVENT2)
  defp parse_when([{:lparen, meta, _} | rest]) do
    case parse_compound_event(rest, []) do
      {:ok, event_expr, rest} ->
        with {:ok, rest} <- expect(rest, :rparen) do
          {duration, rest} = parse_optional_duration(rest)
          {guard, rest} = parse_optional_guard(rest)

          with {:ok, rest} <- expect(rest, :lbrace),
               {:ok, body, rest} <- parse_statements_until_rbrace(rest, []),
               {:ok, rest} <- expect(rest, :rbrace) do
            {:ok,
             %AST.When{
               event: event_expr,
               duration: duration,
               guard: guard,
               body: Enum.reverse(body),
               line: meta[:line]
             }, rest}
          end
        end

      {:error, _} = err ->
        err
    end
  end

  defp parse_when([{_, meta, _} | _]) do
    {:error, "Expected event name after 'when' on line #{meta[:line]}"}
  end

  defp parse_when([]) do
    {:error, "Expected event name after 'when' but got end of input"}
  end

  # Parse compound event expressions like: INFRA::ip4_addr_changed OR INFRA::ip6_addr_changed
  # Returns a structured tuple: {:compound, :or, [events]} or {:compound, :and, [events]}
  defp parse_compound_event([{:rparen, _, _} | _] = tokens, acc) do
    parts = Enum.reverse(acc)
    event = build_compound_event(parts)
    {:ok, event, tokens}
  end

  defp parse_compound_event(
         [{:module_id, _, mod}, {:double_colon, _, _}, {:identifier, _, name} | rest],
         acc
       ) do
    parse_compound_event(rest, [{:event, "#{mod}::#{name}"} | acc])
  end

  defp parse_compound_event([{:module_id, _, name} | rest], acc) when name in ["OR", "AND"] do
    op = name |> String.downcase() |> String.to_atom()
    parse_compound_event(rest, [{:op, op} | acc])
  end

  defp parse_compound_event([{:module_id, _, name} | rest], acc) do
    parse_compound_event(rest, [{:event, name} | acc])
  end

  defp parse_compound_event([{_, meta, _} | _], _acc) do
    {:error, "Unexpected token in compound event on line #{meta[:line]}"}
  end

  defp parse_compound_event([], _acc) do
    {:error, "Unterminated compound event: expected ')' but got end of input"}
  end

  defp build_compound_event(parts) do
    events = for {:event, e} <- parts, do: e
    ops = for {:op, o} <- parts, do: o
    # Use the first operator found (all should be the same in well-formed input)
    op = List.first(ops) || :or
    {:compound, op, events}
  end

  defp parse_optional_duration([{:keyword, _, :for}, {:duration, _, duration} | rest]) do
    {duration, rest}
  end

  defp parse_optional_duration(tokens), do: {nil, tokens}

  # --- Optional guard: unless/until ---

  defp parse_optional_guard([{:keyword, _, :unless} | rest]) do
    case parse_expression(rest) do
      {:ok, expr, rest} -> {{:unless, expr}, rest}
      {:error, _} = err -> err
    end
  end

  defp parse_optional_guard([{:keyword, _, :until} | rest]) do
    case parse_expression(rest) do
      {:ok, expr, rest} -> {{:until, expr}, rest}
      {:error, _} = err -> err
    end
  end

  defp parse_optional_guard(tokens), do: {nil, tokens}

  # --- At ---

  # at interval(duration) { ... }
  defp parse_at([
         {:keyword, meta, :interval},
         {:lparen, _, _},
         {:duration, _, dur},
         {:rparen, _, _} | rest
       ]) do
    {guard, rest} = parse_optional_guard(rest)

    with {:ok, rest} <- expect(rest, :lbrace),
         {:ok, body, rest} <- parse_statements_until_rbrace(rest, []),
         {:ok, rest} <- expect(rest, :rbrace) do
      {:ok,
       %AST.At{
         time_spec: {:interval, dur},
         guard: guard,
         body: Enum.reverse(body),
         line: meta[:line]
       }, rest}
    end
  end

  # at <time_literal> every <recurrence> { ... }
  defp parse_at([{:time_literal, meta, time}, {:keyword, _, :every} | rest]) do
    with {:ok, recurrence, rest} <- parse_recurrence(rest),
         {guard, rest} = parse_optional_guard(rest),
         {:ok, rest} <- expect(rest, :lbrace),
         {:ok, body, rest} <- parse_statements_until_rbrace(rest, []),
         {:ok, rest} <- expect(rest, :rbrace) do
      {:ok,
       %AST.At{
         time_spec: {:recurring, {:time, time}, recurrence},
         guard: guard,
         body: Enum.reverse(body),
         line: meta[:line]
       }, rest}
    end
  end

  # at <time_literal> { ... }
  defp parse_at([{:time_literal, meta, time} | rest]) do
    {guard, rest} = parse_optional_guard(rest)

    with {:ok, rest} <- expect(rest, :lbrace),
         {:ok, body, rest} <- parse_statements_until_rbrace(rest, []),
         {:ok, rest} <- expect(rest, :rbrace) do
      {:ok,
       %AST.At{
         time_spec: {:time, time},
         guard: guard,
         body: Enum.reverse(body),
         line: meta[:line]
       }, rest}
    end
  end

  # at DATE_YYYY.MM.DD { ... }
  defp parse_at([{:date_literal, meta, date} | rest]) do
    {guard, rest} = parse_optional_guard(rest)

    with {:ok, rest} <- expect(rest, :lbrace),
         {:ok, body, rest} <- parse_statements_until_rbrace(rest, []),
         {:ok, rest} <- expect(rest, :rbrace) do
      {:ok,
       %AST.At{
         time_spec: {:date, date},
         guard: guard,
         body: Enum.reverse(body),
         line: meta[:line]
       }, rest}
    end
  end

  # at NLD_expression { ... }
  defp parse_at([{:nld_literal, meta, text} | rest]) do
    {guard, rest} = parse_optional_guard(rest)

    with {:ok, rest} <- expect(rest, :lbrace),
         {:ok, body, rest} <- parse_statements_until_rbrace(rest, []),
         {:ok, rest} <- expect(rest, :rbrace) do
      {:ok,
       %AST.At{
         time_spec: {:nld, text},
         guard: guard,
         body: Enum.reverse(body),
         line: meta[:line]
       }, rest}
    end
  end

  # at DAY_weekday { ... }
  defp parse_at([{:day_literal, meta, day} | rest]) do
    {guard, rest} = parse_optional_guard(rest)

    with {:ok, rest} <- expect(rest, :lbrace),
         {:ok, body, rest} <- parse_statements_until_rbrace(rest, []),
         {:ok, rest} <- expect(rest, :rbrace) do
      {:ok,
       %AST.At{time_spec: {:day, day}, guard: guard, body: Enum.reverse(body), line: meta[:line]},
       rest}
    end
  end

  defp parse_at([{_, meta, _} | _]) do
    {:error, "Expected time spec after 'at' on line #{meta[:line]}"}
  end

  defp parse_at([]) do
    {:error, "Expected time spec after 'at' but got end of input"}
  end

  # Recurrence: day | weekday | weekend | <weekday_name>.
  #
  # Closed set. Source text is untrusted, and atoms are never collected, so an
  # unrecognised name must become a parse error rather than a new atom — a parse
  # failure is recoverable, atom-table exhaustion takes the node down. The set is
  # also what Anemos.Runtime.Scheduler actually dispatches on; anything else used
  # to parse cleanly and then crash the scheduler at fire time.
  @recurrences Map.new(
                 ~w(day weekday weekend monday tuesday wednesday thursday friday saturday sunday),
                 &{&1, String.to_atom(&1)}
               )

  defp parse_recurrence([{:keyword, _, :day} | rest]), do: {:ok, :day, rest}

  defp parse_recurrence([{:identifier, meta, name} | rest]) do
    case Map.fetch(@recurrences, name) do
      {:ok, recurrence} ->
        {:ok, recurrence, rest}

      :error ->
        {:error, "Unknown recurrence #{inspect(name)} after 'every' on line #{meta[:line]}"}
    end
  end

  defp parse_recurrence(tokens), do: {:ok, :day, tokens}

  # --- Statements ---

  defp parse_statements_until_rbrace([{:rbrace, _, _} | _] = tokens, acc), do: {:ok, acc, tokens}

  defp parse_statements_until_rbrace(tokens, acc) do
    case parse_statement(tokens) do
      {:ok, node, rest} -> parse_statements_until_rbrace(rest, [node | acc])
      {:error, _} = err -> err
    end
  end

  defp parse_statement([{:keyword, _, :let} | rest]), do: parse_let(rest)
  defp parse_statement([{:keyword, _, :set} | rest]), do: parse_set(rest)
  defp parse_statement([{:keyword, _, :log} | rest]), do: parse_log(rest)
  defp parse_statement([{:keyword, _, :emit} | rest]), do: parse_emit(rest)
  defp parse_statement([{:keyword, _, :demand} | rest]), do: parse_demand(rest)
  defp parse_statement([{:keyword, _, :if} | rest]), do: parse_if(rest)
  defp parse_statement([{:keyword, _, :when} | rest]), do: parse_when(rest)
  defp parse_statement([{:keyword, _, :at} | rest]), do: parse_at(rest)
  defp parse_statement([{:keyword, _, :context} | rest]), do: parse_context(rest)
  defp parse_statement([{:lbracket, _, _} | _] = tokens), do: parse_command_statement(tokens)
  defp parse_statement([{:keyword, _, :while} | rest]), do: parse_while(rest)
  defp parse_statement([{:keyword, _, :for} | rest]), do: parse_for(rest)
  defp parse_statement([{:keyword, _, :each} | rest]), do: parse_each(rest)
  defp parse_statement([{:keyword, _, :every} | rest]), do: parse_each(rest)
  defp parse_statement([{:keyword, _, :foreach} | rest]), do: parse_foreach(rest)
  defp parse_statement([{:keyword, _, :return} | rest]), do: parse_return(rest)
  defp parse_statement([{:keyword, _, :done} | rest]), do: parse_done(rest)
  defp parse_statement([{:keyword, _, :nextevent} | rest]), do: parse_nextevent(rest)
  defp parse_statement([{:keyword, _, :nextrule} | rest]), do: parse_nextrule(rest)
  defp parse_statement([{:keyword, _, :data} | rest]), do: parse_inline_data(rest)
  defp parse_statement([{:keyword, _, :query} | rest]), do: parse_inline_query(rest)

  defp parse_statement([{:keyword, meta, verb} | rest]) when verb in @introspection,
    do: parse_introspect(verb, meta[:line], rest)

  defp parse_statement([{type, meta, _} | _]) do
    {:error, "Unexpected token #{type} on line #{meta[:line]}, expected statement"}
  end

  defp parse_statement([]) do
    {:error, "Unexpected end of input, expected statement"}
  end

  # --- Inline data/query (inside rule bodies, default scope :local) ---

  defp parse_inline_data([{:keyword, _, :global}, {name_type, meta, name} | rest])
       when name_type in [:identifier, :keyword] do
    name_str = if name_type == :keyword, do: Atom.to_string(name), else: name

    with {:ok, rest} <- expect(rest, :lbrace),
         {:ok, source, content, transclude, rest} <- parse_data_body(rest),
         {:ok, rest} <- expect(rest, :rbrace) do
      {:ok,
       %AST.DataDecl{
         name: name_str,
         source: source,
         content: content,
         transclude: transclude,
         scope: :global,
         line: meta[:line]
       }, rest}
    end
  end

  defp parse_inline_data([{:identifier, meta, name} | rest]) do
    with {:ok, rest} <- expect(rest, :lbrace),
         {:ok, source, content, transclude, rest} <- parse_data_body(rest),
         {:ok, rest} <- expect(rest, :rbrace) do
      {:ok,
       %AST.DataDecl{
         name: name,
         source: source,
         content: content,
         transclude: transclude,
         scope: :local,
         line: meta[:line]
       }, rest}
    end
  end

  defp parse_inline_data([{:keyword, meta, kw} | rest]) do
    parse_inline_data([{:identifier, meta, Atom.to_string(kw)} | rest])
  end

  defp parse_inline_data([{_, meta, _} | _]) do
    {:error, "Expected data block name on line #{meta[:line]}"}
  end

  defp parse_inline_data([]) do
    {:error, "Expected data block name but got end of input"}
  end

  defp parse_inline_query([{:keyword, _, :global}, {name_type, meta, name} | rest])
       when name_type in [:identifier, :keyword] do
    name_str = if name_type == :keyword, do: Atom.to_string(name), else: name

    with {:ok, rest} <- expect(rest, :lbrace),
         {:ok, expect_list, engine, body, return_var, rest} <-
           parse_query_body(name_str, :global, meta[:line], rest),
         {:ok, rest} <- expect(rest, :rbrace) do
      {:ok,
       %AST.QueryDecl{
         name: name_str,
         expect: expect_list,
         engine: engine,
         body: body,
         return: return_var,
         scope: :global,
         line: meta[:line]
       }, rest}
    end
  end

  defp parse_inline_query([{:identifier, meta, name} | rest]) do
    with {:ok, rest} <- expect(rest, :lbrace),
         {:ok, expect_list, engine, body, return_var, rest} <-
           parse_query_body(name, :local, meta[:line], rest),
         {:ok, rest} <- expect(rest, :rbrace) do
      {:ok,
       %AST.QueryDecl{
         name: name,
         expect: expect_list,
         engine: engine,
         body: body,
         return: return_var,
         scope: :local,
         line: meta[:line]
       }, rest}
    end
  end

  defp parse_inline_query([{:keyword, meta, kw} | rest]) do
    parse_inline_query([{:identifier, meta, Atom.to_string(kw)} | rest])
  end

  defp parse_inline_query([{_, meta, _} | _]) do
    {:error, "Expected query block name on line #{meta[:line]}"}
  end

  defp parse_inline_query([]) do
    {:error, "Expected query block name but got end of input"}
  end

  # --- Let ---

  defp parse_let([{:identifier, meta, name}, {:operator, _, :=} | rest]) do
    case parse_expression(rest) do
      {:ok, expr, rest} ->
        {:ok, %AST.Let{name: name, value: expr, line: meta[:line]}, rest}

      {:error, _} = err ->
        err
    end
  end

  # let [triple assertion] — assert a fact into the triple store
  defp parse_let([{:lbracket, meta, _} | _] = tokens) do
    case parse_bracket_expr(tokens) do
      {:ok, %AST.Triple{} = triple, rest} ->
        {:ok, %AST.Let{name: nil, value: triple, line: meta[:line]}, rest}

      {:ok, _other, _rest} ->
        {:error, "Expected triple pattern after 'let [' on line #{meta[:line]}"}

      {:error, _} = err ->
        err
    end
  end

  defp parse_let([{_, meta, _} | _]) do
    {:error, "Expected 'let <name> = <expr>' or 'let [triple]' on line #{meta[:line]}"}
  end

  defp parse_let([]) do
    {:error, "Expected 'let <name> = <expr>' or 'let [triple]' but got end of input"}
  end

  # --- Set ---

  defp parse_set([{:identifier, meta, name}, {:operator, _, :=} | rest]) do
    case parse_expression(rest) do
      {:ok, expr, rest} ->
        {:ok, %AST.Set{name: name, value: expr, line: meta[:line]}, rest}

      {:error, _} = err ->
        err
    end
  end

  defp parse_set([{_, meta, _} | _]) do
    {:error, "Expected 'set <name> = <expr>' on line #{meta[:line]}"}
  end

  defp parse_set([]) do
    {:error, "Expected 'set <name> = <expr>' but got end of input"}
  end

  # --- Log ---

  # --- Introspection ---
  #
  # `show NAME` asks about a module or an event; `list rules` about a
  # catalogue; anything else is an expression and the subject is its value.
  # `assert` always takes an expression: asserting a name would assert a
  # string.
  defp parse_introspect(verb, line, [{:module_id, _, name} | rest]) when verb != :assert do
    {:ok, %AST.Introspect{verb: verb, subject: {:name, name}, line: line}, rest}
  end

  defp parse_introspect(verb, line, [{:identifier, _, word} | rest])
       when verb != :assert and is_map_key(@catalogues, word) do
    {:ok, %AST.Introspect{verb: verb, subject: {:catalogue, @catalogues[word]}, line: line}, rest}
  end

  defp parse_introspect(verb, line, tokens) do
    case parse_expression(tokens) do
      {:ok, expr, rest} ->
        {:ok, %AST.Introspect{verb: verb, subject: {:expr, expr}, line: line}, rest}

      {:error, _} = err ->
        err
    end
  end

  defp parse_log(tokens) do
    line = tokens_line(tokens)

    case parse_expression(tokens) do
      {:ok, expr, rest} ->
        {:ok, %AST.Log{expression: expr, line: line}, rest}

      {:error, _} = err ->
        err
    end
  end

  # --- Emit ---

  @emit_types [:state, :effect, :stream]

  defp parse_emit(tokens) do
    line = tokens_line(tokens)

    # Check for optional emit type (state/effect/stream)
    {type, tokens} =
      case tokens do
        [{:keyword, _, kw} | rest] when kw in @emit_types -> {kw, rest}
        _ -> {nil, tokens}
      end

    # Parse the command expression — this internally handles `to` destination inside brackets
    case parse_emit_command(tokens) do
      {:ok, command, destination, rest} ->
        # Parse optional "to" destination (outside brackets, if not found inside)
        with {:ok, destination, rest} <-
               if(destination == nil,
                 do: parse_optional_to(rest),
                 else: {:ok, destination, rest}
               ),
             # Parse optional "as" label
             {:ok, label, rest} <- parse_optional_as(rest) do
          {:ok,
           %AST.Emit{
             type: type,
             value: command,
             destination: destination,
             label: label,
             line: line
           }, rest}
        end

      {:error, _} = err ->
        err
    end
  end

  # Parse command for emit — like parse_command but extracts `to destination` from inside brackets
  defp parse_emit_command([{:lbracket, _, _} | rest]) do
    case rest do
      [{:module_id, meta, mod}, {:double_colon, _, _} | rest] ->
        with {:ok, verb, rest} <- parse_command_verb(rest),
             {:ok, args, destination, rest} <- parse_emit_command_args(rest, [], nil),
             {:ok, rest} <- expect(rest, :rbracket) do
          {:ok, %AST.Command{module: mod, verb: verb, args: args, line: meta[:line]}, destination,
           rest}
        end

      [{_, meta, _} | _] ->
        {:error, "Expected MODULE::verb in command on line #{meta[:line]}"}

      [] ->
        {:error, "Unexpected end of input in command"}
    end
  end

  defp parse_emit_command([{_, meta, _} | _]) do
    {:error, "Expected command expression after emit on line #{meta[:line]}"}
  end

  defp parse_emit_command([]) do
    {:error, "Expected command expression after emit but got end of input"}
  end

  # Parse command args for emit, tracking destination
  defp parse_emit_command_args([{:rbracket, _, _} | _] = tokens, acc, dest) do
    {:ok, Enum.reverse(acc), dest, tokens}
  end

  defp parse_emit_command_args([{:comma, _, _} | rest], acc, dest) do
    parse_emit_command_args(rest, acc, dest)
  end

  defp parse_emit_command_args([{:lparen, _, _} | rest], acc, dest) do
    case parse_command_args_until_rparen(rest, acc) do
      {:ok, acc, rest} ->
        with {:ok, rest} <- expect(rest, :rparen) do
          parse_emit_command_args(rest, acc, dest)
        end

      {:error, _} = err ->
        err
    end
  end

  defp parse_emit_command_args([{:keyword, _, :to} | rest], acc, _dest) do
    case parse_destination(rest) do
      {:ok, dest, rest} -> parse_emit_command_args(rest, acc, dest)
      {:error, _} = err -> err
    end
  end

  defp parse_emit_command_args(tokens, acc, dest) do
    case parse_atom_expression(tokens) do
      {:ok, expr, rest} -> parse_emit_command_args(rest, [expr | acc], dest)
      {:error, _} = err -> err
    end
  end

  defp parse_optional_to([{:keyword, _, :to} | rest]) do
    case parse_destination(rest) do
      {:ok, dest, rest} -> {:ok, dest, rest}
      {:error, _} = err -> err
    end
  end

  defp parse_optional_to(tokens), do: {:ok, nil, tokens}

  defp parse_destination([{:keyword, _, :channel}, {:lparen, _, _} | rest]) do
    case parse_dotted_path_until_rparen(rest) do
      {:ok, path, rest} ->
        with {:ok, rest} <- expect(rest, :rparen) do
          {:ok, {:channel, path}, rest}
        end

      {:error, _} = err ->
        err
    end
  end

  defp parse_destination([{:keyword, _, :service}, {:lparen, _, _} | rest]) do
    case parse_dotted_path_until_rparen(rest) do
      {:ok, path, rest} ->
        with {:ok, rest} <- expect(rest, :rparen) do
          {:ok, {:service, path}, rest}
        end

      {:error, _} = err ->
        err
    end
  end

  defp parse_destination([{:keyword, _, :self} | rest]) do
    {:ok, :self, rest}
  end

  defp parse_destination([{_, meta, _} | _]) do
    {:error, "Expected destination on line #{meta[:line]}"}
  end

  defp parse_destination([]) do
    {:error, "Expected destination but got end of input"}
  end

  defp parse_dotted_path_until_rparen([{:identifier, _, path} | rest]) do
    {:ok, path, rest}
  end

  defp parse_dotted_path_until_rparen([{_, meta, _} | _]) do
    {:error, "Expected dotted path on line #{meta[:line]}"}
  end

  defp parse_dotted_path_until_rparen([]) do
    {:error, "Expected dotted path but got end of input"}
  end

  defp parse_optional_as([{:keyword, _, :as} | rest]) do
    case rest do
      [{:atom, _, name} | rest] ->
        {:ok, name, rest}

      [{:interp_atom, _, name} | rest] ->
        {:ok, name, rest}

      # identifier followed by interp_atom: "ddns.update." + ":{?fqdn}"
      [{:identifier, _, prefix}, {:interp_atom, _, suffix} | rest] ->
        {:ok, "#{prefix}:{#{suffix}}", rest}

      [{:identifier, _, name} | rest] ->
        {:ok, name, rest}

      [{_, meta, _} | _] ->
        {:error, "Expected label after 'as' on line #{meta[:line]}"}

      [] ->
        {:error, "Expected label after 'as' but got end of input"}
    end
  end

  defp parse_optional_as(tokens), do: {:ok, nil, tokens}

  # --- Demand ---

  defp parse_demand([{:identifier, meta, name} | rest]) do
    {flag, rest} =
      case rest do
        [{:demand_flag, _, flag_value} | rest] -> {flag_value, rest}
        _ -> {:requisite, rest}
      end

    {:ok, %AST.Demand{capability: name, flag: flag, line: meta[:line]}, rest}
  end

  defp parse_demand([{_, meta, _} | _]) do
    {:error, "Expected capability name after 'demand' on line #{meta[:line]}"}
  end

  defp parse_demand([]) do
    {:error, "Expected capability name after 'demand' but got end of input"}
  end

  # --- If ---

  defp parse_if(tokens) do
    line = tokens_line(tokens)

    with {:ok, condition, rest} <- parse_expression(tokens) do
      {guard, rest} = parse_optional_guard(rest)

      with {:ok, rest} <- expect(rest, :lbrace),
           {:ok, body, rest} <- parse_statements_until_rbrace(rest, []),
           {:ok, rest} <- expect(rest, :rbrace) do
        {else_body, rest} = parse_optional_else(rest)

        {:ok,
         %AST.If{
           condition: condition,
           guard: guard,
           body: Enum.reverse(body),
           else_body: else_body,
           line: line
         }, rest}
      end
    end
  end

  defp parse_optional_else([{:keyword, _, :else} | rest]) do
    case rest do
      [{:keyword, _, :if} | if_rest] ->
        case parse_if(if_rest) do
          {:ok, if_node, rest} -> {[if_node], rest}
          _ -> {nil, rest}
        end

      [{:lbrace, _, _} | rest] ->
        case parse_statements_until_rbrace(rest, []) do
          {:ok, body, rest} ->
            case expect(rest, :rbrace) do
              {:ok, rest} -> {Enum.reverse(body), rest}
              _ -> {nil, rest}
            end

          _ ->
            {nil, rest}
        end

      _ ->
        {nil, rest}
    end
  end

  defp parse_optional_else([{:keyword, _, :elseif} | rest]) do
    case parse_if(rest) do
      {:ok, if_node, rest} -> {[if_node], rest}
      _ -> {nil, rest}
    end
  end

  defp parse_optional_else(tokens), do: {nil, tokens}

  # --- While ---

  defp parse_while(tokens) do
    line = tokens_line(tokens)

    with {:ok, condition, rest} <- parse_expression(tokens),
         {:ok, rest} <- expect(rest, :lbrace),
         {:ok, body, rest} <- parse_statements_until_rbrace(rest, []),
         {:ok, rest} <- expect(rest, :rbrace) do
      {:ok, %AST.While{condition: condition, body: Enum.reverse(body), line: line}, rest}
    end
  end

  # --- For ---

  defp parse_for(tokens) do
    line = tokens_line(tokens)

    case tokens do
      [{:identifier, _, var}, {:word_operator, _, :in} | rest] ->
        with {:ok, iterable, rest} <- parse_expression(rest),
             {:ok, rest} <- expect(rest, :lbrace),
             {:ok, body, rest} <- parse_statements_until_rbrace(rest, []),
             {:ok, rest} <- expect(rest, :rbrace) do
          {:ok,
           %AST.For{
             var: var,
             iterable: iterable,
             body: Enum.reverse(body),
             keyword: :for,
             line: line
           }, rest}
        end

      [{_, meta, _} | _] ->
        {:error, "Expected 'for <var> in <expr>' on line #{meta[:line]}"}

      [] ->
        {:error, "Expected 'for <var> in <expr>' but got end of input"}
    end
  end

  # --- Each / Every ---

  defp parse_each(tokens) do
    line = tokens_line(tokens)

    case tokens do
      [{:identifier, _, var}, {:word_operator, _, :in} | rest] ->
        with {:ok, iterable, rest} <- parse_expression(rest),
             {:ok, rest} <- expect(rest, :lbrace),
             {:ok, body, rest} <- parse_statements_until_rbrace(rest, []),
             {:ok, rest} <- expect(rest, :rbrace) do
          {:ok,
           %AST.For{
             var: var,
             iterable: iterable,
             body: Enum.reverse(body),
             keyword: :each,
             line: line
           }, rest}
        end

      [{:identifier, _, var}, {:lbrace, _, _} | _] = all ->
        [{:identifier, _, _} | rest] = all

        with {:ok, rest} <- expect(rest, :lbrace),
             {:ok, body, rest} <- parse_statements_until_rbrace(rest, []),
             {:ok, rest} <- expect(rest, :rbrace) do
          {:ok,
           %AST.For{
             var: var,
             iterable: nil,
             body: Enum.reverse(body),
             keyword: :each,
             line: line
           }, rest}
        end

      [{_, meta, _} | _] ->
        {:error, "Expected 'each <var> [in <expr>]' on line #{meta[:line]}"}

      [] ->
        {:error, "Expected 'each <var>' but got end of input"}
    end
  end

  # --- Foreach ---

  defp parse_foreach(tokens) do
    line = tokens_line(tokens)

    case tokens do
      [{:module_id, meta, mod}, {:double_colon, _, _} | rest] ->
        with {:ok, verb, rest} <- parse_command_verb(rest),
             {:ok, rest} <- expect(rest, :lbrace),
             {:ok, body, rest} <- parse_statements_until_rbrace(rest, []),
             {:ok, rest} <- expect(rest, :rbrace) do
          cmd = %AST.Command{module: mod, verb: verb, args: [], line: meta[:line]}

          {:ok,
           %AST.For{
             var: "item",
             iterable: cmd,
             body: Enum.reverse(body),
             keyword: :foreach,
             line: line
           }, rest}
        end

      [{_, meta, _} | _] ->
        {:error, "Expected 'foreach MODULE::verb' on line #{meta[:line]}"}

      [] ->
        {:error, "Expected 'foreach MODULE::verb' but got end of input"}
    end
  end

  # --- Return ---

  defp parse_return([{:rbrace, _, _} | _] = tokens) do
    line = tokens_line(tokens)
    {:ok, %AST.Return{value: nil, line: line}, tokens}
  end

  defp parse_return([{:keyword, _, next_kw} | _] = tokens)
       when next_kw in [
              :when,
              :if,
              :at,
              :let,
              :set,
              :log,
              :emit,
              :demand,
              :return,
              :done,
              :nextevent,
              :nextrule,
              :while,
              :for,
              :each,
              :every,
              :foreach,
              :else,
              :elseif
            ] do
    line = tokens_line(tokens)
    {:ok, %AST.Return{value: nil, line: line}, tokens}
  end

  defp parse_return(tokens) do
    line = tokens_line(tokens)

    case parse_expression(tokens) do
      {:ok, expr, rest} ->
        {:ok, %AST.Return{value: expr, line: line}, rest}

      {:error, _} ->
        {:ok, %AST.Return{value: nil, line: line}, tokens}
    end
  end

  # --- Done ---

  defp parse_done(tokens) do
    line =
      case tokens do
        [{_, meta, _} | _] -> meta[:line]
        [] -> nil
      end

    {:ok, %AST.Done{line: line}, tokens}
  end

  # --- NextEvent ---

  defp parse_nextevent([{type, meta, target} | rest]) when type in [:module_id, :identifier] do
    case parse_optional_with(rest) do
      {:ok, args, rest} ->
        {:ok, %AST.NextEvent{target: target, args: args, line: meta[:line]}, rest}

      {:error, _} = err ->
        err
    end
  end

  defp parse_nextevent([{_, meta, _} | _]) do
    {:error, "Expected event target after 'nextevent' on line #{meta[:line]}"}
  end

  defp parse_nextevent([]) do
    {:error, "Expected event target after 'nextevent' but got end of input"}
  end

  # --- NextRule ---

  defp parse_nextrule([{:identifier, meta, target} | rest]) do
    case parse_optional_with(rest) do
      {:ok, args, rest} ->
        {:ok, %AST.NextRule{target: target, args: args, line: meta[:line]}, rest}

      {:error, _} = err ->
        err
    end
  end

  defp parse_nextrule([{_, meta, _} | _]) do
    {:error, "Expected rule name after 'nextrule' on line #{meta[:line]}"}
  end

  defp parse_nextrule([]) do
    {:error, "Expected rule name after 'nextrule' but got end of input"}
  end

  # `with { key: expr, ... }` — the argument block a `nextrule` or a
  # `nextevent` carries to its target (A-51, A-55). The dispatcher merges the
  # resolved pairs into the target's `:context_data`, so the target reads them
  # as `?key`.
  #
  # Absent `with`, args stay nil and the target sees only the originating
  # event's context. A brace block with no `with` is not an argument list; it
  # belongs to whatever construct follows.
  defp parse_optional_with([{:keyword, _, :with}, {:lbrace, meta, _} | rest]) do
    case parse_block_args(rest, []) do
      {:ok, pairs, rest} ->
        with {:ok, rest} <- expect(rest, :rbrace) do
          {:ok, %AST.BlockArgs{pairs: pairs, line: meta[:line]}, rest}
        end

      {:error, _} = err ->
        err
    end
  end

  defp parse_optional_with([{:keyword, meta, :with} | _]) do
    {:error, "Expected '{' after 'with' on line #{meta[:line]}"}
  end

  defp parse_optional_with(tokens), do: {:ok, nil, tokens}

  # Pairs are `identifier: expression`, separated by an optional comma. A
  # keyword is accepted as a key so a pair named after a construct (`state:`,
  # `to:`) is not a parse error; the key is kept as a binary, never interned.
  defp parse_block_args([{:rbrace, _, _} | _] = tokens, acc) do
    {:ok, Enum.reverse(acc), tokens}
  end

  defp parse_block_args([{:comma, _, _} | rest], acc), do: parse_block_args(rest, acc)

  defp parse_block_args([{key_type, meta, key}, {:colon, _, _} | rest], acc)
       when key_type in [:identifier, :keyword, :module_id] do
    key_string = if is_atom(key), do: Atom.to_string(key), else: key

    case parse_expression(rest) do
      {:ok, value, rest} -> parse_block_args(rest, [{key_string, value} | acc])
      {:error, _} -> {:error, "Expected a value after '#{key_string}:' on line #{meta[:line]}"}
    end
  end

  defp parse_block_args([{_, meta, _} | _], _acc) do
    {:error, "Expected 'key: value' or '}' in a with block on line #{meta[:line]}"}
  end

  defp parse_block_args([], _acc) do
    {:error, "Unterminated with block: expected '}' but got end of input"}
  end

  # --- Command statement (top-level command as statement) ---

  defp parse_command_statement(tokens) do
    parse_bracket_expr(tokens)
  end

  # --- Bracket expressions: commands [MODULE::verb ...] or triple patterns [:s :p :o] ---

  # No `[]` clause and no catch-all, deliberately — the same arrangement as
  # `parse_declaration/1` (A-71) and for the same reason. All three call sites
  # (`parse_statement/1` via `parse_command_statement/1`, `parse_let/1`, and
  # `parse_atom_expression/1`) select this function by matching
  # `[{:lbracket, _, _} | _]` themselves, so the caller has already answered
  # both "is there a token?" and "is it a `[`?". A clause here would answer a
  # question nobody can ask, which is dead code A-71 spent an entry removing.
  defp parse_bracket_expr([{:lbracket, _, _} | rest]) do
    case rest do
      # Command: [MODULE::verb args...]
      [{:module_id, meta, mod}, {:double_colon, _, _} | rest] ->
        with {:ok, verb, rest} <- parse_command_verb(rest),
             {:ok, args, rest} <- parse_command_args(rest, []),
             {:ok, rest} <- expect(rest, :rbracket) do
          {:ok, %AST.Command{module: mod, verb: verb, args: args, line: meta[:line]}, rest}
        end

      # Triple assertion: [:s -> :p -> :o]
      [{type, meta, _}, {:operator, _, :->} | _] = triple_rest when type in [:atom, :query_var] ->
        parse_triple_assertion(triple_rest, meta)

      # Triple query: [:s :p :o] or [?s :p ?o]
      [{type, meta, _} | _] = triple_rest when type in [:atom, :query_var] ->
        parse_triple_query(triple_rest, meta)

      [{_, meta, _} | _] ->
        {:error, "Expected MODULE::verb or triple pattern on line #{meta[:line]}"}

      [] ->
        {:error, "Unexpected end of input in bracket expression"}
    end
  end

  # Triple assertion: subject -> predicate -> object
  defp parse_triple_assertion(tokens, meta) do
    with {:ok, subject, rest} <- parse_triple_element(tokens),
         {:ok, rest} <- expect_operator(rest, :->),
         {:ok, predicate, rest} <- parse_triple_element(rest),
         {:ok, rest} <- expect_operator(rest, :->),
         {:ok, object, rest} <- parse_triple_element(rest),
         {:ok, rest} <- expect(rest, :rbracket) do
      {:ok,
       %AST.Triple{subject: subject, predicate: predicate, object: object, line: meta[:line]},
       rest}
    end
  end

  # Triple query: subject predicate object (space-separated)
  defp parse_triple_query(tokens, meta) do
    with {:ok, subject, rest} <- parse_triple_element(tokens),
         {:ok, predicate, rest} <- parse_triple_element(rest),
         {:ok, object, rest} <- parse_triple_element(rest),
         {:ok, rest} <- expect(rest, :rbracket) do
      {:ok,
       %AST.Triple{subject: subject, predicate: predicate, object: object, line: meta[:line]},
       rest}
    end
  end

  defp parse_triple_element([{:atom, meta, name} | rest]) do
    {:ok, %AST.Literal{type: :atom, value: name, line: meta[:line]}, rest}
  end

  defp parse_triple_element([{:query_var, meta, name} | rest]) do
    {:ok, %AST.VarRef{sigil: "?", name: name, line: meta[:line]}, rest}
  end

  defp parse_triple_element([{:identifier, meta, name} | rest]) do
    {:ok, %AST.Literal{type: :identifier, value: name, line: meta[:line]}, rest}
  end

  defp parse_triple_element([{_type, meta, _} | _]) do
    {:error, "Expected atom, query var, or identifier in triple on line #{meta[:line]}"}
  end

  defp parse_triple_element([]) do
    {:error, "Expected atom, query var, or identifier in triple but got end of input"}
  end

  defp expect_operator([{:operator, _, expected} | rest], expected), do: {:ok, rest}

  defp expect_operator([{_, meta, _} | _], expected) do
    {:error, "Expected #{expected} on line #{meta[:line]}"}
  end

  defp expect_operator([], expected) do
    {:error, "Expected #{expected} but got end of input"}
  end

  # Verb can be a keyword or identifier
  defp parse_command_verb([{:keyword, _, kw} | rest]), do: {:ok, Atom.to_string(kw), rest}
  defp parse_command_verb([{:identifier, _, name} | rest]), do: {:ok, name, rest}

  defp parse_command_verb([{_, meta, _} | _]) do
    {:error, "Expected verb after :: on line #{meta[:line]}"}
  end

  defp parse_command_verb([]) do
    {:error, "Expected verb after :: but got end of input"}
  end

  # Command args: consume expressions until ]
  defp parse_command_args([{:rbracket, _, _} | _] = tokens, acc) do
    {:ok, Enum.reverse(acc), tokens}
  end

  defp parse_command_args(tokens, acc) do
    case parse_atom_expression(tokens) do
      {:ok, expr, rest} -> parse_command_args(rest, [expr | acc])
      {:error, _} = err -> err
    end
  end

  # Parse command args inside parens until )
  defp parse_command_args_until_rparen([{:rparen, _, _} | _] = tokens, acc) do
    {:ok, acc, tokens}
  end

  defp parse_command_args_until_rparen([{:comma, _, _} | rest], acc) do
    parse_command_args_until_rparen(rest, acc)
  end

  defp parse_command_args_until_rparen(tokens, acc) do
    case parse_atom_expression(tokens) do
      {:ok, expr, rest} -> parse_command_args_until_rparen(rest, [expr | acc])
      {:error, _} = err -> err
    end
  end

  # --- Expression parsing (precedence climbing) ---

  defp parse_expression(tokens), do: parse_expr(tokens, 0)

  defp parse_expr(tokens, min_prec) do
    case parse_atom_expression(tokens) do
      {:ok, left, rest} ->
        climb(left, rest, min_prec)

      {:error, _} = err ->
        err
    end
  end

  defp climb(left, [{:keyword, meta, :memberof}, {:lparen, _, _} | rest], min_prec)
       when 1 >= min_prec do
    {names, rest} = collect_memberof_names(rest, [])

    with {:ok, rest} <- expect(rest, :rparen) do
      right = %AST.Literal{type: :list, value: names, line: meta[:line]}
      node = %AST.BinaryOp{op: :memberof, left: left, right: right, line: meta[:line]}
      climb(node, rest, min_prec)
    end
  end

  defp climb(left, tokens, min_prec) do
    case peek_binary_op(tokens) do
      {:ok, op, prec, rest} when prec >= min_prec ->
        case parse_expr(rest, prec + 1) do
          {:ok, right, rest} ->
            node = %AST.BinaryOp{op: op, left: left, right: right, line: node_line(left)}
            climb(node, rest, min_prec)

          {:error, _} = err ->
            err
        end

      _ ->
        {:ok, left, tokens}
    end
  end

  # Peek at the next token to see if it's a binary operator; return {op, precedence, rest}
  defp peek_binary_op([{:word_operator, _, op} | rest]) do
    case Map.fetch(@precedence, op) do
      {:ok, prec} -> {:ok, op, prec, rest}
      :error -> :not_op
    end
  end

  defp peek_binary_op([{:operator, _, op} | rest]) do
    case Map.fetch(@precedence, op) do
      {:ok, prec} -> {:ok, op, prec, rest}
      :error -> :not_op
    end
  end

  # Handle AND/OR/IN as module_ids (uppercase versions)
  defp peek_binary_op([{:module_id, _, "IN"} | rest]), do: {:ok, :in, @precedence[:in], rest}
  defp peek_binary_op([{:module_id, _, "AND"} | rest]), do: {:ok, :and, @precedence[:and], rest}
  defp peek_binary_op([{:module_id, _, "OR"} | rest]), do: {:ok, :or, @precedence[:or], rest}

  defp peek_binary_op([{:keyword, _, :memberof} | _] = tokens) do
    {:ok, :memberof, 1, tokens}
  end

  defp peek_binary_op(_), do: :not_op

  # Atom expressions (non-binary)
  defp parse_atom_expression([{:string, meta, value} | rest]) do
    {:ok, %AST.Literal{type: :string, value: value, line: meta[:line]}, rest}
  end

  defp parse_atom_expression([{:integer, meta, value} | rest]) do
    {:ok, %AST.Literal{type: :integer, value: value, line: meta[:line]}, rest}
  end

  defp parse_atom_expression([{:float, meta, value} | rest]) do
    {:ok, %AST.Literal{type: :float, value: value, line: meta[:line]}, rest}
  end

  defp parse_atom_expression([{:boolean, meta, value} | rest]) do
    {:ok, %AST.Literal{type: :boolean, value: value, line: meta[:line]}, rest}
  end

  defp parse_atom_expression([{:mutable_ref, meta, name} | rest]) do
    {:ok, %AST.VarRef{sigil: "$", name: name, line: meta[:line]}, rest}
  end

  defp parse_atom_expression([{:immutable_ref, meta, name} | rest]) do
    {:ok, %AST.VarRef{sigil: "@", name: name, line: meta[:line]}, rest}
  end

  defp parse_atom_expression([{:query_var, meta, name} | rest]) do
    {:ok, %AST.VarRef{sigil: "?", name: name, line: meta[:line]}, rest}
  end

  defp parse_atom_expression([{:atom, meta, name} | rest]) do
    {:ok, %AST.Literal{type: :atom, value: name, line: meta[:line]}, rest}
  end

  defp parse_atom_expression([{:interp_atom, meta, name} | rest]) do
    {:ok, %AST.Literal{type: :interp_atom, value: name, line: meta[:line]}, rest}
  end

  defp parse_atom_expression([{:identifier, meta, name} | rest]) do
    {:ok, %AST.Literal{type: :identifier, value: name, line: meta[:line]}, rest}
  end

  # MODULE::name qualified reference in expressions
  defp parse_atom_expression([
         {:module_id, meta, mod},
         {:double_colon, _, _},
         {:identifier, _, name} | rest
       ]) do
    {:ok, %AST.Literal{type: :identifier, value: "#{mod}::#{name}", line: meta[:line]}, rest}
  end

  defp parse_atom_expression([{:module_id, meta, name} | rest]) do
    {:ok, %AST.Literal{type: :identifier, value: name, line: meta[:line]}, rest}
  end

  # `exists X` as a value: a bound variable, or a bound module. One operand,
  # so `exists ?x == true` reads as `(exists ?x) == true`.
  defp parse_atom_expression([{:keyword, meta, :exists}, {:module_id, _, name} | rest]) do
    {:ok, %AST.Introspect{verb: :exists, subject: {:name, name}, line: meta[:line]}, rest}
  end

  defp parse_atom_expression([{:keyword, meta, :exists} | rest]) do
    case parse_atom_expression(rest) do
      {:ok, expr, rest} ->
        {:ok, %AST.Introspect{verb: :exists, subject: {:expr, expr}, line: meta[:line]}, rest}

      {:error, _} = err ->
        err
    end
  end

  # --- Built-in pipeline functions ---

  defp parse_atom_expression([{:keyword, meta, :filter}, {:query_var, _, var_name} | rest]) do
    case parse_atom_expression(rest) do
      {:ok, predicate, rest} ->
        {:ok, %AST.BuiltinCall{name: :filter, args: [var_name, predicate], line: meta[:line]},
         rest}

      {:error, _} = err ->
        err
    end
  end

  defp parse_atom_expression([{:keyword, meta, :map}, {:query_var, _, var_name} | rest]) do
    case parse_atom_expression(rest) do
      {:ok, transform, rest} ->
        {:ok, %AST.BuiltinCall{name: :map, args: [var_name, transform], line: meta[:line]}, rest}

      {:error, _} = err ->
        err
    end
  end

  defp parse_atom_expression([{:keyword, meta, :reduce}, {:identifier, _, acc_name} | rest]) do
    case parse_atom_expression(rest) do
      {:ok, initial, [{:query_var, _, var_name} | rest2]} ->
        case parse_atom_expression(rest2) do
          {:ok, body, rest3} ->
            {:ok,
             %AST.BuiltinCall{
               name: :reduce,
               args: [acc_name, initial, var_name, body],
               line: meta[:line]
             }, rest3}

          {:error, _} = err ->
            err
        end

      {:ok, _, _} ->
        {:error, "Expected query variable after reduce initial value on line #{meta[:line]}"}

      {:error, _} = err ->
        err
    end
  end

  defp parse_atom_expression([{:keyword, meta, :emit} | rest]) do
    case parse_atom_expression(rest) do
      {:ok, command, rest} ->
        {:ok, %AST.BuiltinCall{name: :emit, args: [command], line: meta[:line]}, rest}

      {:error, _} = err ->
        err
    end
  end

  defp parse_atom_expression([{:keyword, meta, kw} | rest]) do
    {:ok, %AST.Literal{type: :keyword, value: Atom.to_string(kw), line: meta[:line]}, rest}
  end

  defp parse_atom_expression([{:lbracket, _, _} | _] = tokens) do
    parse_bracket_expr(tokens)
  end

  # Parenthesized expression — try full expression first, fall back to multi-element list
  defp parse_atom_expression([{:lparen, meta, _} | rest]) do
    case parse_expression(rest) do
      {:ok, expr, [{:rparen, _, _} | _] = rest} ->
        with {:ok, rest} <- expect(rest, :rparen) do
          {:ok, expr, rest}
        end

      _ ->
        # Fall back: collect atoms until rparen (for tuple-like constructs)
        case parse_paren_contents(rest, []) do
          {:ok, elements, rest} ->
            with {:ok, rest} <- expect(rest, :rparen) do
              {:ok, paren_expression(elements, meta[:line]), rest}
            end

          {:error, _} = err ->
            err
        end
    end
  end

  defp parse_atom_expression([{:operator, _, :!} | rest]) do
    case parse_atom_expression(rest) do
      {:ok, operand, rest} ->
        {:ok, %AST.UnaryOp{op: :!, operand: operand, line: node_line(operand)}, rest}

      {:error, _} = err ->
        err
    end
  end

  defp parse_atom_expression([{:word_operator, _, :not} | rest]) do
    case parse_atom_expression(rest) do
      {:ok, operand, rest} ->
        {:ok, %AST.UnaryOp{op: :not, operand: operand, line: node_line(operand)}, rest}

      {:error, _} = err ->
        err
    end
  end

  defp parse_atom_expression([{:operator, _, :"~"} | rest]) do
    case parse_atom_expression(rest) do
      {:ok, operand, rest} ->
        {:ok, %AST.UnaryOp{op: :"~", operand: operand, line: node_line(operand)}, rest}

      {:error, _} = err ->
        err
    end
  end

  defp parse_atom_expression([{type, meta, _} | _]) do
    {:error, "Unexpected token #{type} on line #{meta[:line]}, expected expression"}
  end

  defp parse_atom_expression([]) do
    {:error, "Unexpected end of input, expected expression"}
  end

  # `( e )` is a grouping — the parens carry no meaning and the inner
  # expression stands alone. `( a, b, ... )` is a list literal.
  defp paren_expression([single], _line), do: single
  defp paren_expression(multiple, line), do: %AST.ListLiteral{elements: multiple, line: line}

  # --- Data declaration ---

  # data global <name> { ... } — explicit global scope
  # --- Query ---

  # query global <name> { ... }
  defp parse_query([{:keyword, meta, :global}, {name_type, _, name} | rest])
       when name_type in [:identifier, :keyword] do
    name_str = if name_type == :keyword, do: Atom.to_string(name), else: name

    with {:ok, rest} <- expect(rest, :lbrace),
         {:ok, expect_list, engine, body, return_var, rest} <-
           parse_query_body(name_str, :global, meta[:line], rest),
         {:ok, rest} <- expect(rest, :rbrace) do
      {:ok,
       %AST.QueryDecl{
         name: name_str,
         expect: expect_list,
         engine: engine,
         body: body,
         return: return_var,
         scope: :global,
         line: meta[:line]
       }, rest}
    end
  end

  # query <name> { ... } — implicit global scope
  defp parse_query([{:identifier, meta, name} | rest]) do
    with {:ok, rest} <- expect(rest, :lbrace),
         {:ok, expect_list, engine, body, return_var, rest} <-
           parse_query_body(name, :global, meta[:line], rest),
         {:ok, rest} <- expect(rest, :rbrace) do
      {:ok,
       %AST.QueryDecl{
         name: name,
         expect: expect_list,
         engine: engine,
         body: body,
         return: return_var,
         scope: :global,
         line: meta[:line]
       }, rest}
    end
  end

  # Allow keywords as query names
  defp parse_query([{:keyword, meta, kw} | rest]) do
    parse_query([{:identifier, meta, Atom.to_string(kw)} | rest])
  end

  defp parse_query([{_, meta, _} | _]) do
    {:error, "Expected query block name on line #{meta[:line]}"}
  end

  defp parse_query([]) do
    {:error, "Expected query block name but got end of input"}
  end

  # parse_query_body — consumes tokens up to (but not including) the closing rbrace
  # Returns {:ok, expect_list, engine, body, return_var, rest}
  defp parse_query_body(_name, _scope, _line, tokens) do
    {expect_list, tokens} = parse_optional_expect(tokens)

    case parse_engine_block(tokens) do
      {:ok, engine, body, tokens} ->
        case parse_return_stmt(tokens) do
          {:ok, return_var, tokens} ->
            {:ok, expect_list, engine, body, return_var, tokens}

          {:error, _} = err ->
            err
        end

      {:error, _} = err ->
        err
    end
  end

  # parse_optional_expect — consume `expect :atom1, :atom2, ...` if present
  defp parse_optional_expect([{:keyword, _, :expect} | rest]) do
    collect_atom_list(rest)
  end

  defp parse_optional_expect(tokens), do: {[], tokens}

  # collect_atom_list — gather comma-separated `expect` names.
  #
  # These names are open-ended: a policy may expect any binding it likes, so
  # there is no closed set to validate against and no safe atom to produce.
  # Names are kept as binaries. Nothing downstream dispatches on them — the
  # compiler copies the list into %Anemos.CompiledQuery{} verbatim — so this is
  # a representation change only.
  defp collect_atom_list([{:atom, _, val} | rest]) do
    case rest do
      [{:comma, _, _} | rest2] ->
        {more, rest2} = collect_atom_list(rest2)
        {[val | more], rest2}

      _ ->
        {[val], rest}
    end
  end

  defp collect_atom_list(tokens), do: {[], tokens}

  # parse_engine_block — identifier `{` raw-content `}`
  defp parse_engine_block([{:identifier, _, engine_name}, {:lbrace, _, _} | rest]) do
    {raw, rest} = collect_raw_content(rest, 1, [])
    {:ok, engine_name, raw, rest}
  end

  defp parse_engine_block([{_, meta, _} | _]) do
    {:error, "Expected engine identifier in query block on line #{meta[:line]}"}
  end

  defp parse_engine_block([]) do
    {:error, "Expected engine block but got end of input"}
  end

  # parse_return_stmt — `return ?var`
  defp parse_return_stmt([{:keyword, _, :return}, {:query_var, _, var_name} | rest]) do
    {:ok, var_name, rest}
  end

  defp parse_return_stmt([{_, meta, _} | _]) do
    {:error, "Expected 'return ?var' in query block on line #{meta[:line]}"}
  end

  defp parse_return_stmt([]) do
    {:error, "Expected 'return ?var' but got end of input"}
  end

  defp parse_data([{:keyword, meta, :global}, {name_type, _, name} | rest])
       when name_type in [:identifier, :keyword] do
    name_str = if name_type == :keyword, do: Atom.to_string(name), else: name

    with {:ok, rest} <- expect(rest, :lbrace),
         {:ok, source, content, transclude, rest} <- parse_data_body(rest),
         {:ok, rest} <- expect(rest, :rbrace) do
      {:ok,
       %AST.DataDecl{
         name: name_str,
         source: source,
         content: content,
         transclude: transclude,
         scope: :global,
         line: meta[:line]
       }, rest}
    end
  end

  # data <name> { ... } — implicit global scope
  defp parse_data([{:identifier, meta, name} | rest]) do
    with {:ok, rest} <- expect(rest, :lbrace),
         {:ok, source, content, transclude, rest} <- parse_data_body(rest),
         {:ok, rest} <- expect(rest, :rbrace) do
      {:ok,
       %AST.DataDecl{
         name: name,
         source: source,
         content: content,
         transclude: transclude,
         scope: :global,
         line: meta[:line]
       }, rest}
    end
  end

  # Allow keywords as data names
  defp parse_data([{:keyword, meta, kw} | rest]) do
    parse_data([{:identifier, meta, Atom.to_string(kw)} | rest])
  end

  defp parse_data([{_, meta, _} | _]) do
    {:error, "Expected data block name on line #{meta[:line]}"}
  end

  defp parse_data([]) do
    {:error, "Expected data block name but got end of input"}
  end

  # parse_data_body: consumes tokens up to (but not including) the closing rbrace
  # Returns {:ok, source, content, transclude, rest}
  defp parse_data_body(tokens) do
    # Check for optional `source <dotted-identifier>`
    {source, tokens} =
      case tokens do
        [{:keyword, _, :source}, {:identifier, _, path} | rest] -> {path, rest}
        _ -> {nil, tokens}
      end

    # Detect content type
    {content, tokens} =
      case tokens do
        # dynamic block
        [{:keyword, _, :dynamic} | rest] ->
          case parse_dynamic_block(rest) do
            {:ok, dynamic, rest} -> {dynamic, rest}
            {:error, _} = err -> throw(err)
          end

        # format block: identifier followed by lbrace
        [{:identifier, _, _fmt_kw}, {:lbrace, _, _} | _] ->
          case parse_format_block(tokens) do
            {:ok, fmt, rest} -> {fmt, rest}
            {:error, _} = err -> throw(err)
          end

        # fallback: simple list
        _ ->
          {values, tokens} = collect_simple_list(tokens, [])
          {{:simple_list, Enum.reverse(values)}, tokens}
      end

    # Optional transclude clause
    {transclude, tokens} = parse_optional_transclude(tokens)

    {:ok, source, content, transclude, tokens}
  catch
    {:error, _} = err -> err
  end

  # --- Format block ---

  defp parse_format_block([{:identifier, _, fmt_kw}, {:lbrace, _, _} | rest]) do
    {raw, rest} = collect_raw_content(rest, 1, [])
    {:ok, {:format_block, fmt_kw, raw}, rest}
  end

  # No `[]` clause, and the third of only three places in this file that go
  # without one (see `parse_declaration/1` for the rule). The sole call site
  # selects this function by matching
  # `[{:identifier, _, _fmt_kw}, {:lbrace, _, _} | _]`, so two tokens are
  # already guaranteed. One was added here during the A-75 sweep and Dialyzer
  # immediately reported it unreachable, which is the check working: the rule
  # says who *should* own the end-of-input answer, and Dialyzer says where the
  # caller already gave it.
  defp parse_format_block([{_, meta, _} | _]) do
    {:error, "Expected format block identifier on line #{meta[:line]}"}
  end

  # Brace-depth counting raw content collector.
  # Depth starts at 1 (opening brace already consumed).
  defp collect_raw_content([], _depth, acc) do
    {acc |> Enum.reverse() |> Enum.join(), []}
  end

  defp collect_raw_content([{:rbrace, _, _} | rest], 1, acc) do
    # Depth returns to 0 — done, do NOT include this closing brace
    {acc |> Enum.reverse() |> Enum.join(), rest}
  end

  defp collect_raw_content([{:rbrace, _, _} = tok | rest], depth, acc) do
    collect_raw_content(rest, depth - 1, [token_to_string(tok) | acc])
  end

  defp collect_raw_content([{:lbrace, _, _} = tok | rest], depth, acc) do
    collect_raw_content(rest, depth + 1, [token_to_string(tok) | acc])
  end

  defp collect_raw_content([tok | rest], depth, acc) do
    collect_raw_content(rest, depth, [token_to_string(tok) | acc])
  end

  defp token_to_string({:string, _, val}), do: ~s("#{val}")
  defp token_to_string({:identifier, _, val}), do: " #{val}"
  defp token_to_string({:keyword, _, val}), do: " #{val}"
  defp token_to_string({:integer, _, val}), do: " #{val}"
  defp token_to_string({:float, _, val}), do: " #{val}"
  defp token_to_string({:atom, _, val}), do: ":#{val}"
  defp token_to_string({:lbrace, _, _}), do: " {"
  defp token_to_string({:rbrace, _, _}), do: " }"
  defp token_to_string({:lparen, _, _}), do: "("
  defp token_to_string({:rparen, _, _}), do: ")"
  defp token_to_string({:lbracket, _, _}), do: "["
  defp token_to_string({:rbracket, _, _}), do: "]"
  defp token_to_string({:comma, _, _}), do: ","
  defp token_to_string({:operator, _, op}), do: " #{op}"
  defp token_to_string({:mutable_ref, _, val}), do: "$#{val}"
  defp token_to_string({:immutable_ref, _, val}), do: "@#{val}"
  defp token_to_string({:module_id, _, val}), do: " #{val}"
  defp token_to_string({type, _, val}), do: " #{inspect({type, val})}"

  # --- Dynamic block ---

  defp parse_dynamic_block([{:lbrace, _, _} | rest]) do
    with {:ok, subscribe, rest} <- parse_subscribe(rest),
         {periodic, rest} <- parse_optional_periodic(rest),
         {:ok, rest} <- expect(rest, :rbrace) do
      {:ok, {:dynamic, subscribe, periodic}, rest}
    end
  end

  defp parse_dynamic_block([{_, meta, _} | _]) do
    {:error, "Expected '{' after dynamic on line #{meta[:line]}"}
  end

  defp parse_dynamic_block([]) do
    {:error, "Expected '{' after dynamic but got end of input"}
  end

  defp parse_subscribe([{:keyword, _, :subscribe}, {:identifier, _, protocol} | rest]) do
    {uri, rest} = collect_uri(rest)
    {:ok, {:subscribe, protocol, uri}, rest}
  end

  defp parse_subscribe([{_, meta, _} | _]) do
    {:error, "Expected 'subscribe' in dynamic block on line #{meta[:line]}"}
  end

  defp parse_subscribe([]) do
    {:error, "Expected 'subscribe' in dynamic block but got end of input"}
  end

  # Collect URI tokens: a string literal is the URI directly.
  # Identifiers/other tokens are joined until keyword or rbrace.
  defp collect_uri([{:string, _, val} | rest]), do: {val, rest}

  defp collect_uri(tokens) do
    {parts, rest} = collect_uri_tokens(tokens, [])
    {Enum.join(parts), rest}
  end

  defp collect_uri_tokens([{:keyword, _, _} | _] = tokens, acc), do: {Enum.reverse(acc), tokens}
  defp collect_uri_tokens([{:rbrace, _, _} | _] = tokens, acc), do: {Enum.reverse(acc), tokens}
  defp collect_uri_tokens([], acc), do: {Enum.reverse(acc), []}

  defp collect_uri_tokens([tok | rest], acc) do
    collect_uri_tokens(rest, [token_to_string(tok) |> String.trim() | acc])
  end

  defp parse_optional_periodic([{:keyword, _, :periodic}, {:identifier, _, interval} | rest]) do
    {interval, rest}
  end

  defp parse_optional_periodic(tokens), do: {nil, tokens}

  # --- Transclude clause ---

  # transclude to shape(<dotted-id>) with <dotted-id> as <identifier>
  defp parse_optional_transclude([
         {:keyword, _, :transclude},
         {:keyword, _, :to},
         {:identifier, _, "shape"},
         {:lparen, _, _} | rest
       ]) do
    with {shape, [{:rparen, _, _} | rest]} <- collect_dotted_identifier(rest),
         {:ok, rest} <- expect(rest, :keyword, :with),
         {transducer, rest} <- collect_dotted_identifier(rest),
         {:ok, rest} <- expect(rest, :keyword, :as),
         {bind_as, rest} <- collect_identifier(rest) do
      {{:transclude, shape, transducer, bind_as}, rest}
    else
      _ -> {nil, [{:keyword, [], :transclude}]}
    end
  end

  defp parse_optional_transclude(tokens), do: {nil, tokens}

  # Collect a dotted identifier (foo.bar.baz) — already tokenized as a single identifier token
  defp collect_dotted_identifier([{:identifier, _, val} | rest]), do: {val, rest}
  defp collect_dotted_identifier([{:keyword, _, val} | rest]), do: {Atom.to_string(val), rest}
  defp collect_dotted_identifier(tokens), do: {"", tokens}

  defp collect_identifier([{:identifier, _, val} | rest]), do: {val, rest}
  defp collect_identifier([{:keyword, _, val} | rest]), do: {Atom.to_string(val), rest}
  defp collect_identifier(tokens), do: {"", tokens}

  # Collect identifier tokens as list values until rbrace or transclude keyword
  defp collect_simple_list([{:rbrace, _, _} | _] = tokens, acc), do: {acc, tokens}
  defp collect_simple_list([{:keyword, _, :transclude} | _] = tokens, acc), do: {acc, tokens}

  defp collect_simple_list([{:identifier, _, value} | rest], acc) do
    collect_simple_list(rest, [value | acc])
  end

  defp collect_simple_list([{:string, _, value} | rest], acc) do
    collect_simple_list(rest, [value | acc])
  end

  defp collect_simple_list([{:ip_addr, _, value} | rest], acc) do
    collect_simple_list(rest, [value | acc])
  end

  defp collect_simple_list([{:integer, _, value} | rest], acc) do
    collect_simple_list(rest, [to_string(value) | acc])
  end

  defp collect_simple_list([{:float, _, value} | rest], acc) do
    collect_simple_list(rest, [to_string(value) | acc])
  end

  # Skip keyword tokens that are not structural (e.g., bare keyword values in list)
  defp collect_simple_list([{:keyword, _, kw} | rest], acc) do
    collect_simple_list(rest, [Atom.to_string(kw) | acc])
  end

  # A-75. Anything that cannot be a list value ends the list, including no
  # token at all. Stopping is right rather than erroring here: this is a
  # collect-until-terminator loop, and the caller's `expect(rest, :rbrace)`
  # already reports the offending token with its line. Erroring here would
  # duplicate that diagnostic and lose the position.
  defp collect_simple_list(tokens, acc), do: {acc, tokens}

  # --- Capability declaration ---

  # Allow keywords used as capability names
  defp parse_capability([{:keyword, meta, kw} | rest]) do
    parse_capability([{:identifier, meta, Atom.to_string(kw)} | rest])
  end

  defp parse_capability([{:identifier, meta, name} | rest]) do
    with {:ok, rest} <- expect(rest, :lbrace) do
      # Parse optional context (standalone, no braces)
      {context, rest} =
        case rest do
          [{:keyword, _, :context}, {:identifier, _, path} | rest] -> {path, rest}
          [{:keyword, _, :context}, {:string, _, path} | rest] -> {path, rest}
          _ -> {nil, rest}
        end

      # Parse "on demand { ... }"
      with {:ok, rest} <- expect(rest, :keyword, :on),
           {:ok, rest} <- expect(rest, :keyword, :demand),
           {:ok, rest} <- expect(rest, :lbrace),
           {:ok, body, rest} <- parse_statements_until_rbrace(rest, []),
           {:ok, rest} <- expect(rest, :rbrace),
           {:ok, rest} <- expect(rest, :rbrace) do
        {:ok,
         %AST.Capability{
           name: name,
           context: context,
           body: Enum.reverse(body),
           line: meta[:line]
         }, rest}
      end
    end
  end

  defp parse_capability([{_, meta, _} | _]) do
    {:error, "Expected capability name on line #{meta[:line]}"}
  end

  defp parse_capability([]) do
    {:error, "Expected capability name but got end of input"}
  end

  # --- Condition declaration ---

  # Allow keywords used as condition names
  defp parse_condition_decl([{:keyword, meta, kw} | rest]) do
    parse_condition_decl([{:identifier, meta, Atom.to_string(kw)} | rest])
  end

  defp parse_condition_decl([{:identifier, meta, name} | rest]) do
    with {:ok, rest} <- expect(rest, :lbrace),
         {:ok, body, rest} <- parse_statements_until_rbrace(rest, []),
         {:ok, rest} <- expect(rest, :rbrace) do
      if body == [] do
        {:error, "Condition '#{name}' has empty body on line #{meta[:line]}"}
      else
        {:ok, %AST.Condition{name: name, body: Enum.reverse(body), line: meta[:line]}, rest}
      end
    end
  end

  defp parse_condition_decl([{_, meta, _} | _]) do
    {:error, "Expected condition name on line #{meta[:line]}"}
  end

  defp parse_condition_decl([]) do
    {:error, "Expected condition name but got end of input"}
  end

  # --- Helpers ---

  # Parse contents inside parens — collects expressions until )
  defp parse_paren_contents([{:rparen, _, _} | _] = tokens, acc) do
    {:ok, Enum.reverse(acc), tokens}
  end

  defp parse_paren_contents(tokens, acc) do
    case parse_atom_expression(tokens) do
      {:ok, expr, rest} -> parse_paren_contents(rest, [expr | acc])
      {:error, _} = err -> err
    end
  end

  # --- memberof name list collector ---

  defp collect_memberof_names([{:rparen, _, _} | _] = tokens, acc) do
    {Enum.reverse(acc), tokens}
  end

  defp collect_memberof_names([{:identifier, _, name}, {:comma, _, _} | rest], acc) do
    collect_memberof_names(rest, [name | acc])
  end

  defp collect_memberof_names([{:identifier, _, name} | rest], acc) do
    {Enum.reverse([name | acc]), rest}
  end

  # Handle keyword-as-name (e.g., memberof(global, source))
  defp collect_memberof_names([{:keyword, _, kw}, {:comma, _, _} | rest], acc) do
    collect_memberof_names(rest, [Atom.to_string(kw) | acc])
  end

  defp collect_memberof_names([{:keyword, _, kw} | rest], acc) do
    {Enum.reverse([Atom.to_string(kw) | acc]), rest}
  end

  # A-75. As `collect_simple_list/2`: stop on anything that cannot be a name,
  # end of input included, and let the caller's `expect(rest, :rparen)` name it.
  defp collect_memberof_names(tokens, acc), do: {Enum.reverse(acc), tokens}

  defp expect([{expected, _, _} | rest], expected), do: {:ok, rest}

  defp expect([{got, meta, _} | _], expected) do
    {:error, "Expected #{expected} but got #{got} on line #{meta[:line]}"}
  end

  defp expect([], expected) do
    {:error, "Expected #{expected} but got end of input"}
  end

  defp expect([{type, _, value} | rest], type, value), do: {:ok, rest}

  defp expect([{got, meta, val} | _], expected_type, expected_val) do
    {:error,
     "Expected #{expected_type}:#{expected_val} but got #{got}:#{val} on line #{meta[:line]}"}
  end

  defp expect([], expected_type, expected_val) do
    {:error, "Expected #{expected_type}:#{expected_val} but got end of input"}
  end

  defp token_line({_, meta, _}), do: meta[:line]

  # The line of the next token, or nil when the stream is exhausted.
  #
  # Total on purpose. Callers record the line *before* they know whether the
  # tokens they need are actually there, so `token_line(hd(tokens))` used to
  # raise ArgumentError on truncated input — crashing out of `parse/1` past the
  # `[] -> {:error, "...but got end of input"}` branch that was written to
  # handle exactly that case, and past the `{:error, String.t()}` half of
  # `parse/1`'s contract. A nil line on an input that is about to be rejected
  # costs nothing; the raise cost the caller its error handling.
  defp tokens_line([token | _]), do: token_line(token)
  defp tokens_line([]), do: nil

  defp node_line(%{line: line}), do: line
  defp node_line(_), do: nil
end
