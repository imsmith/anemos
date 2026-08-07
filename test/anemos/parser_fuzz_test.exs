defmodule Anemos.ParserFuzzTest do
  @moduledoc """
  A-75. `Anemos.Parser.parse/1` must answer a tuple for *any* binary, and must
  terminate.

  A-74 established totality against input that **runs out** — every prefix of
  every shipped example. A prefix is always a valid source with a clean cut, so
  it never holds a token in a position the language disallows. This covers the
  other class: input **wrong in the middle**. Tokens deleted, duplicated,
  swapped and substituted; brackets added and dropped; bytes flipped, inserted
  and removed; invalid UTF-8 spliced in.

  It matters for the reason A-74 did. `parse/1` is the only path from source to
  an AST (`Anemos.Runtime.LoadAuthority.gate/3`), and under the multi-tenant
  decision its input is untrusted. A-74 was found the first time this class was
  tested at all — eight crashes on the first run.

  ## This test can fail

  Verified rather than assumed: run against `lib/anemos/parser.ex` as of
  `73c3637~1`, the same generator reports the A-74 crashes, including
  `parse_destination/1`'s `CaseClauseError` reached by a *malformed* input
  rather than a truncated one. A fuzzer nobody has watched fail is decoration.

  ## Determinism

  The seed is fixed so a failure reproduces exactly, and it is printed in the
  failure message. `ANEMOS_FUZZ_SEED` and `ANEMOS_FUZZ_CASES` override it for
  longer or differently-seeded runs without editing this file.
  """
  use ExUnit.Case, async: true

  alias Anemos.SourceMutator

  # ~0.5 ms per case. 2,000 keeps this around a second in a suite that runs in
  # six; the env vars exist for the long soak that does not belong in CI.
  @cases String.to_integer(System.get_env("ANEMOS_FUZZ_CASES") || "2000")
  @seed String.to_integer(System.get_env("ANEMOS_FUZZ_SEED") || "20260807")

  # Generous on purpose. This is not a performance assertion — it is the
  # difference between "slow" and "does not return", and only the latter is a
  # defect on the untrusted path.
  @timeout_ms 2_000

  setup_all do
    corpus =
      "priv/examples/*.rule"
      |> Path.wildcard()
      |> Enum.map(&File.read!/1)

    # A corpus that silently went missing would make every assertion below pass
    # while testing nothing.
    assert corpus != [], "no example .rule files found to mutate"

    {:ok, corpus: corpus}
  end

  test "no mutation of a shipped example makes the parser die or hang", %{corpus: corpus} do
    :rand.seed(:exsss, {@seed, @seed + 1, @seed + 2})

    failures =
      for _ <- 1..@cases,
          source = SourceMutator.mutate_chain(Enum.random(corpus)),
          verdict = SourceMutator.check(source, @timeout_ms),
          verdict != :ok do
        {source, verdict}
      end

    assert failures == [], format(failures)
  end

  test "the mutations actually reach the parser, not just the lexer", %{corpus: corpus} do
    # A generator whose output all dies in the lexer would pass the test above
    # while exercising none of the code it claims to cover. Byte-level
    # mutations are *meant* to produce lexer garbage; chunk-level ones are not,
    # and this asserts the mix stays useful.
    :rand.seed(:exsss, {@seed + 100, @seed + 101, @seed + 102})

    reached =
      Enum.count(1..500, fn _ ->
        corpus
        |> Enum.random()
        |> SourceMutator.mutate_chain()
        |> SourceMutator.classify(@timeout_ms)
        |> Kernel.!=(:lexer_error)
      end)

    assert reached > 150,
           "only #{reached}/500 mutated sources got past the lexer; the generator is " <>
             "producing garbage rather than malformed policy"
  end

  test "every mutation kind can be applied without raising", %{corpus: corpus} do
    # Guards the generator itself. A mutator that crashes on some input would
    # otherwise fail the run above as though the parser were at fault.
    :rand.seed(:exsss, {@seed + 200, @seed + 201, @seed + 202})

    for kind <- SourceMutator.kinds(), source <- corpus ++ ["", " ", "{"] do
      mutated = SourceMutator.mutate(source, kind)
      assert is_binary(mutated), "#{kind} returned a non-binary for #{inspect(source)}"
    end
  end

  defp format([]), do: ""

  defp format(failures) do
    {source, verdict} = Enum.min_by(failures, fn {s, _} -> byte_size(s) end)
    shrunk = SourceMutator.shrink(source, @timeout_ms)

    """
    #{length(failures)} of #{@cases} mutated sources violated parse/1's contract.

    Reproduce with: ANEMOS_FUZZ_SEED=#{@seed} ANEMOS_FUZZ_CASES=#{@cases} mix test #{__ENV__.file |> Path.relative_to_cwd()}

    Smallest failure, shrunk to #{byte_size(shrunk)} bytes:
    #{inspect(shrunk, limit: :infinity, printable_limit: 600)}

    Verdict: #{inspect(verdict)}
    """
  end
end
