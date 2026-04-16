# Data & Query Blocks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `data` and `query` top-level declarations (and inline variants) with pluggable format handlers, a centralized DataStore, and `memberof()` built-in.

**Architecture:** Follows the existing lex → parse → compile → dispatch pipeline. Data blocks register datasets into a new `Anemos.Runtime.DataStore` GenServer (mirrors TripleStore). Query blocks compile to callable functions. Format/engine handlers implement a new `Anemos.DataModel` behaviour (mirrors `Anemos.Module`). `memberof()` is a built-in function that resolves through the DataStore.

**Tech Stack:** Elixir/OTP, NimbleParsec, ExUnit

---

## File Map

**New files:**
- `lib/anemos/data_model.ex` — `Anemos.DataModel` behaviour + `__using__` macro
- `lib/anemos/subscribable.ex` — `Anemos.Subscribable` behaviour
- `lib/anemos/runtime/data_store.ex` — GenServer for dataset storage and lookup
- `lib/anemos/runtime/data_model_registry.ex` — Agent mapping keyword strings to handler modules
- `test/anemos/data_store_test.exs` — DataStore unit tests
- `test/anemos/data_block_test.exs` — end-to-end data block tests (lex → parse → compile → dispatch)
- `test/anemos/query_block_test.exs` — end-to-end query block tests

**Modified files:**
- `lib/anemos/lexer.ex` — add `data`, `query`, `expect`, `source`, `transclude`, `shape`, `dynamic`, `subscribe`, `periodic`, `memberof`, `global` to `@keywords`
- `lib/anemos/ast.ex` — add `DataDecl` and `QueryDecl` structs
- `lib/anemos/parser.ex` — add `parse_data/1`, `parse_query/1`, raw content capture, declaration dispatch clauses, inline statement clauses
- `lib/anemos/compiler.ex` — add `compile_data/1`, `compile_query/1`, declaration dispatch clauses, `memberof()` expression evaluation, `CompilationResult` fields
- `lib/anemos/runtime/dispatcher.ex` — start DataStore in `init/1`, pass it through context, handle `:memberof` operations
- `test/anemos/lexer_test.exs` — new token tests
- `test/anemos/parser_test.exs` — new parse tests
- `test/anemos/compiler_test.exs` — new compile tests

---

### Task 1: AST Nodes

**Files:**
- Modify: `lib/anemos/ast.ex`
- Test: `test/anemos/ast_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/anemos/ast_test.exs`:

```elixir
test "DataDecl struct has all fields" do
  node = %Anemos.AST.DataDecl{
    name: "reserved-ips",
    source: nil,
    content: {:simple_list, ["10.0.0.0/8", "192.168.0.0/16"]},
    transclude: nil,
    scope: :global,
    line: 1
  }

  assert node.name == "reserved-ips"
  assert node.scope == :global
  assert {:simple_list, [_ | _]} = node.content
end

test "QueryDecl struct has all fields" do
  node = %Anemos.AST.QueryDecl{
    name: "wd-city",
    expect: [:city, :state],
    engine: "wikidata",
    body: "some query body",
    return: "?city",
    scope: :global,
    line: 1
  }

  assert node.name == "wd-city"
  assert node.expect == [:city, :state]
  assert node.engine == "wikidata"
  assert node.return == "?city"
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/imsmith/github/anemos && mix test test/anemos/ast_test.exs --no-compile-warnings 2>&1 | tail -20`
Expected: FAIL — `Anemos.AST.DataDecl` and `Anemos.AST.QueryDecl` not defined

- [ ] **Step 3: Write minimal implementation**

Add to `lib/anemos/ast.ex` before the closing `end` of the `Anemos.AST` module:

```elixir
defmodule DataDecl do
  @moduledoc "A named data declaration with content, optional source/transclude, scope, and source line."
  @enforce_keys []
  @type t :: %__MODULE__{
    name: String.t() | nil,
    source: String.t() | nil,
    content: {:simple_list, list()} | {:format_block, String.t(), String.t()} | {:dynamic, tuple(), String.t() | nil},
    transclude: {:transclude, String.t(), String.t(), String.t()} | nil,
    scope: :local | :global,
    line: non_neg_integer() | nil
  }
  defstruct [:name, :source, :content, :transclude, :scope, :line]
end

defmodule QueryDecl do
  @moduledoc "A named query declaration with expect/engine/body/return, scope, and source line."
  @enforce_keys []
  @type t :: %__MODULE__{
    name: String.t() | nil,
    expect: [atom()],
    engine: String.t() | nil,
    body: String.t() | nil,
    return: String.t() | nil,
    scope: :local | :global,
    line: non_neg_integer() | nil
  }
  defstruct [:name, :expect, :engine, :body, :return, :scope, :line]
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /home/imsmith/github/anemos && mix test test/anemos/ast_test.exs -v 2>&1 | tail -20`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/anemos/ast.ex test/anemos/ast_test.exs
git commit -m "feat: add DataDecl and QueryDecl AST nodes"
```

---

### Task 2: Lexer — New Keywords

**Files:**
- Modify: `lib/anemos/lexer.ex`
- Test: `test/anemos/lexer_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/anemos/lexer_test.exs`:

```elixir
test "tokenizes data keyword" do
  assert {:ok, tokens} = Anemos.Lexer.tokenize("data reserved-ips { }")
  assert [{:keyword, _, :data}, {:identifier, _, "reserved-ips"}, {:lbrace, _, _}, {:rbrace, _, _}] = tokens
end

test "tokenizes query keyword" do
  assert {:ok, tokens} = Anemos.Lexer.tokenize("query movie { }")
  assert [{:keyword, _, :query}, {:identifier, _, "movie"}, {:lbrace, _, _}, {:rbrace, _, _}] = tokens
end

test "tokenizes data block keywords" do
  assert {:ok, tokens} = Anemos.Lexer.tokenize("source expect transclude dynamic subscribe periodic memberof global")
  keywords = for {:keyword, _, k} <- tokens, do: k
  assert :source in keywords
  assert :expect in keywords
  assert :transclude in keywords
  assert :dynamic in keywords
  assert :subscribe in keywords
  assert :periodic in keywords
  assert :memberof in keywords
  assert :global in keywords
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/imsmith/github/anemos && mix test test/anemos/lexer_test.exs --no-compile-warnings 2>&1 | tail -20`
Expected: FAIL — `data`, `query`, etc. tokenized as `:identifier` instead of `:keyword`

- [ ] **Step 3: Write minimal implementation**

In `lib/anemos/lexer.ex`, update the `@keywords` list (line 10–16) to add the new keywords:

```elixir
@keywords ~w(
  rule when if at on it let set emit demand condition capability flow context
  else elseif while for each every foreach do return done nextevent nextrule
  log show list graph trace explain exists infer assert unless until as with
  by that import export version signed_by scope state effect stream to channel
  service self interval then filter data query source expect transclude
  dynamic subscribe periodic memberof global
)a
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /home/imsmith/github/anemos && mix test test/anemos/lexer_test.exs -v 2>&1 | tail -20`
Expected: PASS

- [ ] **Step 5: Run full test suite to check for regressions**

Run: `cd /home/imsmith/github/anemos && mix test 2>&1 | tail -5`
Expected: All existing tests pass. Some existing tests that use `data`, `query`, `source`, `expect`, `global`, `dynamic`, `subscribe`, `periodic`, or `memberof` as identifiers may break — fix those if they exist.

- [ ] **Step 6: Commit**

```bash
git add lib/anemos/lexer.ex test/anemos/lexer_test.exs
git commit -m "feat: add data/query block keywords to lexer"
```

---

### Task 3: Parser — Simple Data Blocks

**Files:**
- Modify: `lib/anemos/parser.ex`
- Test: `test/anemos/parser_test.exs`

- [ ] **Step 1: Write the failing test for top-level simple data**

Add to `test/anemos/parser_test.exs`:

```elixir
test "parses simple data block" do
  input = """
  data reserved-ips {
    10.0.0.0/8
    192.168.0.0/16
    172.16.0.0/12
  }
  """

  assert {:ok, %{declarations: [decl]}} = Anemos.Parser.parse(input)
  assert %Anemos.AST.DataDecl{} = decl
  assert decl.name == "reserved-ips"
  assert {:simple_list, values} = decl.content
  assert "10.0.0.0/8" in values
  assert "192.168.0.0/16" in values
  assert decl.scope == :global
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/imsmith/github/anemos && mix test test/anemos/parser_test.exs --no-compile-warnings 2>&1 | tail -20`
Expected: FAIL — `Expected declaration (rule, condition, ...) but got keyword`

- [ ] **Step 3: Write the parser implementation**

In `lib/anemos/parser.ex`, add declaration dispatch clause after the existing ones (before the catch-all):

```elixir
defp parse_declaration([{:keyword, _, :data} | rest]) do
  parse_data(rest)
