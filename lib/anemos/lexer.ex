defmodule Anemos.Lexer do
  @moduledoc """
  NimbleParsec-based tokenizer for the Anemos DSL.

  Produces a flat list of `{type, metadata, value}` tuples.
  """

  import NimbleParsec

  @keywords ~w(
    rule when if at on it let set emit demand condition capability flow context
    else elseif while for each every foreach do return done nextevent nextrule
    log show list graph trace explain exists infer assert unless until as with
    by that import export version signed_by scope state effect stream to channel
    service self
  )a

  @word_operators ~w(
    eq ne gt lt ge le and or not in notin contains starts_with ends_with
    matches_glob matches_regex
  )a

  @duration_units ~w(s min h d days minutes seconds hours)

  # --- Primitives ---

  whitespace =
    ascii_string([?\s, ?\t, ?\r], min: 1)
    |> label("whitespace")

  newline =
    string("\n")
    |> label("newline")

  comment =
    choice([string(";"), string("#")])
    |> repeat(lookahead_not(ascii_char([?\n])) |> utf8_char([]))
    |> label("comment")

  # String literal: double-quoted, with basic escape support
  string_literal =
    ignore(ascii_char([?"]))
    |> repeat(
      choice([
        string("\\\"") |> replace(?"),
        string("\\\\") |> replace(?\\),
        string("\\n") |> replace(?\n),
        string("\\t") |> replace(?\t),
        utf8_char([{:not, ?"}])
      ])
    )
    |> ignore(ascii_char([?"]))
    |> reduce({List, :to_string, []})
    |> tag(:string_literal)
    |> label("string literal")

  # Duration: integer followed by a unit suffix (must come before plain integer)
  duration =
    integer(min: 1)
    |> choice(Enum.map(@duration_units, &string/1))
    |> tag(:duration_raw)
    |> label("duration")

  # Float: digits.digits
  float_literal =
    integer(min: 1)
    |> ignore(ascii_char([?.]))
    |> integer(min: 1)
    |> tag(:float_raw)
    |> label("float")

  # Integer
  integer_literal =
    integer(min: 1)
    |> tag(:integer_raw)
    |> label("integer")

  # Module ID / Event ID: 2+ uppercase letters/digits/underscores, starts with uppercase
  module_id =
    ascii_char([?A..?Z])
    |> repeat(ascii_char([?A..?Z, ?0..?9, ?_]))
    |> reduce({List, :to_string, []})
    |> tag(:module_id_raw)
    |> label("module ID")

  # Identifier: starts with lowercase letter, can contain letters, digits, hyphens, underscores, dots
  identifier =
    ascii_char([?a..?z])
    |> repeat(ascii_char([?a..?z, ?A..?Z, ?0..?9, ?-, ?_, ?.]))
    |> reduce({List, :to_string, []})
    |> tag(:identifier_raw)
    |> label("identifier")

  # Sigils
  mutable_ref =
    ignore(ascii_char([?$]))
    |> ascii_char([?a..?z, ?A..?Z, ?_])
    |> repeat(ascii_char([?a..?z, ?A..?Z, ?0..?9, ?_]))
    |> reduce({List, :to_string, []})
    |> tag(:mutable_ref_raw)
    |> label("mutable ref")

  immutable_ref =
    ignore(ascii_char([?@]))
    |> ascii_char([?a..?z, ?A..?Z, ?_])
    |> repeat(ascii_char([?a..?z, ?A..?Z, ?0..?9, ?_]))
    |> reduce({List, :to_string, []})
    |> tag(:immutable_ref_raw)
    |> label("immutable ref")

  atom_literal =
    ignore(ascii_char([?:]))
    |> ascii_char([?a..?z, ?A..?Z, ?_])
    |> repeat(ascii_char([?a..?z, ?A..?Z, ?0..?9, ?_]))
    |> reduce({List, :to_string, []})
    |> tag(:atom_raw)
    |> label("atom")

  query_var =
    ignore(ascii_char([??]))
    |> ascii_char([?a..?z, ?A..?Z, ?_])
    |> repeat(ascii_char([?a..?z, ?A..?Z, ?0..?9, ?_]))
    |> reduce({List, :to_string, []})
    |> tag(:query_var_raw)
    |> label("query var")

  # Multi-char operators (ordered longest match first)
  operators =
    choice([
      string("===") |> replace(:===),
      string("!==") |> replace(:!==),
      string("==") |> replace(:==),
      string("!=") |> replace(:!=),
      string("&&") |> replace(:&&),
      string("||") |> replace(:||),
      string("|>") |> replace(:|>),
      string(">=") |> replace(:>=),
      string("<=") |> replace(:<=),
      string("::") |> replace(:"::"),
      string("=") |> replace(:=),
      string(">") |> replace(:>),
      string("<") |> replace(:<),
      string("+") |> replace(:+),
      string("-") |> replace(:-),
      string("*") |> replace(:*),
      string("/") |> replace(:/),
      string("%") |> replace(:%),
      string("!") |> replace(:!)
    ])
    |> tag(:operator_raw)
    |> label("operator")

  # Delimiters
  delimiters =
    choice([
      ascii_char([?{]) |> replace(:lbrace),
      ascii_char([?}]) |> replace(:rbrace),
      ascii_char([?[]) |> replace(:lbracket),
      ascii_char([?]]) |> replace(:rbracket),
      ascii_char([?(]) |> replace(:lparen),
      ascii_char([?)]) |> replace(:rparen),
      ascii_char([?,]) |> replace(:comma)
    ])
    |> tag(:delimiter_raw)
    |> label("delimiter")

  # A single token (order matters — longer/more specific first)
  token =
    choice([
      comment |> tag(:skip),
      newline |> tag(:newline),
      whitespace |> tag(:skip),
      string_literal,
      mutable_ref,
      immutable_ref,
      atom_literal,
      query_var,
      duration,
      float_literal,
      module_id,
      integer_literal,
      operators,
      delimiters,
      identifier
    ])

  defparsec(:raw_tokens, repeat(token) |> eos(), inline: true)

  @doc """
  Tokenize the given input string.

  Returns `{:ok, tokens}` or `{:error, message, line, col}`.
  """
  @spec tokenize(String.t()) :: {:ok, list()} | {:error, String.t(), pos_integer(), pos_integer()}
  def tokenize(input) do
    case raw_tokens(input) do
      {:ok, raw, "", _, _, _} ->
        {:ok, postprocess(raw)}

      {:ok, _raw, rest, _context, {line, _}, col} ->
        {:error, "Unexpected input: #{inspect(String.slice(rest, 0, 20))}", line, col}

      {:error, reason, rest, _context, {line, _}, col} ->
        {:error, "#{reason} near #{inspect(String.slice(rest, 0, 20))}", line, col}
    end
  end

  # --- Post-processing ---

  defp postprocess(raw_tokens) do
    raw_tokens
    |> build_tokens(1, [])
    |> Enum.reverse()
  end

  defp build_tokens([], _line, acc), do: acc

  # Skip whitespace/comments
  defp build_tokens([{:skip, _} | rest], line, acc) do
    build_tokens(rest, line, acc)
  end

  # Track newlines
  defp build_tokens([{:newline, _} | rest], line, acc) do
    build_tokens(rest, line + 1, acc)
  end

  # String literal
  defp build_tokens([{:string_literal, [value]} | rest], line, acc) do
    token = {:string, [line: line], value}
    build_tokens(rest, line, [token | acc])
  end

  # Duration
  defp build_tokens([{:duration_raw, [amount, unit]} | rest], line, acc) do
    token = {:duration, [line: line], {amount, String.to_atom(unit)}}
    build_tokens(rest, line, [token | acc])
  end

  # Float
  defp build_tokens([{:float_raw, [whole, frac]} | rest], line, acc) do
    value = String.to_float("#{whole}.#{frac}")
    token = {:float, [line: line], value}
    build_tokens(rest, line, [token | acc])
  end

  # Integer
  defp build_tokens([{:integer_raw, [value]} | rest], line, acc) do
    token = {:integer, [line: line], value}
    build_tokens(rest, line, [token | acc])
  end

  # Module ID
  defp build_tokens([{:module_id_raw, [value]} | rest], line, acc) do
    token = {:module_id, [line: line], value}
    build_tokens(rest, line, [token | acc])
  end

  # Identifier — check if it's a keyword or word operator
  defp build_tokens([{:identifier_raw, [value]} | rest], line, acc) do
    atom = String.to_atom(value)

    token =
      cond do
        atom in @keywords -> {:keyword, [line: line], atom}
        atom in @word_operators -> {:word_operator, [line: line], atom}
        true -> {:identifier, [line: line], value}
      end

    build_tokens(rest, line, [token | acc])
  end

  # Sigils
  defp build_tokens([{:mutable_ref_raw, [value]} | rest], line, acc) do
    build_tokens(rest, line, [{:mutable_ref, [line: line], value} | acc])
  end

  defp build_tokens([{:immutable_ref_raw, [value]} | rest], line, acc) do
    build_tokens(rest, line, [{:immutable_ref, [line: line], value} | acc])
  end

  defp build_tokens([{:atom_raw, [value]} | rest], line, acc) do
    build_tokens(rest, line, [{:atom, [line: line], value} | acc])
  end

  defp build_tokens([{:query_var_raw, [value]} | rest], line, acc) do
    build_tokens(rest, line, [{:query_var, [line: line], value} | acc])
  end

  # Operator — special-case :: to :double_colon
  defp build_tokens([{:operator_raw, [:"::"] } | rest], line, acc) do
    build_tokens(rest, line, [{:double_colon, [line: line], "::"} | acc])
  end

  defp build_tokens([{:operator_raw, [op]} | rest], line, acc) do
    build_tokens(rest, line, [{:operator, [line: line], op} | acc])
  end

  # Delimiters
  defp build_tokens([{:delimiter_raw, [type]} | rest], line, acc) do
    build_tokens(rest, line, [{type, [line: line], nil} | acc])
  end
end
