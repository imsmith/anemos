defmodule Anemos.Parser do
  @moduledoc """
  Recursive descent parser for the Anemos DSL.

  Consumes the token stream from `Anemos.Lexer.tokenize/1` and produces
  an `Anemos.AST.Program` struct.
  """

  alias Anemos.AST

  # Operator precedence table (higher number = tighter binding)
  # From spec section 7.1, inverted so higher = tighter
  @precedence %{
    in: 1, notin: 1, contains: 1, starts_with: 1, ends_with: 1, matches_glob: 1, matches_regex: 1,
    ||: 2, or: 2,
    &&: 3, and: 3,
    |: 4,
    ^: 5,
    &: 6,
    ==: 7, !=: 7, ===: 7, !==: 7, eq: 7, ne: 7,
    <: 8, <=: 8, >: 8, >=: 8, lt: 8, le: 8, gt: 8, ge: 8,
    "<<": 9, ">>": 9,
    +: 10, -: 10,
    *: 11, /: 11, %: 11
  }

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
        line = token_line(hd(remaining))
        {:error, "Unexpected token #{inspect(elem(hd(remaining), 0))} on line #{line}"}

      {:error, _} = err ->
        err
    end
  end

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

  defp parse_declaration([{:keyword, _, :rule} | rest]) do
    parse_rule(rest)
  end

  defp parse_declaration([{:keyword, _, :condition} | rest]) do
    parse_condition_decl(rest)
  end

  defp parse_declaration([{:keyword, _, :capability} | rest]) do
    parse_capability(rest)
  end

  defp parse_declaration([{type, meta, _} | _]) do
    {:error, "Expected declaration (rule, condition, ...) but got #{type} on line #{meta[:line]}"}
  end

  defp parse_declaration([]) do
    {:error, "Unexpected end of input"}
  end

  # --- Rule ---

  defp parse_rule([{:identifier, meta, name} | rest]) do
    with {:ok, rest} <- expect(rest, :lbrace),
         {rule_meta, rest} <- parse_rule_metadata(rest, %{}),
         {:ok, body, rest} <- parse_rule_body(rest, []),
         {:ok, rest} <- expect(rest, :rbrace) do
      rule_meta = if rule_meta == %{}, do: nil, else: rule_meta
      {:ok, %AST.Rule{name: name, body: Enum.reverse(body), meta: rule_meta, line: meta[:line]}, rest}
    end
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

    with {:ok, rest} <- expect(rest, :lbrace),
         {:ok, body, rest} <- parse_statements_until_rbrace(rest, []),
         {:ok, rest} <- expect(rest, :rbrace) do
      {:ok,
       %AST.When{event: event, duration: duration, body: Enum.reverse(body), line: meta[:line]},
       rest}
    end
  end

  # Simple module_id event (e.g. SENSOR_MOTION_DETECTED)
  defp parse_when([{:module_id, meta, event} | rest]) do
    {duration, rest} = parse_optional_duration(rest)

    with {:ok, rest} <- expect(rest, :lbrace),
         {:ok, body, rest} <- parse_statements_until_rbrace(rest, []),
         {:ok, rest} <- expect(rest, :rbrace) do
      {:ok,
       %AST.When{event: event, duration: duration, body: Enum.reverse(body), line: meta[:line]},
       rest}
    end
  end

  # Identifier event name (e.g. my.event — used for emit label re-dispatch targets)
  defp parse_when([{:identifier, meta, event} | rest]) do
    {duration, rest} = parse_optional_duration(rest)

    with {:ok, rest} <- expect(rest, :lbrace),
         {:ok, body, rest} <- parse_statements_until_rbrace(rest, []),
         {:ok, rest} <- expect(rest, :rbrace) do
      {:ok,
       %AST.When{event: event, duration: duration, body: Enum.reverse(body), line: meta[:line]},
       rest}
    end
  end

  # Compound event in parens: (EVENT1 OR EVENT2)
  defp parse_when([{:lparen, meta, _} | rest]) do
    case parse_compound_event(rest, []) do
      {:ok, event_expr, rest} ->
        with {:ok, rest} <- expect(rest, :rparen) do
          {duration, rest} = parse_optional_duration(rest)

          with {:ok, rest} <- expect(rest, :lbrace),
               {:ok, body, rest} <- parse_statements_until_rbrace(rest, []),
               {:ok, rest} <- expect(rest, :rbrace) do
            {:ok,
             %AST.When{
               event: event_expr,
               duration: duration,
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

  # --- At ---

  # at interval(duration) { ... }
  defp parse_at([
         {:keyword, meta, :interval},
         {:lparen, _, _},
         {:duration, _, dur},
         {:rparen, _, _} | rest
       ]) do
    with {:ok, rest} <- expect(rest, :lbrace),
         {:ok, body, rest} <- parse_statements_until_rbrace(rest, []),
         {:ok, rest} <- expect(rest, :rbrace) do
      {:ok, %AST.At{time_spec: {:interval, dur}, body: Enum.reverse(body), line: meta[:line]},
       rest}
    end
  end

  # at <time_literal> every <recurrence> { ... }
  defp parse_at([{:time_literal, meta, time}, {:keyword, _, :every} | rest]) do
    {recurrence, rest} = parse_recurrence(rest)

    with {:ok, rest} <- expect(rest, :lbrace),
         {:ok, body, rest} <- parse_statements_until_rbrace(rest, []),
         {:ok, rest} <- expect(rest, :rbrace) do
      {:ok,
       %AST.At{
         time_spec: {:recurring, {:time, time}, recurrence},
         body: Enum.reverse(body),
         line: meta[:line]
       }, rest}
    end
  end

  # at <time_literal> { ... }
  defp parse_at([{:time_literal, meta, time} | rest]) do
    with {:ok, rest} <- expect(rest, :lbrace),
         {:ok, body, rest} <- parse_statements_until_rbrace(rest, []),
         {:ok, rest} <- expect(rest, :rbrace) do
      {:ok, %AST.At{time_spec: {:time, time}, body: Enum.reverse(body), line: meta[:line]}, rest}
    end
  end

  # at DATE_YYYY.MM.DD { ... }
  defp parse_at([{:date_literal, meta, date} | rest]) do
    with {:ok, rest} <- expect(rest, :lbrace),
         {:ok, body, rest} <- parse_statements_until_rbrace(rest, []),
         {:ok, rest} <- expect(rest, :rbrace) do
      {:ok, %AST.At{time_spec: {:date, date}, body: Enum.reverse(body), line: meta[:line]}, rest}
    end
  end

  # at NLD_expression { ... }
  defp parse_at([{:nld_literal, meta, text} | rest]) do
    with {:ok, rest} <- expect(rest, :lbrace),
         {:ok, body, rest} <- parse_statements_until_rbrace(rest, []),
         {:ok, rest} <- expect(rest, :rbrace) do
      {:ok, %AST.At{time_spec: {:nld, text}, body: Enum.reverse(body), line: meta[:line]}, rest}
    end
  end

  # at DAY_weekday { ... }
  defp parse_at([{:day_literal, meta, day} | rest]) do
    with {:ok, rest} <- expect(rest, :lbrace),
         {:ok, body, rest} <- parse_statements_until_rbrace(rest, []),
         {:ok, rest} <- expect(rest, :rbrace) do
      {:ok, %AST.At{time_spec: {:day, day}, body: Enum.reverse(body), line: meta[:line]}, rest}
    end
  end

  defp parse_at([{_, meta, _} | _]) do
    {:error, "Expected time spec after 'at' on line #{meta[:line]}"}
  end

  defp parse_at([]) do
    {:error, "Expected time spec after 'at' but got end of input"}
  end

  # Recurrence: day | weekday | weekend | <day_name_identifier>
  defp parse_recurrence([{:keyword, _, :day} | rest]), do: {:day, rest}

  defp parse_recurrence([{:identifier, _, name} | rest]),
    do: {String.to_atom(name), rest}

  defp parse_recurrence(tokens), do: {:day, tokens}

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

  defp parse_statement([{type, meta, _} | _]) do
    {:error, "Unexpected token #{type} on line #{meta[:line]}, expected statement"}
  end

  defp parse_statement([]) do
    {:error, "Unexpected end of input, expected statement"}
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

  # --- Log ---

  defp parse_log(tokens) do
    line = token_line(hd(tokens))

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
    line = token_line(hd(tokens))

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
    end
  end

  defp parse_destination([{:keyword, _, :service}, {:lparen, _, _} | rest]) do
    case parse_dotted_path_until_rparen(rest) do
      {:ok, path, rest} ->
        with {:ok, rest} <- expect(rest, :rparen) do
          {:ok, {:service, path}, rest}
        end
    end
  end

  defp parse_destination([{:keyword, _, :self} | rest]) do
    {:ok, :self, rest}
  end

  defp parse_destination([{_, meta, _} | _]) do
    {:error, "Expected destination on line #{meta[:line]}"}
  end

  defp parse_dotted_path_until_rparen([{:identifier, _, path} | rest]) do
    {:ok, path, rest}
  end

  defp parse_dotted_path_until_rparen([{_, meta, _} | _]) do
    {:error, "Expected dotted path on line #{meta[:line]}"}
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
    line = token_line(hd(tokens))

    with {:ok, condition, rest} <- parse_expression(tokens),
         {:ok, rest} <- expect(rest, :lbrace),
         {:ok, body, rest} <- parse_statements_until_rbrace(rest, []),
         {:ok, rest} <- expect(rest, :rbrace) do
      {else_body, rest} = parse_optional_else(rest)

      {:ok,
       %AST.If{
         condition: condition,
         body: Enum.reverse(body),
         else_body: else_body,
         line: line
       }, rest}
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
    line = token_line(hd(tokens))

    with {:ok, condition, rest} <- parse_expression(tokens),
         {:ok, rest} <- expect(rest, :lbrace),
         {:ok, body, rest} <- parse_statements_until_rbrace(rest, []),
         {:ok, rest} <- expect(rest, :rbrace) do
      {:ok, %AST.While{condition: condition, body: Enum.reverse(body), line: line}, rest}
    end
  end

  # --- For ---

  defp parse_for(tokens) do
    line = token_line(hd(tokens))

    case tokens do
      [{:identifier, _, var}, {:word_operator, _, :in} | rest] ->
        with {:ok, iterable, rest} <- parse_expression(rest),
             {:ok, rest} <- expect(rest, :lbrace),
             {:ok, body, rest} <- parse_statements_until_rbrace(rest, []),
             {:ok, rest} <- expect(rest, :rbrace) do
          {:ok, %AST.For{var: var, iterable: iterable, body: Enum.reverse(body), keyword: :for, line: line}, rest}
        end

      [{_, meta, _} | _] ->
        {:error, "Expected 'for <var> in <expr>' on line #{meta[:line]}"}

      [] ->
        {:error, "Expected 'for <var> in <expr>' but got end of input"}
    end
  end

  # --- Each / Every ---

  defp parse_each(tokens) do
    line = token_line(hd(tokens))

    case tokens do
      [{:identifier, _, var}, {:word_operator, _, :in} | rest] ->
        with {:ok, iterable, rest} <- parse_expression(rest),
             {:ok, rest} <- expect(rest, :lbrace),
             {:ok, body, rest} <- parse_statements_until_rbrace(rest, []),
             {:ok, rest} <- expect(rest, :rbrace) do
          {:ok, %AST.For{var: var, iterable: iterable, body: Enum.reverse(body), keyword: :each, line: line}, rest}
        end

      [{:identifier, _, var}, {:lbrace, _, _} | _] = all ->
        [{:identifier, _, _} | rest] = all

        with {:ok, rest} <- expect(rest, :lbrace),
             {:ok, body, rest} <- parse_statements_until_rbrace(rest, []),
             {:ok, rest} <- expect(rest, :rbrace) do
          {:ok, %AST.For{var: var, iterable: nil, body: Enum.reverse(body), keyword: :each, line: line}, rest}
        end

      [{_, meta, _} | _] ->
        {:error, "Expected 'each <var> [in <expr>]' on line #{meta[:line]}"}

      [] ->
        {:error, "Expected 'each <var>' but got end of input"}
    end
  end

  # --- Foreach ---

  defp parse_foreach(tokens) do
    line = token_line(hd(tokens))

    case tokens do
      [{:module_id, meta, mod}, {:double_colon, _, _} | rest] ->
        with {:ok, verb, rest} <- parse_command_verb(rest),
             {:ok, rest} <- expect(rest, :lbrace),
             {:ok, body, rest} <- parse_statements_until_rbrace(rest, []),
             {:ok, rest} <- expect(rest, :rbrace) do
          cmd = %AST.Command{module: mod, verb: verb, args: [], line: meta[:line]}
          {:ok, %AST.For{var: "item", iterable: cmd, body: Enum.reverse(body), keyword: :foreach, line: line}, rest}
        end

      [{_, meta, _} | _] ->
        {:error, "Expected 'foreach MODULE::verb' on line #{meta[:line]}"}

      [] ->
        {:error, "Expected 'foreach MODULE::verb' but got end of input"}
    end
  end

  # --- Command statement (top-level command as statement) ---

  defp parse_command_statement(tokens) do
    parse_bracket_expr(tokens)
  end

  # --- Bracket expressions: commands [MODULE::verb ...] or triple patterns [:s :p :o] ---

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
      [{type, meta, _}, {:operator, _, :"->"} | _] = triple_rest when type in [:atom, :query_var] ->
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
         {:ok, rest} <- expect_operator(rest, :"->"),
         {:ok, predicate, rest} <- parse_triple_element(rest),
         {:ok, rest} <- expect_operator(rest, :"->"),
         {:ok, object, rest} <- parse_triple_element(rest),
         {:ok, rest} <- expect(rest, :rbracket) do
      {:ok, %AST.Triple{subject: subject, predicate: predicate, object: object, line: meta[:line]}, rest}
    end
  end

  # Triple query: subject predicate object (space-separated)
  defp parse_triple_query(tokens, meta) do
    with {:ok, subject, rest} <- parse_triple_element(tokens),
         {:ok, predicate, rest} <- parse_triple_element(rest),
         {:ok, object, rest} <- parse_triple_element(rest),
         {:ok, rest} <- expect(rest, :rbracket) do
      {:ok, %AST.Triple{subject: subject, predicate: predicate, object: object, line: meta[:line]}, rest}
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

  defp expect_operator([{:operator, _, expected} | rest], expected), do: {:ok, rest}

  defp expect_operator([{_, meta, _} | _], expected) do
    {:error, "Expected #{expected} on line #{meta[:line]}"}
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
              expr =
                case elements do
                  [single] -> single
                  multiple -> %AST.ListLiteral{elements: multiple, line: meta[:line]}
                end

              {:ok, expr, rest}
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

  # --- Capability declaration ---

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

  # --- Condition declaration ---

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

  defp node_line(%{line: line}), do: line
  defp node_line(_), do: nil
end