end

defp parse_declaration([{:keyword, _, :query} | rest]) do
  parse_query(rest)
end
```

Add the `parse_data/1` function. The key challenge is that simple list content is free-form text — values can contain dots, slashes, colons (like IP addresses and CIDR notation). The parser needs to consume tokens until `}` and treat them as raw values:

```elixir
# --- Data ---

defp parse_data([{:keyword, _, :global}, {:identifier, meta, name} | rest]) do
  parse_data_body(name, :global, meta[:line], rest)
end

defp parse_data([{:identifier, meta, name} | rest]) do
  parse_data_body(name, :global, meta[:line], rest)
end

defp parse_data_body(name, scope, line, tokens) do
  with {:ok, rest} <- expect(tokens, :lbrace),
       {source, rest} <- parse_optional_source(rest),
       {:ok, content, rest} <- parse_data_content(rest),
       {transclude, rest} <- parse_optional_transclude(rest),
       {:ok, rest} <- expect(rest, :rbrace) do
    {:ok,
     %AST.DataDecl{
       name: name,
       source: source,
       content: content,
       transclude: transclude,
       scope: scope,
       line: line
     }, rest}
  end
end

defp parse_optional_source([{:keyword, _, :source} | rest]) do
  {source_str, rest} = collect_dotted_identifier(rest)
  {source_str, rest}
end

defp parse_optional_source(tokens), do: {nil, tokens}

defp parse_optional_transclude([{:keyword, _, :transclude} | rest]) do
  # transclude to shape(...) with <transducer> as <bind>
  with [{:keyword, _, :to} | rest] <- rest,
       [{:keyword, _, :shape} | rest] <- rest,
       {:ok, rest} <- expect(rest, :lparen),
       {shape, rest} <- collect_dotted_identifier(rest),
       {:ok, rest} <- expect(rest, :rparen),
       [{:keyword, _, :with} | rest] <- rest,
       {transducer, rest} <- collect_dotted_identifier(rest),
       [{:keyword, _, :as} | rest] <- rest,
       [{:identifier, _, bind_as} | rest] <- rest do
    {{:transclude, shape, transducer, bind_as}, rest}
  end
end

defp parse_optional_transclude(tokens), do: {nil, tokens}

defp parse_data_content([{:keyword, _, :dynamic} | rest]) do
  parse_dynamic_block(rest)
end

defp parse_data_content([{:identifier, _, keyword}, {:lbrace, _, _} | _] = tokens) do
  parse_format_block(tokens)
end

defp parse_data_content(tokens) do
  # Simple list: collect all values until }, transclude, or end
  {values, rest} = collect_simple_list(tokens)
  {:ok, {:simple_list, values}, rest}
end

defp collect_simple_list(tokens, acc \\ [])

defp collect_simple_list([{:rbrace, _, _} | _] = tokens, acc) do
  {Enum.reverse(acc), tokens}
end

defp collect_simple_list([{:keyword, _, :transclude} | _] = tokens, acc) do
  {Enum.reverse(acc), tokens}
end

defp collect_simple_list([{type, _, value} | rest], acc)
     when type in [:identifier, :string, :integer, :float, :atom] do
  str_value = to_string(value)
  collect_simple_list(rest, [str_value | acc])
end

defp collect_simple_list([{:operator, _, _} | rest], acc) do
  # Skip comment markers (//) — the lexer handles these as operators
  collect_simple_list(rest, acc)
end

defp collect_simple_list([], acc) do
  {Enum.reverse(acc), []}
end
```

Note: The exact token handling for simple list values (IP addresses with dots, CIDR with slashes) depends on how the lexer tokenizes these. IP addresses like `10.0.0.0/8` will be tokenized as a sequence of tokens (integers, dots, slashes). The `collect_simple_list` function needs to reconstruct these. This may require a `collect_raw_value` helper that concatenates consecutive non-delimiter tokens into a single string value:

```elixir
defp collect_simple_list(tokens, acc) do
  case collect_raw_value(tokens) do
    {nil, rest} -> {Enum.reverse(acc), rest}
    {value, rest} -> collect_simple_list(rest, [value | acc])
  end
end

defp collect_raw_value(tokens, parts \\ [])

defp collect_raw_value([{:rbrace, _, _} | _] = tokens, []) do
  {nil, tokens}
end

defp collect_raw_value([{:keyword, _, :transclude} | _] = tokens, []) do
  {nil, tokens}
end

defp collect_raw_value([{:rbrace, _, _} | _] = tokens, parts) do
  {Enum.reverse(parts) |> Enum.join(""), tokens}
end

defp collect_raw_value([{:keyword, _, :transclude} | _] = tokens, parts) do
  {Enum.reverse(parts) |> Enum.join(""), tokens}
end

# Newline-equivalent boundary between values — if we have accumulated parts, emit the value
# This will need tuning based on how the lexer handles line boundaries

defp collect_raw_value([{type, _, value} | rest], parts)
     when type in [:identifier, :string, :integer, :float, :atom, :operator, :module_id] do
  collect_raw_value(rest, [to_string(value) | parts])
end

defp collect_raw_value(tokens, []) do
  {nil, tokens}
end

defp collect_raw_value(tokens, parts) do
  {Enum.reverse(parts) |> Enum.join(""), tokens}
end
```

The exact implementation of `collect_simple_list` and `collect_raw_value` will need adjustment based on how the lexer actually tokenizes IP addresses, CIDR blocks, and domain names. The key principle: consume tokens greedily per line, reconstruct the original string value, stop at `}` or `transclude`.

Also add `collect_dotted_identifier` if it doesn't already exist:

```elixir
defp collect_dotted_identifier([{:identifier, _, first} | rest]) do
  collect_dotted_parts(rest, [first])
end

defp collect_dotted_identifier([{:module_id, _, first} | rest]) do
  collect_dotted_parts(rest, [first])
end

defp collect_dotted_parts([{:operator, _, :.}, {:identifier, _, part} | rest], acc) do
  collect_dotted_parts(rest, [part | acc])
end

