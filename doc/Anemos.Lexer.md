# `Anemos.Lexer`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/lexer.ex#L1)

NimbleParsec-based tokenizer for the Anemos DSL.

Produces a flat list of `{type, metadata, value}` tuples.

`true` and `false` produce `:boolean` tokens carrying real booleans, not
identifiers. `Anemos.Compiler`'s moduledoc records what that means for
`?var == "true"` — the short version is that comparison does not coerce and a
boolean/boolean-string mismatch warns at evaluation time.

# `raw_tokens`

```elixir
@spec raw_tokens(binary(), keyword()) ::
  {:ok, [term()], rest, context, line, byte_offset}
  | {:error, reason, rest, context, line, byte_offset}
when line: {pos_integer(), byte_offset},
     byte_offset: non_neg_integer(),
     rest: binary(),
     reason: String.t(),
     context: map()
```

Parses the given `binary` as raw_tokens.

Returns `{:ok, [token], rest, context, position, byte_offset}` or
`{:error, reason, rest, context, line, byte_offset}` where `position`
describes the location of the raw_tokens (start position) as `{line, offset_to_start_of_line}`.

To column where the error occurred can be inferred from `byte_offset - offset_to_start_of_line`.

## Options

  * `:byte_offset` - the byte offset for the whole binary, defaults to 0
  * `:line` - the line and the byte offset into that line, defaults to `{1, byte_offset}`
  * `:context` - the initial context value. It will be converted to a map

# `tokenize`

```elixir
@spec tokenize(String.t()) :: {:ok, list()} | {:error, Comn.Errors.ErrorStruct.t()}
```

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

---

*Consult [api-reference.md](api-reference.md) for complete listing*
