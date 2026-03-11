defmodule Anemos.Parser do
  @moduledoc """
  Recursive descent parser for the Anemos DSL.

  Consumes the token stream from `Anemos.Lexer.tokenize/1` and produces
  an `Anemos.AST.Program` struct.
  """

  alias Anemos.AST

  @comparison_ops [:eq, :ne, :gt, :lt, :ge, :le, :==, :!=, :>, :<, :>=, :<=,
                   :in, :notin, :contains, :starts_with, :ends_with,
                   :matches_glob, :matches_regex]
  @logical_ops [:and, :or, :&&, :||]

  # --- Public API ---

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

  defp parse_declaration([{type, meta, _} | _]) do
    {:error, "Expected declaration (rule, condition, ...) but got #{type} on line #{meta[:line]}"}
  end

  defp parse_declaration([]) do
    {:error, "Unexpected end of input"}
  end

  # --- Rule ---

  defp parse_rule([{:identifier, meta, name} | rest]) do
    with {:ok, rest} <- expect(rest, :lbrace),
         {:ok, body, rest} <- parse_rule_body(rest, []),
         {:ok, rest} <- expect(rest, :rbrace) do
      {:ok, %AST.Rule{name: name, body: Enum.reverse(body), line: meta[:line]}, rest}
    end
  end

  defp parse_rule([{type, meta, _} | _]) do
    {:error, "Expected rule name (identifier) but got #{type} on line #{meta[:line]}"}
  end

  defp parse_rule([]) do
    {:error, "Expected rule name but got end of input"}
  end

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

  defp parse_context([{:identifier, meta, path} | rest]) do
    with {:ok, rest} <- expect(rest, :lbrace),
         {:ok, body, rest} <- parse_context_body(rest, []),
         {:ok, rest} <- expect(rest, :rbrace) do
      {:ok, %AST.Context{path: path, body: Enum.reverse(body), line: meta[:line]}, rest}
    end
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

  defp parse_when([{:module_id, meta, event} | rest]) do
    {duration, rest} = parse_optional_duration(rest)

    with {:ok, rest} <- expect(rest, :lbrace),
         {:ok, body, rest} <- parse_statements_until_rbrace(rest, []),
         {:ok, rest} <- expect(rest, :rbrace) do
      {:ok, %AST.When{event: event, duration: duration, body: Enum.reverse(body), line: meta[:line]}, rest}
    end
  end

  defp parse_when([{_, meta, _} | _]) do
    {:error, "Expected event name after 'when' on line #{meta[:line]}"}
  end

  defp parse_optional_duration([{:keyword, _, :for}, {:duration, _, duration} | rest]) do
    {duration, rest}
  end

  defp parse_optional_duration(tokens), do: {nil, tokens}

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
  defp parse_statement([{:keyword, _, :context} | rest]), do: parse_context(rest)
  defp parse_statement([{:lbracket, _, _} | _] = tokens), do: parse_command_statement(tokens)

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

  defp parse_let([{_, meta, _} | _]) do
    {:error, "Expected 'let <name> = <expr>' on line #{meta[:line]}"}
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

  # --- Emit (stub) ---

  defp parse_emit([{_, meta, _} | _]) do
    {:error, "emit not yet implemented (line #{meta[:line]})"}
  end

  # --- Demand (stub) ---

  defp parse_demand([{_, meta, _} | _]) do
    {:error, "demand not yet implemented (line #{meta[:line]})"}
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

  # --- Command statement (top-level command as statement) ---

  defp parse_command_statement(tokens) do
    parse_command(tokens)
  end

  # --- Command ---
  # [MODULE::verb arg1 arg2 ...]

  defp parse_command([{:lbracket, _, _} | rest]) do
    case rest do
      [{:module_id, meta, mod}, {:double_colon, _, _} | rest] ->
        {verb, rest} = parse_command_verb(rest)

        case parse_command_args(rest, []) do
          {:ok, args, rest} ->
            case expect(rest, :rbracket) do
              {:ok, rest} ->
                {:ok,
                 %AST.Command{module: mod, verb: verb, args: args, line: meta[:line]},
                 rest}

              {:error, _} = err ->
                err
            end

          {:error, _} = err ->
            err
        end

      [{_, meta, _} | _] ->
        {:error, "Expected MODULE::verb in command on line #{meta[:line]}"}

      [] ->
        {:error, "Unexpected end of input in command"}
    end
  end

  # Verb can be a keyword or identifier
  defp parse_command_verb([{:keyword, _, kw} | rest]), do: {Atom.to_string(kw), rest}
  defp parse_command_verb([{:identifier, _, name} | rest]), do: {name, rest}

  defp parse_command_verb([{_, meta, _} | _]) do
    raise "Expected verb after :: on line #{meta[:line]}"
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

  # --- Expression parsing ---
  # Simple: parse an atom, then check for binary op

  defp parse_expression(tokens) do
    case parse_atom_expression(tokens) do
      {:ok, left, rest} ->
        maybe_parse_binary_op(left, rest)

      {:error, _} = err ->
        err
    end
  end

  defp maybe_parse_binary_op(left, [{:word_operator, _, op} | rest]) when op in @comparison_ops or op in @logical_ops do
    case parse_atom_expression(rest) do
      {:ok, right, rest} ->
        node = %AST.BinaryOp{op: op, left: left, right: right, line: node_line(left)}
        maybe_parse_binary_op(node, rest)

      {:error, _} = err ->
        err
    end
  end

  defp maybe_parse_binary_op(left, [{:operator, _, op} | rest]) when op in @comparison_ops or op in @logical_ops do
    case parse_atom_expression(rest) do
      {:ok, right, rest} ->
        node = %AST.BinaryOp{op: op, left: left, right: right, line: node_line(left)}
        maybe_parse_binary_op(node, rest)

      {:error, _} = err ->
        err
    end
  end

  defp maybe_parse_binary_op(left, rest), do: {:ok, left, rest}

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

  defp parse_atom_expression([{:identifier, meta, name} | rest]) do
    {:ok, %AST.Literal{type: :identifier, value: name, line: meta[:line]}, rest}
  end

  defp parse_atom_expression([{:module_id, meta, name} | rest]) do
    {:ok, %AST.Literal{type: :identifier, value: name, line: meta[:line]}, rest}
  end

  defp parse_atom_expression([{:keyword, meta, kw} | rest]) do
    {:ok, %AST.Literal{type: :keyword, value: Atom.to_string(kw), line: meta[:line]}, rest}
  end

  defp parse_atom_expression([{:lbracket, _, _} | _] = tokens) do
    parse_command(tokens)
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

  defp parse_atom_expression([{type, meta, _} | _]) do
    {:error, "Unexpected token #{type} on line #{meta[:line]}, expected expression"}
  end

  defp parse_atom_expression([]) do
    {:error, "Unexpected end of input, expected expression"}
  end

  # --- Condition declaration (stub) ---

  defp parse_condition_decl([{:identifier, meta, name} | rest]) do
    with {:ok, rest} <- expect(rest, :lbrace),
         {:ok, body, rest} <- parse_statements_until_rbrace(rest, []),
         {:ok, rest} <- expect(rest, :rbrace) do
      {:ok, %AST.Condition{name: name, body: Enum.reverse(body), line: meta[:line]}, rest}
    end
  end

  defp parse_condition_decl([{_, meta, _} | _]) do
    {:error, "Expected condition name on line #{meta[:line]}"}
  end

  # --- Helpers ---

  defp expect([{expected, _, _} | rest], expected), do: {:ok, rest}

  defp expect([{got, meta, _} | _], expected) do
    {:error, "Expected #{expected} but got #{got} on line #{meta[:line]}"}
  end

  defp expect([], expected) do
    {:error, "Expected #{expected} but got end of input"}
  end

  defp token_line({_, meta, _}), do: meta[:line]

  defp node_line(%{line: line}), do: line
  defp node_line(_), do: nil
end