defp collect_dotted_parts(rest, acc) do
  {acc |> Enum.reverse() |> Enum.join("."), rest}
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /home/imsmith/github/anemos && mix test test/anemos/parser_test.exs -v 2>&1 | tail -20`
Expected: PASS

- [ ] **Step 5: Run full test suite**

Run: `cd /home/imsmith/github/anemos && mix test 2>&1 | tail -5`
Expected: All tests pass

- [ ] **Step 6: Commit**

```bash
git add lib/anemos/parser.ex test/anemos/parser_test.exs
git commit -m "feat: parse simple data blocks"
```

---

### Task 4: Parser — Format Blocks and Dynamic Blocks

**Files:**
- Modify: `lib/anemos/parser.ex`
- Test: `test/anemos/parser_test.exs`

- [ ] **Step 1: Write the failing tests**

Add to `test/anemos/parser_test.exs`:

```elixir
test "parses data block with format block" do
  input = """
  data movie-inventory {
    source ghost.ian.homebrew.movie-inventory
    edn {
      {:title "The Matrix" :year 1999}
    }
    transclude to shape(resource.schema.knowledge) with resource.transducer.edn-to-kb as fact
  }
  """

  assert {:ok, %{declarations: [decl]}} = Anemos.Parser.parse(input)
  assert %Anemos.AST.DataDecl{} = decl
  assert decl.name == "movie-inventory"
  assert decl.source == "ghost.ian.homebrew.movie-inventory"
  assert {:format_block, "edn", raw} = decl.content
  assert is_binary(raw)
  assert String.contains?(raw, "The Matrix")
  assert {:transclude, "resource.schema.knowledge", "resource.transducer.edn-to-kb", "fact"} = decl.transclude
end

test "parses dynamic data block" do
  input = """
  data botnet-ips {
    dynamic {
      subscribe webhook https://hooks.example.com/feed
    }
  }
  """

  assert {:ok, %{declarations: [decl]}} = Anemos.Parser.parse(input)
  assert %Anemos.AST.DataDecl{} = decl
  assert decl.name == "botnet-ips"
  assert {:dynamic, {:subscribe, "webhook", uri}, nil} = decl.content
  assert String.contains?(uri, "hooks.example.com")
end

test "parses dynamic data block with periodic" do
  input = """
  data gtld-servers {
    dynamic {
      subscribe git git://example.com/repos/gtld-servers.git
      periodic daily
    }
  }
  """

  assert {:ok, %{declarations: [decl]}} = Anemos.Parser.parse(input)
  assert {:dynamic, {:subscribe, "git", _uri}, "daily"} = decl.content
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/imsmith/github/anemos && mix test test/anemos/parser_test.exs --no-compile-warnings 2>&1 | tail -20`
Expected: FAIL

- [ ] **Step 3: Write the format block and dynamic block parsers**

Add to `lib/anemos/parser.ex`:

```elixir
defp parse_format_block([{:identifier, _, keyword} | rest]) do
  with {:ok, rest} <- expect(rest, :lbrace) do
    {raw, rest} = collect_raw_content(rest, 1, [])
    {:ok, {:format_block, keyword, raw}, rest}
  end
end

# Brace-depth counting: captures everything between { and matching }
# Tracks nested braces so format content can contain { } pairs
defp collect_raw_content([{:rbrace, _, _} | rest], 1, acc) do
  raw = acc |> Enum.reverse() |> Enum.join("")
  {String.trim(raw), rest}
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

defp collect_raw_content([], _depth, _acc) do
  # This will be caught as an error upstream
  {"", []}
end

defp token_to_string({:string, _, val}), do: ~s|"#{val}"|
defp token_to_string({:identifier, _, val}), do: " #{val}"
defp token_to_string({:keyword, _, val}), do: " #{val}"
defp token_to_string({:module_id, _, val}), do: " #{val}"
defp token_to_string({:integer, _, val}), do: " #{val}"
defp token_to_string({:float, _, val}), do: " #{val}"
defp token_to_string({:atom, _, val}), do: " :#{val}"
defp token_to_string({:query_var, _, val}), do: " ?#{val}"
defp token_to_string({:lbrace, _, _}), do: " {"
defp token_to_string({:rbrace, _, _}), do: " }"
defp token_to_string({:lbracket, _, _}), do: " ["
defp token_to_string({:rbracket, _, _}), do: " ]"
defp token_to_string({:lparen, _, _}), do: " ("
defp token_to_string({:rparen, _, _}), do: " )"
defp token_to_string({:operator, _, val}), do: " #{val}"
defp token_to_string({:comma, _, _}), do: ","
defp token_to_string({:double_colon, _, _}), do: "::"
defp token_to_string({_, _, val}), do: " #{val}"

defp parse_dynamic_block(tokens) do
  with {:ok, rest} <- expect(tokens, :lbrace),
       {:ok, subscribe, rest} <- parse_subscribe(rest),
       {periodic, rest} <- parse_optional_periodic(rest),
       {:ok, rest} <- expect(rest, :rbrace) do
    {:ok, {:dynamic, subscribe, periodic}, rest}
  end
end

defp parse_subscribe([{:keyword, _, :subscribe}, {:identifier, _, protocol} | rest]) do
  # Collect the URI — everything until the next keyword or closing brace
  {uri, rest} = collect_uri(rest)
  {:ok, {:subscribe, protocol, uri}, rest}
end

defp collect_uri(tokens, parts \\ [])

defp collect_uri([{:keyword, _, _} | _] = tokens, parts) do
  {parts |> Enum.reverse() |> Enum.join(""), tokens}
end

defp collect_uri([{:rbrace, _, _} | _] = tokens, parts) do
  {parts |> Enum.reverse() |> Enum.join(""), tokens}
end

defp collect_uri([{_, _, val} | rest], parts) do
  collect_uri(rest, [to_string(val) | parts])
end

defp collect_uri([], parts) do
  {parts |> Enum.reverse() |> Enum.join(""), []}
end

defp parse_optional_periodic([{:keyword, _, :periodic}, {:identifier, _, interval} | rest]) do
  {interval, rest}
end

defp parse_optional_periodic(tokens), do: {nil, tokens}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /home/imsmith/github/anemos && mix test test/anemos/parser_test.exs -v 2>&1 | tail -20`
Expected: PASS

- [ ] **Step 5: Run full test suite**

Run: `cd /home/imsmith/github/anemos && mix test 2>&1 | tail -5`
Expected: All tests pass

- [ ] **Step 6: Commit**

```bash
git add lib/anemos/parser.ex test/anemos/parser_test.exs
git commit -m "feat: parse format blocks and dynamic data blocks"
```

---

### Task 5: Parser — Query Blocks

**Files:**
- Modify: `lib/anemos/parser.ex`
- Test: `test/anemos/parser_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/anemos/parser_test.exs`:

```elixir
test "parses query block" do
  input = """
  query wd-city {
    expect :city, :state
    wikidata {
      SELECT ?city WHERE { ?city :locatedIn ?state }
    }
    return ?city
  }
  """

  assert {:ok, %{declarations: [decl]}} = Anemos.Parser.parse(input)
  assert %Anemos.AST.QueryDecl{} = decl
  assert decl.name == "wd-city"
  assert decl.expect == [:city, :state]
  assert decl.engine == "wikidata"
  assert is_binary(decl.body)
  assert decl.return == "city"
  assert decl.scope == :global
end

test "parses query block without expect" do
  input = """
  query all-movies {
    movies {
      thing/movie { }
    }
    return ?movie
  }
  """

  assert {:ok, %{declarations: [decl]}} = Anemos.Parser.parse(input)
  assert %Anemos.AST.QueryDecl{} = decl
  assert decl.expect == []
  assert decl.engine == "movies"
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/imsmith/github/anemos && mix test test/anemos/parser_test.exs --no-compile-warnings 2>&1 | tail -20`
Expected: FAIL

- [ ] **Step 3: Write the query parser**

Add to `lib/anemos/parser.ex`:

```elixir
# --- Query ---

defp parse_query([{:keyword, _, :global}, {:identifier, meta, name} | rest]) do
  parse_query_body(name, :global, meta[:line], rest)
end

defp parse_query([{:identifier, meta, name} | rest]) do
  parse_query_body(name, :global, meta[:line], rest)
end

