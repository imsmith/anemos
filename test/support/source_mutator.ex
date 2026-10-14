defmodule Anemos.SourceMutator do
  @moduledoc """
  Mutation generator and process-level oracle for A-75's parser fuzzing.

  A-74's sweep established that `Anemos.Parser.parse/1` is total against input
  that **runs out** — every prefix of every shipped example. A prefix is always
  a valid source with a clean cut, so it never contains a token in a position
  the language disallows. This module produces the other class: input that is
  **wrong in the middle**.

  ## The oracle does not rescue

  Each parse runs in an unlinked process and the monitor reports how it ended.
  An exception, an exit, a throw and a non-terminating parse are then all
  observed the same way, rather than three of them being caught by a `rescue`
  that names the wrong types and the fourth being missed entirely. A hang on
  the path from untrusted source to an AST is no better than a crash, and
  nothing else in the suite bounds parse time.

  ## Determinism

  Nothing here seeds the RNG. The caller does, so a failing run reproduces from
  the seed printed in its own message. Callers should seed `:rand` explicitly
  rather than relying on process defaults.
  """

  @chunk ~r/"(?:[^"\\]|\\.)*"|[A-Za-z_][A-Za-z0-9_.\-]*|::|[{}()\[\]]|\S|\s+/

  @brackets ["{", "}", "(", ")", "[", "]"]

  @punctuation [
    ":",
    ";",
    ",",
    "::",
    "=",
    "==",
    "!=",
    "<",
    ">",
    "+",
    "-",
    "*",
    "/",
    "%",
    "&",
    "|",
    "^",
    "!",
    "?",
    "@",
    "$"
  ]

  @keywords ~w(rule condition capability data query when if else elseif let set
               emit demand context signed_by version scope at every for each while
               return done nextevent nextrule with to channel service self and or not)

  @literals ["\"str\"", "42", "-1", "0x1F", ":atom", "?var", "@var", "$var", "EV", "MOD::verb"]

  @vocab @brackets ++ @punctuation ++ @keywords ++ @literals

  @kinds [
    :delete_chunk,
    :duplicate_chunk,
    :swap_chunks,
    :replace_chunk,
    :insert_bracket,
    :drop_bracket,
    :flip_byte,
    :insert_byte,
    :delete_byte,
    :invalid_utf8
  ]

  @doc "The mutation kinds this module can apply."
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc """
  Splits a source into lexical chunks — strings, words, `::`, brackets, single
  punctuation, runs of whitespace.

  An approximation of the lexer's own tokens, used because tokens carry a line
  but no byte offset, so they cannot be spliced back into text. Rejoining the
  chunks reproduces the source exactly, which is what makes the chunk-level
  mutations below meaning-preserving except where they mean to be.
  """
  @spec chunks(binary()) :: [binary()]
  def chunks(source), do: @chunk |> Regex.scan(source) |> Enum.map(&hd/1)

  @doc """
  Applies one mutation of the given kind. Returns the source unchanged when the
  kind cannot apply — an empty source has no chunk to delete.
  """
  @spec mutate(binary(), atom()) :: binary()
  def mutate(source, :delete_chunk) do
    with_chunks(source, fn c -> c |> List.delete_at(index(c)) |> Enum.join() end)
  end

  def mutate(source, :duplicate_chunk) do
    with_chunks(source, fn c ->
      i = index(c)
      c |> List.insert_at(i, Enum.at(c, i)) |> Enum.join()
    end)
  end

  def mutate(source, :swap_chunks) do
    c = chunks(source)

    if length(c) < 2 do
      source
    else
      i = :rand.uniform(length(c) - 1) - 1
      {a, b} = {Enum.at(c, i), Enum.at(c, i + 1)}
      c |> List.replace_at(i, b) |> List.replace_at(i + 1, a) |> Enum.join()
    end
  end

  def mutate(source, :replace_chunk) do
    with_chunks(source, fn c ->
      c |> List.replace_at(index(c), Enum.random(@vocab)) |> Enum.join()
    end)
  end

  def mutate(source, :insert_bracket) do
    c = chunks(source)
    at = if c == [], do: 0, else: index(c)
    c |> List.insert_at(at, Enum.random(@brackets)) |> Enum.join()
  end

  def mutate(source, :drop_bracket) do
    c = chunks(source)
    positions = for {v, i} <- Enum.with_index(c), v in @brackets, do: i

    if positions == [] do
      source
    else
      c |> List.delete_at(Enum.random(positions)) |> Enum.join()
    end
  end

  def mutate(source, :flip_byte) when byte_size(source) > 0 do
    i = :rand.uniform(byte_size(source)) - 1
    <<head::binary-size(^i), _replaced, tail::binary>> = source
    <<head::binary, :rand.uniform(255), tail::binary>>
  end

  def mutate(source, :insert_byte) do
    i = :rand.uniform(byte_size(source) + 1) - 1
    <<head::binary-size(^i), tail::binary>> = source
    <<head::binary, :rand.uniform(255), tail::binary>>
  end

  def mutate(source, :delete_byte) when byte_size(source) > 0 do
    i = :rand.uniform(byte_size(source)) - 1
    <<head::binary-size(^i), _dropped, tail::binary>> = source
    <<head::binary, tail::binary>>
  end

  def mutate(source, :invalid_utf8) do
    i = :rand.uniform(byte_size(source) + 1) - 1
    <<head::binary-size(^i), tail::binary>> = source
    <<head::binary, 0xFF, 0xFE, tail::binary>>
  end

  def mutate(source, _inapplicable), do: source

  @doc """
  Applies between one and `depth` randomly chosen mutations in sequence.

  Chained rather than single because a defect needing two independent edits —
  an unbalanced brace *and* a wrong token — is unreachable one mutation at a
  time.
  """
  @spec mutate_chain(binary(), pos_integer()) :: binary()
  def mutate_chain(source, depth \\ 3) do
    Enum.reduce(1..:rand.uniform(depth), source, fn _step, acc ->
      mutate(acc, Enum.random(@kinds))
    end)
  end

  @doc """
  Runs `Anemos.Parser.parse/1` on `source` under a time limit, in a process of
  its own.

  Returns `:ok` when the contract holds — `{:ok, %AST.Program{}}` or
  `{:error, %Comn.Errors.ErrorStruct{}}` — and a description of the violation otherwise.
  """
  @spec check(binary(), pos_integer()) :: :ok | tuple()
  def check(source, timeout_ms) do
    parent = self()
    {pid, ref} = spawn_monitor(fn -> send(parent, {__MODULE__, self(), verdict(source)}) end)

    receive do
      {__MODULE__, ^pid, verdict} ->
        drain(ref, pid)
        verdict

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:died, summarize(reason)}
    after
      timeout_ms ->
        Process.exit(pid, :kill)
        drain(ref, pid)
        {:hang, timeout_ms}
    end
  end

  @doc """
  Where a source ends up: `:parsed`, `:lexer_error`, `:parser_error`, or the
  same failure tuples `check/2` returns.

  Process-isolated for the same reason `check/2` is — a coverage measurement
  must not be the thing that dies when the parser has a defect, or the failure
  gets reported against the wrong test.
  """
  @spec classify(binary(), pos_integer()) :: atom() | tuple()
  def classify(source, timeout_ms) do
    parent = self()
    {pid, ref} = spawn_monitor(fn -> send(parent, {__MODULE__, self(), where(source)}) end)

    receive do
      {__MODULE__, ^pid, result} ->
        drain(ref, pid)
        result

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:died, summarize(reason)}
    after
      timeout_ms ->
        Process.exit(pid, :kill)
        drain(ref, pid)
        {:hang, timeout_ms}
    end
  end

  @doc """
  Reduces a failing source while it keeps failing, by dropping one chunk at a
  time.

  A raw failing case is a whole mutated example and unreadable as a bug report;
  the shrunk one is usually a line or two. `fuel` bounds the work so a
  pathological case cannot stall the suite.
  """
  @spec shrink(binary(), pos_integer(), non_neg_integer()) :: binary()
  def shrink(source, timeout_ms, fuel \\ 200)

  def shrink(source, _timeout_ms, 0), do: source

  def shrink(source, timeout_ms, fuel) do
    c = chunks(source)

    smaller =
      Enum.find_value(0..max(length(c) - 1, 0), fn i ->
        candidate = c |> List.delete_at(i) |> Enum.join()
        if candidate != source and check(candidate, timeout_ms) != :ok, do: candidate
      end)

    if smaller, do: shrink(smaller, timeout_ms, fuel - 1), else: source
  end

  # --- internals ---

  defp verdict(source) do
    case Anemos.Parser.parse(source) do
      {:ok, %Anemos.AST.Program{}} -> :ok
      {:error, %Comn.Errors.ErrorStruct{message: message}} when is_binary(message) -> :ok
      other -> {:bad_return, other |> inspect() |> String.slice(0, 160)}
    end
  end

  defp where(source) do
    case Anemos.Parser.parse(source) do
      {:ok, %Anemos.AST.Program{}} -> :parsed
      {:error, %Comn.Errors.ErrorStruct{code: "anemos.lexer/" <> _}} -> :lexer_error
      {:error, %Comn.Errors.ErrorStruct{code: "anemos.parser/" <> _}} -> :parser_error
      other -> {:bad_return, other |> inspect() |> String.slice(0, 160)}
    end
  end

  defp with_chunks(source, fun) do
    case chunks(source) do
      [] -> source
      c -> fun.(c)
    end
  end

  defp index(list), do: :rand.uniform(length(list)) - 1

  defp drain(ref, pid) do
    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      1_000 -> :ok
    end
  end

  defp summarize({%{__struct__: module}, stack}) when is_list(stack) do
    {module, stack |> Enum.take(2) |> inspect() |> String.slice(0, 200)}
  end

  defp summarize(reason), do: reason |> inspect() |> String.slice(0, 200)
end
