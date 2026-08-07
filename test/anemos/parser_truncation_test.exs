defmodule Anemos.ParserTruncationTest do
  @moduledoc """
  Truncated source must return `{:error, _}`, never raise.

  Regression coverage for A-65. Eight parser functions read
  `token_line(hd(tokens))` before the `case` that followed, so on empty input
  they raised `ArgumentError` and the `[] ->` branch each author had written
  for end-of-input was unreachable. Dialyzer proved the branch dead; the crash
  was why.

  This matters beyond tidiness. `Anemos.Parser.parse/1` promises
  `{:ok, _} | {:error, String.t()}`, and every caller that matches `{:error, _}`
  got an exception instead — including `Anemos.Runtime.LoadAuthority.gate/3`,
  which is the only path from source to an AST. Truncated source is exactly
  what a partially-written or hostile `.rule` file looks like, so this is the
  input the trust boundary is most likely to meet.
  """
  use ExUnit.Case, async: true

  alias Anemos.Parser

  # Each entry truncates the source immediately after a keyword whose parser
  # previously called hd/1 on what turned out to be an empty token list.
  @truncated [
    {"for", ~s|rule r { when E { for|},
    {"each", ~s|rule r { when E { each|},
    {"foreach", ~s|rule r { when E { foreach|},
    {"while", ~s|rule r { when E { while|},
    {"log", ~s|rule r { when E { log|},
    {"emit", ~s|rule r { when E { emit|},
    {"if", ~s|rule r { when E { if|},
    {"return", ~s|rule r { when E { return|}
  ]

  for {keyword, source} <- @truncated do
    test "source truncated after `#{keyword}` returns an error rather than raising" do
      assert {:error, message} = Parser.parse(unquote(source))
      assert is_binary(message)
      refute message == ""
    end
  end

  test "a truncated source never escapes parse/1 as an exception" do
    for {_keyword, source} <- @truncated do
      # parse/1's contract is total over binaries. If any clause reintroduces
      # an unguarded hd/1 this raises rather than returning a tuple.
      assert {:error, _} = Parser.parse(source)
    end
  end

  test "an empty source is still valid and produces no declarations" do
    assert {:ok, %Anemos.AST.Program{declarations: []}} = Parser.parse("")
  end

  # A-74. A-65 fixed eight functions of this shape. These are eight more it did
  # not reach, found by feeding every example file truncated at every byte —
  # 5,955 inputs, of which 87 crashed. The rule that decides who needs a clause
  # like this: whoever knows what must come next owns the end-of-input check.
  # Each function below is a position in the language where something is
  # required to follow, so running out there is an error it has to name.
  @unguarded [
    {"capability", ~s|capability|},
    {"condition", ~s|condition|},
    {"context", ~s|rule r { context|},
    {"when", ~s|rule r { when|},
    {"a compound event's open paren", ~s|rule r { when (|},
    {"let", ~s|rule r { when EV { let|},
    {"emit ... to", ~s|rule r { when EV { emit [EVENT::x to|},
    {"channel(", ~s|rule r { when EV { emit [EVENT::x to channel(|}
  ]

  for {position, source} <- @unguarded do
    test "source truncated after #{position} returns an error rather than raising" do
      assert {:error, message} = Parser.parse(unquote(source))
      assert is_binary(message)
      refute message == ""
    end
  end

  test "no truncation of any shipped example crashes the parser" do
    # The experiment that found A-74, kept as a regression: every prefix of
    # every example, byte by byte. Any parser function that reads the next
    # token without first checking there is one will be caught here.
    crashes =
      for path <- Path.wildcard("priv/examples/*.rule"),
          source = File.read!(path),
          n <- 0..byte_size(source),
          prefix = binary_part(source, 0, n),
          match?({:crash, _}, safe_parse(prefix)) do
        {path, n}
      end

    assert crashes == [],
           "#{length(crashes)} truncations crashed, e.g. #{inspect(Enum.take(crashes, 3))}"
  end

  # Narrow on purpose. `FunctionClauseError` is this defect's signature — a
  # parser function with no clause for the empty token list — and
  # `ArgumentError` was A-65's, from `hd/1` on the same. Any *other* exception
  # is not the shape under test and should fail the run loudly rather than be
  # swallowed into a count.
  defp safe_parse(source) do
    Parser.parse(source)
  rescue
    e in [FunctionClauseError, ArgumentError] -> {:crash, Exception.message(e)}
  end
end