defp parse_query_body(name, scope, line, tokens) do
  with {:ok, rest} <- expect(tokens, :lbrace),
       {expect_list, rest} <- parse_optional_expect(rest),
       {:ok, engine, body, rest} <- parse_engine_block(rest),
       {:ok, return_var, rest} <- parse_return_stmt(rest),
       {:ok, rest} <- expect(rest, :rbrace) do
    {:ok,
     %AST.QueryDecl{
       name: name,
       expect: expect_list,
       engine: engine,
       body: body,
       return: return_var,
       scope: scope,
       line: line
     }, rest}
  end
end

defp parse_optional_expect([{:keyword, _, :expect} | rest]) do
  {atoms, rest} = collect_atom_list(rest)
  {atoms, rest}
end

defp parse_optional_expect(tokens), do: {[], tokens}

defp collect_atom_list(tokens, acc \\ [])

defp collect_atom_list([{:atom, _, name}, {:comma, _, _} | rest], acc) do
  collect_atom_list(rest, [name | acc])
end

defp collect_atom_list([{:atom, _, name} | rest], acc) do
  {Enum.reverse([name | acc]), rest}
end

defp collect_atom_list(tokens, acc) do
  {Enum.reverse(acc), tokens}
end

defp parse_engine_block([{:identifier, _, engine} | rest]) do
  with {:ok, rest} <- expect(rest, :lbrace) do
    {raw, rest} = collect_raw_content(rest, 1, [])
    {:ok, engine, raw, rest}
  end
end

defp parse_return_stmt([{:keyword, _, :return}, {:query_var, _, var_name} | rest]) do
  {:ok, var_name, rest}
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /home/imsmith/github/anemos && mix test test/anemos/parser_test.exs -v 2>&1 | tail -20`
Expected: PASS

- [ ] **Step 5: Run full test suite**

Run: `cd /home/imsmith/github/anemos && mix test 2>&1 | tail -5`
Expected: All tests pass

- [ ] **Step 6: Commit**

```bash
git add lib/anemos/parser.ex test/anemos/parser_test.exs
git commit -m "feat: parse query blocks"
```

---

### Task 6: Parser — Inline Data/Query in Rule Bodies

**Files:**
- Modify: `lib/anemos/parser.ex`
- Test: `test/anemos/parser_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/anemos/parser_test.exs`:

```elixir
test "parses inline data block inside rule" do
  input = """
  rule check-ips {
    data bad-ips {
      1.2.3.4
      5.6.7.8
    }
    when CONNECTION_INIT {
      log "checking"
    }
  }
  """

  assert {:ok, %{declarations: [rule]}} = Anemos.Parser.parse(input)
  assert %Anemos.AST.Rule{} = rule
  data_blocks = Enum.filter(rule.body, &match?(%Anemos.AST.DataDecl{}, &1))
  assert [data] = data_blocks
  assert data.name == "bad-ips"
  assert data.scope == :local
end

test "parses inline data block with global escape" do
  input = """
  rule setup {
    data global shared-list {
      a
      b
      c
    }
    when INIT {
      log "done"
    }
  }
  """

  assert {:ok, %{declarations: [rule]}} = Anemos.Parser.parse(input)
  data_blocks = Enum.filter(rule.body, &match?(%Anemos.AST.DataDecl{}, &1))
  assert [data] = data_blocks
  assert data.scope == :global
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/imsmith/github/anemos && mix test test/anemos/parser_test.exs --no-compile-warnings 2>&1 | tail -20`
Expected: FAIL — `data` not recognized as a statement

- [ ] **Step 3: Add data and query as statement types**

In `lib/anemos/parser.ex`, add to the `parse_statement` dispatch (before the catch-all):

```elixir
defp parse_statement([{:keyword, _, :data} | rest]) do
  parse_inline_data(rest)
end

defp parse_statement([{:keyword, _, :query} | rest]) do
  parse_inline_query(rest)
end
```

Add the inline parsers that set scope to `:local` by default:

```elixir
defp parse_inline_data([{:keyword, _, :global}, {:identifier, meta, name} | rest]) do
  parse_data_body(name, :global, meta[:line], rest)
end

defp parse_inline_data([{:identifier, meta, name} | rest]) do
  parse_data_body(name, :local, meta[:line], rest)
end

defp parse_inline_query([{:keyword, _, :global}, {:identifier, meta, name} | rest]) do
  parse_query_body(name, :global, meta[:line], rest)
end

