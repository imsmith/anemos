defmodule Anemos.Lexer do
  @moduledoc """
  NimbleParsec-based tokenizer for the Anemos DSL.

  Produces a flat list of `{type, metadata, value}` tuples.

  `true` and `false` produce `:boolean` tokens carrying real booleans, not
  identifiers. `Anemos.Compiler`'s moduledoc records what that means for
  `?var == "true"` — the short version is that comparison does not coerce and a
  boolean/boolean-string mismatch warns at evaluation time.
  """

  import NimbleParsec

  @keywords ~w(
    rule when if at on it let set emit demand condition capability flow context
    else elseif while for each every foreach do return done nextevent nextrule
    log show list graph trace explain exists infer assert unless until as with
    by that import export version signed_by scope state effect stream to channel
    service systemd self interval then filter map reduce
    data query source expect transclude dynamic subscribe memberof global
  )a

  @word_operators ~w(
    eq ne gt lt ge le and or not in notin contains starts_with ends_with
    matches_glob matches_regex
  )a

  # Order is significant: the token combinator tries these in sequence, so a
  # shorter unit listed before a longer one wins the prefix.
  @duration_units ~w(ms s min h d days minutes seconds hours)

  @weekdays ~w(monday tuesday wednesday thursday friday saturday sunday)

  @demand_flags ~w(required optional sufficient requisite)

  # Boolean literals. These are not keywords: a keyword token carries an atom
  # naming a construct, whereas `true` and `false` are *values* and must reach
  # the parser already typed. Lexing them as identifiers is A-46 — the parser
  # then built `%AST.Literal{type: :identifier, value: "true"}`, a binary, so
  # `?flag == true` silently compared against the string "true".
  @boolean_literals %{"true" => true, "false" => false}

  # Source text is untrusted: `Anemos.Runtime.load/2` is called at runtime with
  # arbitrary policy. Atoms are never garbage collected, and exhausting the atom
  # table aborts the whole node rather than crashing a supervised process — so no
  # atom may be derived from source text outside a closed, compile-time set.
  #
  # These maps ARE those closed sets. Lookup is by binary; the atom on the value
  # side already exists because the map itself is built at compile time. A miss
  # means the text is not a member, and the caller must treat it as an
  # identifier or a lexer error — never as a new atom.
  @keyword_atoms Map.new(@keywords, &{Atom.to_string(&1), &1})
  @word_operator_atoms Map.new(@word_operators, &{Atom.to_string(&1), &1})
  @duration_unit_atoms Map.new(@duration_units, &{&1, String.to_atom(&1)})
  @weekday_atoms Map.new(@weekdays, &{&1, String.to_atom(&1)})
  @demand_flag_atoms Map.new(@demand_flags, &{&1, String.to_atom(&1)})

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

  # Size: integer followed by a byte unit (spec §2.3). Binary multiples:
  # every use is a file size. Longest unit first so "KB" is not read as "B".
  @size_units [
    {"TB", 1_099_511_627_776},
    {"GB", 1_073_741_824},
    {"MB", 1_048_576},
    {"KB", 1024},
    {"B", 1}
  ]

  size =
    integer(min: 1)
    |> choice(Enum.map(@size_units, fn {u, _} -> string(u) end))
    |> lookahead_not(ascii_char([?a..?z, ?A..?Z, ?0..?9, ?_]))
    |> tag(:size_raw)
    |> label("size")

  # `~s(...)` and `~r/.../flags` (spec §2.5). Any of the usual paired
  # delimiters; the body is taken verbatim up to the closer, no escapes.
  @sigil_delims [{?(, ?)}, {?[, ?]}, {?{, ?}}, {?<, ?>}, {?/, ?/}, {?|, ?|}, {?", ?"}]

  sigil_body =
    choice(
      Enum.map(@sigil_delims, fn {open, close} ->
        ignore(ascii_char([open]))
        |> repeat(lookahead_not(ascii_char([close])) |> utf8_char([]))
        |> ignore(ascii_char([close]))
        |> reduce({List, :to_string, []})
      end)
    )

  sigil_s =
    ignore(string("~s"))
    |> concat(sigil_body)
    |> tag(:sigil_s_raw)
    |> label("~s string")

  sigil_r =
    ignore(string("~r"))
    |> concat(sigil_body)
    |> concat(repeat(ascii_char([?a..?z])) |> reduce({List, :to_string, []}))
    |> tag(:sigil_r_raw)
    |> label("~r regex")

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

  # NLD_<natural-language-date> (e.g. NLD_tomorrow, NLD_next.wednesday)
  nld_prefix =
    string("NLD_")
    |> ascii_string([?a..?z, ?.], min: 1)
    |> tag(:nld_prefix_raw)
    |> label("NLD_ prefix")

  # HH:MM time literal — two digits, colon, two digits
  time_literal =
    ascii_string([?0..?9], 2)
    |> ignore(string(":"))
    |> ascii_string([?0..?9], 2)
    |> tag(:time_literal_raw)
    |> label("time literal")

  # IPv4 address: d{1,3}.d{1,3}.d{1,3}.d{1,3} with optional /d{1,2} CIDR prefix
  ipv4_octet = ascii_string([?0..?9], min: 1, max: 3)

  ipv4_address =
    ipv4_octet
    |> string(".")
    |> concat(ipv4_octet)
    |> string(".")
    |> concat(ipv4_octet)
    |> string(".")
    |> concat(ipv4_octet)
    |> optional(string("/") |> concat(ascii_string([?0..?9], min: 1, max: 2)))
    |> reduce({Enum, :join, [""]})
    |> tag(:ipv4_raw)
    |> label("IPv4 address")

  # IPv6 address: hex groups separated by colons, with :: compression, optional /prefix
  # Disambiguation: IPv6 starts with lowercase hex or ':', module_id starts with uppercase.
  # We match several distinct forms:
  #   1. :: alone or ::digits or ::hex (starts with ::)
  #   2. hex_group: followed by more hex:hex groups (starts with [0-9a-f])

  ipv6_hex_group = ascii_string([?0..?9, ?a..?f, ?A..?F], min: 1, max: 4)
  ipv6_cidr = string("/") |> concat(ascii_string([?0..?9], min: 1, max: 3))

  # Word boundary: IPv6 token must not be followed by identifier-continuation chars.
  # This prevents "::extension" from matching as IPv6 "::e" + identifier "xtension".
  ipv6_boundary = lookahead_not(ascii_char([?a..?z, ?A..?Z, ?0..?9, ?_, ?-]))

  # Form 1: starts with :: (compressed from the left)
  # ::1  or  ::1/128  or  ::ffff:0:0/96  or  ::/0
  # Bare :: without hex digits or CIDR is NOT matched (that's the operator)
  ipv6_double_colon_start =
    string("::")
    |> choice([
      # :: followed by hex digits (e.g., ::1, ::ffff:0:0)
      ipv6_hex_group
      |> repeat(string(":") |> lookahead_not(string(":")) |> concat(ipv6_hex_group))
      |> optional(ipv6_cidr),
      # :: followed by CIDR only (e.g., ::/128, ::/0)
      ipv6_cidr
    ])
    |> concat(ipv6_boundary)
    |> reduce({Enum, :join, [""]})
    |> tag(:ipv6_raw)
    |> label("IPv6 address (:: start)")

  # Form 2: starts with hex group, then colon(s)
  # e.g. 2001:db8::1, fe80::/10, 2001:0db8:0000:...:0001
  # Must have at least one : after first hex group to distinguish from bare hex identifiers
  ipv6_hex_start =
    ascii_string([?0..?9, ?a..?f], min: 1, max: 4)
    |> repeat(ascii_char([?0..?9, ?a..?f, ?A..?F]))
    |> reduce({List, :to_string, []})
    |> string(":")
    |> choice([
      # :: compression after first group(s)
      string(":")
      |> optional(
        ipv6_hex_group
        |> repeat(string(":") |> lookahead_not(string(":")) |> concat(ipv6_hex_group))
      ),
      # regular continuation: hex_group (:hex_group)*
      ipv6_hex_group
      |> repeat(string(":") |> lookahead_not(string(":")) |> concat(ipv6_hex_group))
      |> optional(string("::") |> optional(ipv6_hex_group))
    ])
    |> optional(ipv6_cidr)
    |> concat(ipv6_boundary)
    |> reduce({Enum, :join, [""]})
    |> tag(:ipv6_raw)
    |> label("IPv6 address (hex start)")

  ipv6_address =
    choice([
      ipv6_double_colon_start,
      ipv6_hex_start
    ])

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
    # A-82. `::` written hard against a module name and followed by a
    # lowercase letter is the verb separator, and is taken here so the IPv6
    # rule never sees it: `[M::a]`, `[M::dead]` are verbs whose names happen
    # to be hex. An address after a module-shaped word — `AAAA ::1` — is
    # separated from it by a space and is untouched.
    |> optional(
      string("::")
      |> replace(:"::")
      |> lookahead(ascii_char([?a..?z]))
      |> tag(:operator_raw)
    )

  # Demand flags: --required, --optional, --sufficient, --requisite
  demand_flag =
    string("--")
    |> choice(Enum.map(@demand_flags, &string/1))
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
      string("->") |> replace(:->),
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
      ascii_char([?,]) |> replace(:comma),
      # A bare colon. Every other colon-led form — `:atom`, `:{interp}`, `::`,
      # `HH:MM`, IPv6 — is matched earlier in the `token` choice, so this only
      # fires where none of them do: the `key: value` pairs of a `with` block.
      ascii_char([?:]) |> replace(:colon)
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
      sigil_s,
      sigil_r,
      mutable_ref,
      immutable_ref,
      interp_atom,
      atom_literal,
      query_var,
      date_prefix,
      time_prefix,
      nld_prefix,
      day_prefix,
      time_literal,
      ipv4_address,
      size,
      duration,
      float_literal,
      ipv6_address,
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

  Returns `{:ok, tokens}` or `{:error, %Comn.Errors.ErrorStruct{}}` with code
  `anemos.lexer/invalid_token`, whose `field` is `"line:column"`.

  ## Examples

      iex> {:ok, tokens} = Anemos.Lexer.tokenize("rule test { }")
      iex> Enum.map(tokens, &elem(&1, 0))
      [:keyword, :identifier, :lbrace, :rbrace]

      iex> {:ok, tokens} = Anemos.Lexer.tokenize("when EVENT for 5min { }")
      iex> Enum.map(tokens, &elem(&1, 0))
      [:keyword, :module_id, :keyword, :duration, :lbrace, :rbrace]

      iex> {:error, error} = Anemos.Lexer.tokenize("@@@")
      iex> error.code
      "anemos.lexer/invalid_token"
  """
  @spec tokenize(String.t()) :: {:ok, list()} | {:error, Comn.Errors.ErrorStruct.t()}
  def tokenize(input) do
    case raw_tokens(input) do
      {:ok, raw, "", _, _, _} ->
        # Post-processing rejects members that fall outside a closed set (see
        # @weekday_atoms). Those clauses are buried in a 20-clause fold, so they
        # signal by throw and are caught here — the throw never escapes tokenize/1.
        try do
          {:ok, postprocess(raw)}
        catch
          {:lex_error, msg, line} -> lex_error(msg, line, 1)
        end

      {:ok, _raw, rest, _context, {line, _}, col} ->
        lex_error("Unexpected input: #{inspect(String.slice(rest, 0, 20))}", line, col)

      {:error, reason, rest, _context, {line, _}, col} ->
        lex_error("#{reason} near #{inspect(String.slice(rest, 0, 20))}", line, col)
    end
  end

  defp lex_error(message, line, col) do
    {:error,
     Comn.Errors.Registry.error!("anemos.lexer/invalid_token",
       field: "#{line}:#{col}",
       message: "Lexer error on line #{line}: #{message}"
     )}
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
  defp build_tokens([{:size_raw, [amount, unit]} | rest], line, acc) do
    {_, mult} = List.keyfind!(@size_units, unit, 0)
    build_tokens(rest, line, [{:size, [line: line], amount * mult} | acc])
  end

  defp build_tokens([{:sigil_s_raw, [value]} | rest], line, acc) do
    build_tokens(rest, line, [{:string, [line: line], value} | acc])
  end

  defp build_tokens([{:sigil_r_raw, [pattern, flags]} | rest], line, acc) do
    build_tokens(rest, line, [{:regex, [line: line], {pattern, flags}} | acc])
  end

  defp build_tokens([{:duration_raw, [amount, unit]} | rest], line, acc) do
    # The combinator only ever emits a member of @duration_units, so a miss here
    # is a broken invariant in this module, not bad input.
    token = {:duration, [line: line], {amount, Map.fetch!(@duration_unit_atoms, unit)}}
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

  # NLD_ natural language date
  defp build_tokens([{:nld_prefix_raw, [_, text]} | rest], line, acc) do
    build_tokens(rest, line, [{:nld_literal, [line: line], text} | acc])
  end

  # DAY_weekday prefixed day. The combinator accepts any lowercase run, but only
  # the seven weekdays are meaningful downstream (Scheduler.day_to_number/1), so
  # anything else is rejected here rather than interned and crashed on later.
  defp build_tokens([{:day_prefix_raw, [_, day_name]} | rest], line, acc) do
    case Map.fetch(@weekday_atoms, day_name) do
      {:ok, day} ->
        build_tokens(rest, line, [{:day_literal, [line: line], day} | acc])

      :error ->
        throw({:lex_error, "Unknown day name #{inspect(day_name)} in DAY_ literal", line})
    end
  end

  # IPv4 address
  defp build_tokens([{:ipv4_raw, [value]} | rest], line, acc) do
    build_tokens(rest, line, [{:ip_addr, [line: line], value} | acc])
  end

  # IPv6 address
  defp build_tokens([{:ipv6_raw, [value]} | rest], line, acc) do
    build_tokens(rest, line, [{:ip_addr, [line: line], value} | acc])
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
    # Combinator-bounded to @demand_flags; a miss is a broken module invariant.
    flag = Map.fetch!(@demand_flag_atoms, value)
    build_tokens(rest, line, [{:demand_flag, [line: line], flag} | acc])
  end

  # Identifier — check if it's a keyword or word operator.
  #
  # The membership test is on the BINARY. Converting first and testing second
  # would intern every identifier in the source as a side effect of the test,
  # which is precisely the unbounded-atom hazard. An identifier that matches
  # nothing stays a binary and never reaches the atom table.
  defp build_tokens([{:identifier_raw, [value]} | rest], line, acc) do
    token =
      case Map.fetch(@boolean_literals, value) do
        {:ok, bool} ->
          {:boolean, [line: line], bool}

        :error ->
          case Map.fetch(@keyword_atoms, value) do
            {:ok, keyword} ->
              {:keyword, [line: line], keyword}

            :error ->
              case Map.fetch(@word_operator_atoms, value) do
                {:ok, operator} -> {:word_operator, [line: line], operator}
                :error -> {:identifier, [line: line], value}
              end
          end
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

  # `:{expr}` and its optional dotted suffix stay separate: concatenating them
  # made `:{?host}.ip` indistinguishable from `:{?host.ip}` by the parser.
  defp build_tokens([{:interp_atom_raw, [expr]} | rest], line, acc) do
    build_tokens(rest, line, [{:interp_atom, [line: line], {expr, ""}} | acc])
  end

  defp build_tokens([{:interp_atom_raw, [expr, suffix]} | rest], line, acc) do
    build_tokens(rest, line, [{:interp_atom, [line: line], {expr, suffix}} | acc])
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
