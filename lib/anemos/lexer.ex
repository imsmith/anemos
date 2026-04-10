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
    service self interval
  )a

  @word_operators ~w(
    eq ne gt lt ge le and or not in notin contains starts_with ends_with
    matches_glob matches_regex
  )a

  @duration_units ~w(ms s min h d days minutes seconds hours)

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

  # TIME_HHMM prefixed time (e.g. TIME_1300)
  time_prefix =
    string("TIME_")
    |> ascii_string([?0..?9], 4)
    |> tag(:time_prefix_raw)
    |> label("TIME_ prefix")

  # DATE_YYYY.MM.DD prefixed date
  date_prefix =
    string("DATE_")
    |> ascii_string([?0..?9], 4)
    |> ignore(string("."))
    |> ascii_string([?0..?9], 2)
    |> ignore(string("."))
    |> ascii_string([?0..?9], 2)
    |> tag(:date_prefix_raw)
    |> label("DATE_ prefix")

  # DAY_weekday
  day_prefix =
    string("DAY_")
    |> ascii_string([?a..?z], min: 1)
    |> tag(:day_prefix_raw)
    |> label("DAY_ prefix")

  # HH:MM time literal — two digits, colon, two digits
  time_literal =
    ascii_string([?0..?9], 2)
    |> ignore(string(":"))
    |> ascii_string([?0..?9], 2)
    |> tag(:time_literal_raw)
    |> label("time literal")

  # Module ID / Event ID: starts with uppercase, all-caps body with optional lowercase tail.
  # Matches: DEVICE, SENSOR_MOTION_DETECTED, CONDITION_networkchanged
  #
  # Structure: UPPER (UPPER|DIGIT)* (_ (UPPER|DIGIT)+)* (_ lowercase (lower|digit|_|-)*)?
  #
  # This ensures a lowercase tail only appears after an explicit underscore separator,
  # and never fuses a bare uppercase word with adjacent lowercase letters (e.g. DEVICEfoo
  # produces module_id "DEVICE" + identifier "foo", not "DEVICEfoo").
  module_id_caps_segment =
    ascii_char([?_])
    |> ascii_char([?A..?Z, ?0..?9])
    |> repeat(ascii_char([?A..?Z, ?0..?9]))

  module_id_lower_tail =
    ascii_char([?_])
    |> ascii_char([?a..?z])
    |> repeat(ascii_char([?a..?z, ?0..?9, ?_, ?-]))

  module_id =
    ascii_char([?A..?Z])
    |> repeat(ascii_char([?A..?Z, ?0..?9]))
    |> repeat(module_id_caps_segment)
    |> optional(module_id_lower_tail)
    |> reduce({List, :to_string, []})
    |> tag(:module_id_raw)
    |> label("module ID")

  # Demand flags: --required, --optional, --sufficient, --requisite
  demand_flag =
    string("--")
    |> choice([
      string("required"),
      string("optional"),
      string("sufficient"),
      string("requisite")
    ])
    |> tag(:demand_flag_raw)
    |> label("demand flag")

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

  # Interpolated atom: :{expr} with optional dotted suffix
  interp_atom =
    ignore(string(":{"))
    |> repeat(lookahead_not(ascii_char([?}])) |> utf8_char([]))
    |> ignore(ascii_char([?}]))
    |> reduce({List, :to_string, []})
    |> optional(
      ascii_char([?.])
      |> repeat(ascii_char([?a..?z, ?A..?Z, ?0..?9, ?_, ?.]))
      |> reduce({List, :to_string, []})
    )
    |> tag(:interp_atom_raw)
    |> label("interpolated atom")

  atom_literal =
    ignore(ascii_char([?:]))
    |> ascii_char([?a..?z, ?A..?Z, ?_])
    |> repeat(ascii_char([?a..?z, ?A..?Z, ?0..?9, ?_, ?.]))
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
      string("<<") |> replace(:"<<"),
      string(">>") |> replace(:">>"),
      string("++") |> replace(:++),
      string("::") |> replace(:"::"),
      string("~&") |> replace(:"~&"),
      string("~|") |> replace(:"~|"),
      string("~") |> replace(:"~"),
      string("=") |> replace(:=),
      string(">") |> replace(:>),
      string("<") |> replace(:<),
      string("+") |> replace(:+),
      string("-") |> replace(:-),
      string("*") |> replace(:*),
      string("/") |> replace(:/),
      string("%") |> replace(:%),
      string("^") |> replace(:^),
      string("&") |> replace(:&),
      string("|") |> replace(:|),
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
      interp_atom,
      atom_literal,
      query_var,
      date_prefix,
      time_prefix,
      day_prefix,
      time_literal,
      duration,
      float_literal,
      module_id,
      integer_literal,
      demand_flag,
      operators,
      delimiters,
      identifier
    ])

  defparsec(:raw_tokens, repeat(token) |> eos(), inline: true)

  @doc """
  Tokenize the given input string.

  Returns `{:ok, tokens}` or `{:error, message, line, col}`.

  ## Examples

      iex> {:ok, tokens} = Anemos.Lexer.tokenize("rule test { }")
      iex> Enum.map(tokens, &elem(&1, 0))
      [:keyword, :identifier, :lbrace, :rbrace]

      iex> {:ok, tokens} = Anemos.Lexer.tokenize("when EVENT for 5min { }")
      iex> Enum.map(tokens, &elem(&1, 0))
      [:keyword, :module_id, :keyword, :duration, :lbrace, :rbrace]

      iex> {:error, _, _, _} = Anemos.Lexer.tokenize("@@@")
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

  # Time literal HH:MM
  defp build_tokens([{:time_literal_raw, [hour_str, min_str]} | rest], line, acc) do
    hour = String.to_integer(hour_str)
    minute = String.to_integer(min_str)
    build_tokens(rest, line, [{:time_literal, [line: line], {hour, minute}} | acc])
  end

  # TIME_HHMM prefixed time
  defp build_tokens([{:time_prefix_raw, [_, hhmm]} | rest], line, acc) do
    {hour, _} = Integer.parse(String.slice(hhmm, 0, 2))
    {minute, _} = Integer.parse(String.slice(hhmm, 2, 2))
    build_tokens(rest, line, [{:time_literal, [line: line], {hour, minute}} | acc])
  end

  # DATE_YYYY.MM.DD prefixed date
  defp build_tokens([{:date_prefix_raw, [_, year_str, month_str, day_str]} | rest], line, acc) do
    year = String.to_integer(year_str)
    month = String.to_integer(month_str)
    day = String.to_integer(day_str)
    build_tokens(rest, line, [{:date_literal, [line: line], {year, month, day}} | acc])
  end

  # DAY_weekday prefixed day
  defp build_tokens([{:day_prefix_raw, [_, day_name]} | rest], line, acc) do
    build_tokens(rest, line, [{:day_literal, [line: line], String.to_atom(day_name)} | acc])
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

  # Demand flag
  defp build_tokens([{:demand_flag_raw, [_, value]} | rest], line, acc) do
    build_tokens(rest, line, [{:demand_flag, [line: line], String.to_atom(value)} | acc])
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

  defp build_tokens([{:interp_atom_raw, [expr]} | rest], line, acc) do
    build_tokens(rest, line, [{:interp_atom, [line: line], expr} | acc])
  end

  defp build_tokens([{:interp_atom_raw, [expr, suffix]} | rest], line, acc) do
    build_tokens(rest, line, [{:interp_atom, [line: line], expr <> suffix} | acc])
  end

  defp build_tokens([{:query_var_raw, [value]} | rest], line, acc) do
    build_tokens(rest, line, [{:query_var, [line: line], value} | acc])
  end

  # Operator — special-case :: to :double_colon
  defp build_tokens([{:operator_raw, [:"::"]} | rest], line, acc) do
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