defp parse_inline_query([{:identifier, meta, name} | rest]) do
  parse_query_body(name, :local, meta[:line], rest)
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /home/imsmith/github/anemos && mix test test/anemos/parser_test.exs -v 2>&1 | tail -20`
Expected: PASS

- [ ] **Step 5: Run full test suite**

Run: `cd /home/imsmith/github/anemos && mix test 2>&1 | tail -5`
Expected: All tests pass

- [ ] **Step 6: Commit**

```bash
git add lib/anemos/parser.ex test/anemos/parser_test.exs
git commit -m "feat: parse inline data/query blocks in rule bodies"
```

---

### Task 7: DataStore GenServer

**Files:**
- Create: `lib/anemos/runtime/data_store.ex`
- Create: `test/anemos/data_store_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/anemos/data_store_test.exs`:

```elixir
defmodule Anemos.Runtime.DataStoreTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Anemos.Runtime.DataStore

  test "register and member? for simple list" do
    {:ok, store} = DataStore.start_link()
    :ok = DataStore.register(store, "reserved-ips", :global, MapSet.new(["10.0.0.0/8", "192.168.0.0/16"]))

    assert DataStore.member?(store, "reserved-ips", "10.0.0.0/8")
    refute DataStore.member?(store, "reserved-ips", "8.8.8.8")
  end

  test "get returns full dataset" do
    {:ok, store} = DataStore.start_link()
    dataset = MapSet.new(["a", "b", "c"])
    :ok = DataStore.register(store, "letters", :global, dataset)

    assert DataStore.get(store, "letters") == dataset
  end

  test "deregister removes entry" do
    {:ok, store} = DataStore.start_link()
    :ok = DataStore.register(store, "temp", :global, MapSet.new(["x"]))
    assert DataStore.member?(store, "temp", "x")

    :ok = DataStore.deregister(store, "temp", :global)
    refute DataStore.member?(store, "temp", "x")
  end

  test "local scope shadows global" do
    {:ok, store} = DataStore.start_link()
    :ok = DataStore.register(store, "ips", :global, MapSet.new(["1.1.1.1"]))
    :ok = DataStore.register(store, "ips", {:local, self()}, MapSet.new(["2.2.2.2"]))

    # Local shadows global — self() is the caller
    assert DataStore.member?(store, "ips", "2.2.2.2")
    refute DataStore.member?(store, "ips", "1.1.1.1")
  end

  test "update replaces dataset silently" do
    {:ok, store} = DataStore.start_link()
    :ok = DataStore.register(store, "feed", :global, MapSet.new(["old"]))
    assert DataStore.member?(store, "feed", "old")

    :ok = DataStore.update(store, "feed", :global, MapSet.new(["new"]))
    refute DataStore.member?(store, "feed", "old")
    assert DataStore.member?(store, "feed", "new")
  end

  test "member? with multiple names (union check)" do
    {:ok, store} = DataStore.start_link()
    :ok = DataStore.register(store, "set-a", :global, MapSet.new(["x"]))
    :ok = DataStore.register(store, "set-b", :global, MapSet.new(["y"]))

    assert DataStore.member_any?(store, ["set-a", "set-b"], "x")
    assert DataStore.member_any?(store, ["set-a", "set-b"], "y")
    refute DataStore.member_any?(store, ["set-a", "set-b"], "z")
  end

  test "get returns nil for unknown name" do
    {:ok, store} = DataStore.start_link()
    assert DataStore.get(store, "nonexistent") == nil
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/imsmith/github/anemos && mix test test/anemos/data_store_test.exs --no-compile-warnings 2>&1 | tail -20`
Expected: FAIL — module not defined

- [ ] **Step 3: Write the DataStore implementation**

Create `lib/anemos/runtime/data_store.ex`:

```elixir
defmodule Anemos.Runtime.DataStore do
  @moduledoc """
  GenServer holding named datasets for data blocks.

  Stores entries keyed by `{name, scope_tag}` where scope_tag is
  `:global` or `{:local, pid}`. Supports membership checks with
  local-shadows-global resolution.
  """

  use GenServer

  # --- Client API ---

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, %{}, name: name)
  end

  @spec register(pid() | atom(), String.t(), :global | {:local, pid()}, term(), keyword()) :: :ok
  def register(store, name, scope_tag, dataset, opts \\ []) do
    GenServer.call(store, {:register, name, scope_tag, dataset, opts})
  end

  @spec deregister(pid() | atom(), String.t(), :global | {:local, pid()}) :: :ok
  def deregister(store, name, scope_tag) do
    GenServer.call(store, {:deregister, name, scope_tag})
  end

  @spec member?(pid() | atom(), String.t(), term()) :: boolean()
  def member?(store, name, value) do
    GenServer.call(store, {:member?, name, value, self()})
  end

  @spec member_any?(pid() | atom(), [String.t()], term()) :: boolean()
  def member_any?(store, names, value) do
    Enum.any?(names, fn name -> member?(store, name, value) end)
  end

  @spec get(pid() | atom(), String.t()) :: term() | nil
  def get(store, name) do
    GenServer.call(store, {:get, name, self()})
  end

  @spec update(pid() | atom(), String.t(), :global | {:local, pid()}, term()) :: :ok
  def update(store, name, scope_tag, dataset) do
    GenServer.call(store, {:update, name, scope_tag, dataset})
  end

  # --- Server callbacks ---

  @impl true
  def init(_opts) do
    {:ok, %{entries: %{}}}
  end

  @impl true
  def handle_call({:register, name, scope_tag, dataset, opts}, _from, state) do
    entry = %{
      dataset: dataset,
      source: Keyword.get(opts, :source),
      transcluded: Keyword.get(opts, :transcluded),
      subscription: Keyword.get(opts, :subscription)
    }

    # Monitor local processes for cleanup
    if match?({:local, pid} when is_pid(pid), scope_tag) do
      {:local, pid} = scope_tag
      Process.monitor(pid)
    end

    entries = Map.put(state.entries, {name, scope_tag}, entry)
    {:reply, :ok, %{state | entries: entries}}
  end

  @impl true
  def handle_call({:deregister, name, scope_tag}, _from, state) do
    entries = Map.delete(state.entries, {name, scope_tag})
    {:reply, :ok, %{state | entries: entries}}
  end

  @impl true
  def handle_call({:member?, name, value, caller_pid}, _from, state) do
    result =
      case resolve_entry(state.entries, name, caller_pid) do
        nil -> false
        %{dataset: dataset} -> check_membership(dataset, value)
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:get, name, caller_pid}, _from, state) do
    result =
      case resolve_entry(state.entries, name, caller_pid) do
        nil -> nil
        %{dataset: dataset} -> dataset
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:update, name, scope_tag, dataset}, _from, state) do
    case Map.get(state.entries, {name, scope_tag}) do
      nil ->
        {:reply, :ok, state}

      entry ->
        entries = Map.put(state.entries, {name, scope_tag}, %{entry | dataset: dataset})
        {:reply, :ok, %{state | entries: entries}}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Clean up all local entries for the dead process
    entries =
      state.entries
      |> Enum.reject(fn {{_name, scope_tag}, _entry} -> scope_tag == {:local, pid} end)
      |> Map.new()

    {:noreply, %{state | entries: entries}}
  end

  # --- Private ---

  defp resolve_entry(entries, name, caller_pid) do
    # Local scope shadows global
    case Map.get(entries, {name, {:local, caller_pid}}) do
      nil -> Map.get(entries, {name, :global})
      entry -> entry
    end
  end

  defp check_membership(%MapSet{} = set, value), do: MapSet.member?(set, value)
  defp check_membership(list, value) when is_list(list), do: value in list
  defp check_membership(_, _), do: false
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /home/imsmith/github/anemos && mix test test/anemos/data_store_test.exs -v 2>&1 | tail -20`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/anemos/runtime/data_store.ex test/anemos/data_store_test.exs
git commit -m "feat: add DataStore GenServer for data block storage"
```

---

### Task 8: DataModel Behaviour and Registry

**Files:**
- Create: `lib/anemos/data_model.ex`
- Create: `lib/anemos/subscribable.ex`
- Create: `lib/anemos/runtime/data_model_registry.ex`
- Test: `test/anemos/data_store_test.exs` (add to existing)

- [ ] **Step 1: Write the failing test**

Add to `test/anemos/data_store_test.exs` (or create a new test file `test/anemos/data_model_test.exs`):

```elixir
defmodule Anemos.DataModelTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Anemos.Runtime.DataModelRegistry

  test "register and lookup a data model handler" do
    {:ok, registry} = DataModelRegistry.start_link()
    defmodule TestHandler do
      @behaviour Anemos.DataModel
      def keyword, do: "test-format"
      def parse(raw), do: {:ok, String.split(raw, "\n")}
      def eval(parsed, _context), do: {:ok, parsed}
      def transduce(_data, _shape, _transducer), do: {:error, :not_supported}
    end

    :ok = DataModelRegistry.register(registry, TestHandler)
    assert {:ok, TestHandler} = DataModelRegistry.lookup(registry, "test-format")
    assert :error = DataModelRegistry.lookup(registry, "unknown")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/imsmith/github/anemos && mix test test/anemos/data_model_test.exs --no-compile-warnings 2>&1 | tail -20`
Expected: FAIL — modules not defined

- [ ] **Step 3: Write the DataModel behaviour**

Create `lib/anemos/data_model.ex`:

```elixir
defmodule Anemos.DataModel do
  @moduledoc """
  Behaviour for pluggable data format and query engine handlers.

  Implementations register a keyword (e.g., `"edn"`, `"xml"`, `"sql"`)
  that becomes valid inside data and query block bodies. The runtime
  delegates parsing, evaluation, and transclude to the registered handler.

  ## Usage

      defmodule MyApp.Anemos.EdnHandler do
        @behaviour Anemos.DataModel

        def keyword, do: "edn"
        def parse(raw), do: # parse EDN string
        def eval(parsed, context), do: {:ok, parsed}
        def transduce(data, shape, transducer), do: # apply transformation
      end
  """

  @callback keyword() :: String.t()
  @callback parse(raw :: String.t()) :: {:ok, term()} | {:error, term()}
  @callback eval(parsed :: term(), context :: map()) :: {:ok, term()} | {:error, term()}
  @callback transduce(data :: term(), shape :: String.t(), transducer :: String.t()) ::
              {:ok, term()} | {:error, term()}
end
```

Create `lib/anemos/subscribable.ex`:

```elixir
defmodule Anemos.Subscribable do
  @moduledoc """
  Behaviour for data sources that support dynamic subscription.

  Implementations register a protocol identifier (e.g., `"webhook"`,
  `"rss"`, `"amqp"`) used in `dynamic { subscribe <protocol> <uri> }`
  blocks.
  """

  @callback subscribe(protocol :: String.t(), uri :: String.t(), callback :: fun()) ::
              {:ok, reference()} | {:error, term()}
  @callback unsubscribe(reference()) :: :ok
  @callback periodic?() :: boolean()
  @callback interval(spec :: String.t()) :: pos_integer()
end
```

Create `lib/anemos/runtime/data_model_registry.ex`:

```elixir
defmodule Anemos.Runtime.DataModelRegistry do
  @moduledoc """
  Agent mapping data model keyword strings to handler modules.

  Mirrors `Anemos.Runtime.ModuleRegistry` for verb handlers.
  """

  use Agent

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name)
    Agent.start_link(fn -> %{} end, name: name)
  end

  @spec register(pid() | atom(), module()) :: :ok
  def register(registry, handler_module) do
    keyword = handler_module.keyword()
    Agent.update(registry, &Map.put(&1, keyword, handler_module))
  end

  @spec lookup(pid() | atom(), String.t()) :: {:ok, module()} | :error
  def lookup(registry, keyword) do
    case Agent.get(registry, &Map.get(&1, keyword)) do
      nil -> :error
      module -> {:ok, module}
    end
  end

  @spec list(pid() | atom()) :: [String.t()]
  def list(registry) do
    Agent.get(registry, &Map.keys/1)
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /home/imsmith/github/anemos && mix test test/anemos/data_model_test.exs -v 2>&1 | tail -20`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/anemos/data_model.ex lib/anemos/subscribable.ex lib/anemos/runtime/data_model_registry.ex test/anemos/data_model_test.exs
git commit -m "feat: add DataModel/Subscribable behaviours and DataModelRegistry"
```

---

### Task 9: Compiler — Data Blocks

**Files:**
- Modify: `lib/anemos/compiler.ex`
- Test: `test/anemos/compiler_test.exs`

- [ ] **Step 1: Write the failing tests**

Add to `test/anemos/compiler_test.exs`:

```elixir
test "compiles simple data block" do
  input = """
  data test-list {
    alpha
    bravo
    charlie
  }
  """

  {:ok, ast} = Parser.parse(input)
  {:ok, result} = Compiler.compile(ast)

  assert [data] = result.data_blocks
  assert data.name == "test-list"
  assert data.scope == :global
  assert MapSet.member?(data.dataset, "alpha")
  assert MapSet.member?(data.dataset, "bravo")
  assert MapSet.member?(data.dataset, "charlie")
end

test "compiles data block with format block" do
  input = """
  data stuff {
    edn {
      {:key "value"}
    }
  }
  """

  {:ok, ast} = Parser.parse(input)
  {:ok, result} = Compiler.compile(ast)

  assert [data] = result.data_blocks
  assert data.name == "stuff"
  assert data.format == "edn"
  assert is_binary(data.raw)
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/imsmith/github/anemos && mix test test/anemos/compiler_test.exs --no-compile-warnings 2>&1 | tail -20`
Expected: FAIL — `data_blocks` not a field on CompilationResult

- [ ] **Step 3: Write the compiler implementation**

First, add `data_blocks` and `query_blocks` to `%Anemos.CompilationResult{}`:

```elixir
defmodule Anemos.CompilationResult do
  @enforce_keys []
  defstruct rules: [], conditions: [], capabilities: [], schedules: [], data_blocks: [], query_blocks: []

  @type t :: %__MODULE__{
          rules: [Anemos.CompiledRule.t()],
          conditions: [Anemos.CompiledCondition.t()],
          capabilities: [Anemos.CompiledCapability.t()],
          schedules: [Anemos.CompiledSchedule.t()],
          data_blocks: [map()],
          query_blocks: [map()]
        }
end
```

Add a compiled data struct (at the top of `compiler.ex` alongside the other compiled structs):

```elixir
defmodule Anemos.CompiledData do
  @moduledoc """
  A compiled data block: name, scope, and the resolved dataset or raw format content.
  """
  @enforce_keys [:name]
  defstruct [:name, :scope, :dataset, :format, :raw, :source, :transclude, :dynamic]

  @type t :: %__MODULE__{
          name: String.t(),
          scope: :local | :global,
          dataset: MapSet.t() | nil,
          format: String.t() | nil,
          raw: String.t() | nil,
          source: String.t() | nil,
          transclude: tuple() | nil,
          dynamic: tuple() | nil
        }
end

defmodule Anemos.CompiledQuery do
  @moduledoc """
  A compiled query block: name, scope, expect list, engine, parsed body, return var.
  """
  @enforce_keys [:name]
  defstruct [:name, :scope, :expect, :engine, :body, :return, :handler]

  @type t :: %__MODULE__{
          name: String.t(),
          scope: :local | :global,
          expect: [atom()],
          engine: String.t() | nil,
          body: String.t() | nil,
          return: String.t() | nil,
          handler: fun() | nil
        }
end
```

Add declaration dispatch in `compile_declaration/1`:

```elixir
defp compile_declaration(%AST.DataDecl{} = data) do
  {:data, compile_data(data)}
end

defp compile_declaration(%AST.QueryDecl{} = query) do
  {:query, compile_query(query)}
end
```

Add the accumulation in `compile/1`'s reduce:

```elixir
{:data, compiled_data} ->
  %{acc | data_blocks: acc.data_blocks ++ [compiled_data]}
{:query, compiled_query} ->
  %{acc | query_blocks: acc.query_blocks ++ [compiled_query]}
```

Add the compile functions:

```elixir
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

defp compile_query(%AST.QueryDecl{name: name, expect: expect, engine: engine, body: body, return: ret, scope: scope}) do
  handler = fn bindings, context ->
    # At runtime, this will dispatch to the registered engine handler
    # For now, store the raw query for later resolution
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
```

Also handle inline data/query blocks in `eval_statement` — when the compiler encounters a `%AST.DataDecl{}` or `%AST.QueryDecl{}` as a statement inside a rule body, it should emit a `:register_data` or `:register_query` operation:

```elixir
defp eval_statement(%AST.DataDecl{} = data, context, bindings) do
  compiled = compile_data(data)
  op = %{type: :register_data, data: compiled}
  {[op], bindings}
end

defp eval_statement(%AST.QueryDecl{} = query, context, bindings) do
  compiled = compile_query(query)
  op = %{type: :register_query, query: compiled}
  {[op], bindings}
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /home/imsmith/github/anemos && mix test test/anemos/compiler_test.exs -v 2>&1 | tail -20`
Expected: PASS

- [ ] **Step 5: Run full test suite**

Run: `cd /home/imsmith/github/anemos && mix test 2>&1 | tail -5`
Expected: All tests pass

- [ ] **Step 6: Commit**

```bash
git add lib/anemos/compiler.ex test/anemos/compiler_test.exs
git commit -m "feat: compile data and query blocks"
```

---

### Task 10: Compiler — Dynamic Inline Warning

**Files:**
- Modify: `lib/anemos/compiler.ex`
- Test: `test/anemos/compiler_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/anemos/compiler_test.exs`:

```elixir
import ExUnit.CaptureLog

test "warns on dynamic inline data block" do
  input = """
  rule check {
    data live-feed {
      dynamic {
        subscribe webhook https://example.com/feed
      }
    }
    when EVENT {
      log "ok"
    }
  }
  """

  {:ok, ast} = Parser.parse(input)

  log =
    capture_log(fn ->
      {:ok, _result} = Compiler.compile(ast)
    end)

  assert log =~ "dynamic"
  assert log =~ "live-feed"
  assert log =~ "check"
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/imsmith/github/anemos && mix test test/anemos/compiler_test.exs --no-compile-warnings 2>&1 | tail -20`
Expected: FAIL — no warning emitted

- [ ] **Step 3: Add warning to eval_statement for inline dynamic data**

In the `eval_statement(%AST.DataDecl{})` clause, add a warning when the data block is dynamic and locally scoped:

```elixir
defp eval_statement(%AST.DataDecl{} = data, context, bindings) do
  compiled = compile_data(data)

  if compiled.dynamic && compiled.scope == :local do
    # Get enclosing rule name from context if available
    rule_name = Map.get(context, :rule_name, "unknown")
    Logger.warning(
      "data block '#{compiled.name}' is dynamic and inline-scoped to rule '#{rule_name}' — " <>
      "subscription lifecycle is tied to rule process (will reconnect on rule restart)"
    )
  end

  op = %{type: :register_data, data: compiled}
  {[op], bindings}
end
```

This requires that `compile_rule` passes the rule name through the context when calling `eval_body`. Check how `build_handler` constructs the context and add `:rule_name` to it. In `compile_rule`, update the handler builder to include the rule name:

```elixir
# In compile_rule, when building the handler, ensure context includes :rule_name
# This may require passing rule_name through build_handler/build_guarded_handler
```

The exact wiring depends on how `build_handler` passes context. The key change: the `context` map passed to `eval_body` inside the handler closure should include `rule_name: name`.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /home/imsmith/github/anemos && mix test test/anemos/compiler_test.exs -v 2>&1 | tail -20`
Expected: PASS

- [ ] **Step 5: Run full test suite**

Run: `cd /home/imsmith/github/anemos && mix test 2>&1 | tail -5`
Expected: All tests pass

- [ ] **Step 6: Commit**

```bash
git add lib/anemos/compiler.ex test/anemos/compiler_test.exs
git commit -m "feat: warn on dynamic inline data blocks"
```

---

### Task 11: Dispatcher — DataStore Integration

**Files:**
- Modify: `lib/anemos/runtime/dispatcher.ex`
- Test: `test/anemos/runtime/dispatcher_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/anemos/runtime/dispatcher_test.exs`:

```elixir
test "dispatcher starts DataStore and registers data blocks on load" do
  {:ok, registry} = Anemos.Runtime.ModuleRegistry.start_link()

  input = """
  data test-set {
    alpha
    bravo
  }
  rule r {
    when EV {
      log "ok"
    }
  }
  """

  {:ok, ast} = Anemos.Parser.parse(input)
  {:ok, compiled} = Anemos.Compiler.compile(ast)

  {:ok, dispatcher} =
    Anemos.Runtime.Dispatcher.start_link(
      rules: compiled.rules,
      registry: registry,
      conditions: compiled.conditions,
      capabilities: compiled.capabilities
    )

  # Load data blocks
  :ok = Anemos.Runtime.Dispatcher.load(dispatcher, compiled)

  # Verify data is accessible via the dispatcher's DataStore
  assert Anemos.Runtime.Dispatcher.data_member?(dispatcher, "test-set", "alpha")
  refute Anemos.Runtime.Dispatcher.data_member?(dispatcher, "test-set", "unknown")
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/imsmith/github/anemos && mix test test/anemos/runtime/dispatcher_test.exs --no-compile-warnings 2>&1 | tail -20`
Expected: FAIL — `data_member?/3` not defined

- [ ] **Step 3: Wire DataStore into the Dispatcher**

In `lib/anemos/runtime/dispatcher.ex`:

Add to the alias line:

```elixir
alias Anemos.Runtime.{CapabilityServer, ConditionServer, DataStore, ModuleRegistry, TripleStore}
```

Add DataStore startup in `init/1`, after the TripleStore start:

```elixir
{:ok, data_store} = DataStore.start_link()
```

Add `data_store: data_store` to the state map.

Add client API function:

```elixir
@spec data_member?(pid() | atom(), String.t(), term()) :: boolean()
def data_member?(dispatcher, name, value) do
  GenServer.call(dispatcher, {:data_member?, name, value})
end
```

Add handle_call clause:

```elixir
@impl true
def handle_call({:data_member?, name, value}, _from, state) do
  result = DataStore.member?(state.data_store, name, value)
  {:reply, result, state}
end
```

In the `handle_call({:load, compiled}, ...)` handler, after loading rules/conditions/capabilities, register data blocks:

```elixir
# Register data blocks
Enum.each(compiled.data_blocks, fn data ->
  if data.dataset do
    DataStore.register(state.data_store, data.name, data.scope, data.dataset,
      source: data.source)
  end
end)
```

Add `:register_data` and `:register_query` to the operation execution in `execute_op/2` (or wherever operations are processed):

```elixir
defp execute_op(%{type: :register_data, data: data}, state) do
  if data.dataset do
    DataStore.register(state.data_store, data.name, {:local, self()}, data.dataset)
  end
  {nil, state}
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /home/imsmith/github/anemos && mix test test/anemos/runtime/dispatcher_test.exs -v 2>&1 | tail -20`
Expected: PASS

- [ ] **Step 5: Run full test suite**

Run: `cd /home/imsmith/github/anemos && mix test 2>&1 | tail -5`
Expected: All tests pass

- [ ] **Step 6: Commit**

```bash
git add lib/anemos/runtime/dispatcher.ex test/anemos/runtime/dispatcher_test.exs
git commit -m "feat: wire DataStore into dispatcher, register data blocks on load"
```

---

### Task 12: memberof() — Compiler and Dispatcher

**Files:**
- Modify: `lib/anemos/parser.ex`
- Modify: `lib/anemos/compiler.ex`
- Modify: `lib/anemos/runtime/dispatcher.ex`
- Test: `test/anemos/data_block_test.exs` (new, end-to-end)

- [ ] **Step 1: Write the failing end-to-end test**

Create `test/anemos/data_block_test.exs`:

```elixir
defmodule Anemos.DataBlockTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Anemos.{Parser, Compiler}
  alias Anemos.Runtime.{Dispatcher, ModuleRegistry}

  test "memberof() checks membership in data block" do
    input = """
    data allowed-users {
      alice
      bob
      charlie
    }
    rule check-user {
      when USER_LOGIN {
        if ?user memberof(allowed-users) {
          log "allowed"
        } else {
          log "denied"
        }
      }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, compiled} = Compiler.compile(ast)
    {:ok, registry} = ModuleRegistry.start_link()

    {:ok, dispatcher} =
      Dispatcher.start_link(
        rules: compiled.rules,
        registry: registry
      )

    :ok = Dispatcher.load(dispatcher, compiled)

    # Dispatch with user=alice (should be allowed)
    results = Dispatcher.dispatch(dispatcher, "USER_LOGIN", %{context_data: %{"user" => "alice"}})
    ops = for {:ok, op} <- List.flatten(results), do: op
    assert Enum.any?(ops, &(&1.type == :log && &1.value == "allowed"))

    # Dispatch with user=eve (should be denied)
    results = Dispatcher.dispatch(dispatcher, "USER_LOGIN", %{context_data: %{"user" => "eve"}})
    ops = for {:ok, op} <- List.flatten(results), do: op
    assert Enum.any?(ops, &(&1.type == :log && &1.value == "denied"))
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/imsmith/github/anemos && mix test test/anemos/data_block_test.exs --no-compile-warnings 2>&1 | tail -20`
Expected: FAIL — `memberof` not recognized as an expression

- [ ] **Step 3: Add memberof() parsing**

In `lib/anemos/parser.ex`, add `memberof(...)` as a primary expression in the expression parser. It should parse as a function call node. Add to `parse_atom_expression`:

```elixir
defp parse_atom_expression([{:keyword, meta, :memberof}, {:lparen, _, _} | rest]) do
  {names, rest} = collect_identifier_list(rest)
  with {:ok, rest} <- expect(rest, :rparen) do
    {:ok, %AST.Literal{type: :memberof, value: names, line: meta[:line]}, rest}
  end
end
```

Add `collect_identifier_list`:

```elixir
defp collect_identifier_list(tokens, acc \\ [])

defp collect_identifier_list([{:identifier, _, name}, {:comma, _, _} | rest], acc) do
  collect_identifier_list(rest, [name | acc])
end

defp collect_identifier_list([{:identifier, _, name} | rest], acc) do
  {Enum.reverse([name | acc]), rest}
end

defp collect_identifier_list(tokens, acc) do
  {Enum.reverse(acc), tokens}
end
```

Then handle `memberof` as a binary operator in expressions — `?user memberof(allowed-users)` is `<expr> memberof(<names>)`. This is similar to `in` or `contains`. Add `memberof` to the expression climbing or handle it as a postfix/infix operator.

The cleanest approach: in `parse_expr` / `climb`, when we see the `memberof` keyword after a left-hand expression, treat it as an infix operator that takes the right-hand side from the parenthesized name list:

```elixir
# In climb/3, add a clause for memberof
defp climb({:ok, left, [{:keyword, meta, :memberof}, {:lparen, _, _} | rest]}, min_prec) when min_prec <= 7 do
  {names, rest} = collect_identifier_list(rest)
  with {:ok, rest} <- expect(rest, :rparen) do
    node = %AST.BinaryOp{op: :memberof, left: left, right: %AST.Literal{type: :list, value: names, line: meta[:line]}, line: meta[:line]}
    climb({:ok, node, rest}, min_prec)
  end
end
```

- [ ] **Step 4: Add memberof() compilation**

In `lib/anemos/compiler.ex`, add `memberof` to the condition evaluation:

```elixir
defp eval_condition(:memberof, left_val, %AST.Literal{type: :list, value: names}, _context, _bindings) do
  # At compile time, we need the DataStore pid — it will be available in the process dictionary
  # or passed through context at runtime
  data_store = Process.get(:anemos_data_store)

  if data_store do
    Anemos.Runtime.DataStore.member_any?(data_store, names, left_val)
  else
    false
  end
end
```

The DataStore pid needs to be available during handler execution. In the dispatcher, before calling a rule handler, put the DataStore pid in the process dictionary:

In `lib/anemos/runtime/dispatcher.ex`, in the `dispatch_to_rules` function, before calling `rule.handler.()`:

```elixir
Process.put(:anemos_data_store, state.data_store)
```

This follows the existing pattern of using process dictionary (`:anemos_accumulated_ops`).

- [ ] **Step 5: Run test to verify it passes**

Run: `cd /home/imsmith/github/anemos && mix test test/anemos/data_block_test.exs -v 2>&1 | tail -20`
Expected: PASS

- [ ] **Step 6: Run full test suite**

Run: `cd /home/imsmith/github/anemos && mix test 2>&1 | tail -5`
Expected: All tests pass

- [ ] **Step 7: Commit**

```bash
git add lib/anemos/parser.ex lib/anemos/compiler.ex lib/anemos/runtime/dispatcher.ex test/anemos/data_block_test.exs
git commit -m "feat: implement memberof() built-in with DataStore integration"
```

---

### Task 13: End-to-End Query Block Test

**Files:**
- Create: `test/anemos/query_block_test.exs`
- Modify: `lib/anemos/compiler.ex`
- Modify: `lib/anemos/runtime/dispatcher.ex`

- [ ] **Step 1: Write the end-to-end test**

Create `test/anemos/query_block_test.exs`:

```elixir
defmodule Anemos.QueryBlockTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Anemos.{Parser, Compiler}

  test "parses and compiles a query block" do
    input = """
    query find-user {
      expect :name
      users {
        user { name ?name }
      }
      return ?user
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, result} = Compiler.compile(ast)

    assert [query] = result.query_blocks
    assert query.name == "find-user"
    assert query.expect == [:name]
    assert query.engine == "users"
    assert query.return == "user"
    assert is_function(query.handler, 2)
  end

  test "query block compiles alongside rules and data" do
    input = """
    data user-db {
      alice
      bob
    }
    query find-user {
      expect :name
      users {
        lookup ?name
      }
      return ?user
    }
    rule check {
      when LOGIN {
        log "checking"
      }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, result} = Compiler.compile(ast)

    assert length(result.data_blocks) == 1
    assert length(result.query_blocks) == 1
    assert length(result.rules) == 1
  end
end
```

- [ ] **Step 2: Run test to verify it passes** (should pass if prior tasks are complete)

Run: `cd /home/imsmith/github/anemos && mix test test/anemos/query_block_test.exs -v 2>&1 | tail -20`
Expected: PASS

- [ ] **Step 3: Run full test suite**

Run: `cd /home/imsmith/github/anemos && mix test 2>&1 | tail -5`
Expected: All tests pass

- [ ] **Step 4: Commit**

```bash
git add test/anemos/query_block_test.exs
git commit -m "test: end-to-end query block parsing and compilation"
```

---

### Task 14: Full Integration Test — Policy Example

**Files:**
- Modify: `test/anemos/data_block_test.exs`

- [ ] **Step 1: Write a test based on the real policy example**

Add to `test/anemos/data_block_test.exs`:

```elixir
test "parses and compiles the stop-data-extraction policy pattern" do
  input = """
  data reserved-ips {
    10.0.0.0/8
    172.16.0.0/12
    192.168.0.0/16
  }

  data historical-tlds {
    su
    yu
    cs
  }

  rule block-reserved-ips {
    when CONNECTION_INIT {
      if ?src_ip memberof(reserved-ips) {
        log "blocked"
      }
    }
  }
  """

  {:ok, ast} = Parser.parse(input)
  {:ok, result} = Compiler.compile(ast)

  assert length(result.data_blocks) == 2
  assert length(result.rules) == 1

  # Verify data block contents
  reserved = Enum.find(result.data_blocks, &(&1.name == "reserved-ips"))
  assert MapSet.member?(reserved.dataset, "10.0.0.0/8")

  tlds = Enum.find(result.data_blocks, &(&1.name == "historical-tlds"))
  assert MapSet.member?(tlds.dataset, "su")
end

test "full dispatch with memberof against data block" do
  input = """
  data bad-ips {
    1.2.3.4
    5.6.7.8
  }

  rule check {
    when CONN {
      if ?ip memberof(bad-ips) {
        log "blocked"
      } else {
        log "allowed"
      }
    }
  }
  """

  {:ok, ast} = Parser.parse(input)
  {:ok, compiled} = Compiler.compile(ast)
  {:ok, registry} = Anemos.Runtime.ModuleRegistry.start_link()

  {:ok, dispatcher} =
    Anemos.Runtime.Dispatcher.start_link(
      rules: compiled.rules,
      registry: registry
    )

  :ok = Anemos.Runtime.Dispatcher.load(dispatcher, compiled)

  # Bad IP — should be blocked
  results = Anemos.Runtime.Dispatcher.dispatch(dispatcher, "CONN", %{context_data: %{"ip" => "1.2.3.4"}})
  ops = for {:ok, op} <- List.flatten(results), do: op
  assert Enum.any?(ops, &(&1.type == :log && &1.value == "blocked"))

  # Good IP — should be allowed
  results = Anemos.Runtime.Dispatcher.dispatch(dispatcher, "CONN", %{context_data: %{"ip" => "9.9.9.9"}})
  ops = for {:ok, op} <- List.flatten(results), do: op
  assert Enum.any?(ops, &(&1.type == :log && &1.value == "allowed"))
end
```

- [ ] **Step 2: Run test to verify it passes**

Run: `cd /home/imsmith/github/anemos && mix test test/anemos/data_block_test.exs -v 2>&1 | tail -20`
Expected: PASS

- [ ] **Step 3: Run full test suite one final time**

Run: `cd /home/imsmith/github/anemos && mix test 2>&1 | tail -5`
Expected: All tests pass, zero failures

- [ ] **Step 4: Commit**

```bash
git add test/anemos/data_block_test.exs
git commit -m "test: full integration tests for data blocks with memberof dispatch"
```
