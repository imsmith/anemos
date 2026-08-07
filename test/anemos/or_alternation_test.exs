defmodule Anemos.OrAlternationTest do
  @moduledoc """
  `OR` is alternation, made explicit — the counterpart of A-73's decision on
  `AND`.

  `AND` answers *every* operand; `OR` answers the *first available* one. The
  algebra is conjunction's dual: `true` is absorbing, `false` and `nil` are the
  identity and drop out, and when every operand is falsey the first one answers.

  The spine is flattened on the AST for the same reason it is for `AND` — so the
  decision is taken once over the whole chain rather than pairwise at runtime,
  where a triple pattern and an already-decided alternation are both just lists.
  """
  use ExUnit.Case, async: true

  alias Anemos.{Compiler, Parser}
  alias Anemos.Runtime.ModuleRegistry

  # A-56 forbids short-circuiting: an operand may be a module call whose side
  # effect is the point, so it happens whether or not its value is reachable.
  defmodule Recorder do
    @moduledoc false
    @behaviour Anemos.Runtime.Module

    @impl true
    def handle_verb(verb, _args, context) do
      send(Map.fetch!(context, :test_pid), {:called, verb})
      {:ok, verb}
    end
  end

  defp logged(source, opts \\ []) do
    {:ok, ops} = Anemos.run(source, Keyword.merge([event: "EV"], opts))
    for %{type: :log, value: v} <- ops, do: v
  end

  describe "alternation over non-boolean operands" do
    test "two triples answer the first, not a compound" do
      source = """
      rule r {
        when EV {
          let update = (:h IN A "1.1.1.1") OR (:h IN AAAA "::1")
          log @update
        }
      }
      """

      assert logged(source) == [["h", "IN", "A", "1.1.1.1"]]
    end

    test "three triples answer the first, not the last and not a nest" do
      source = """
      rule r {
        when EV {
          let update = (:h IN A "1") OR (:h IN AAAA "2") OR (:h IN TXT "3")
          log @update
        }
      }
      """

      assert logged(source) == [["h", "IN", "A", "1"]]
    end

    test "lowercase `or` is the same operator" do
      source = """
      rule r {
        when EV {
          let update = (:h IN A "1") or (:h IN AAAA "2")
          log @update
        }
      }
      """

      assert logged(source) == [["h", "IN", "A", "1"]]
    end

    test "an absent left operand falls through to the right" do
      source = """
      rule r {
        when EV {
          let pick = ?missing OR ?present
          log @pick
        }
      }
      """

      assert logged(source, context_data: %{"present" => "here"}) == ["here"]
    end

    test "the first present operand of three wins, later ones do not override" do
      source = """
      rule r {
        when EV {
          let pick = ?a OR ?b OR ?c
          log @pick
        }
      }
      """

      assert logged(source, context_data: %{"b" => "second", "c" => "third"}) == ["second"]
    end
  end

  describe "logical disjunction over boolean operands is retained" do
    test "an if condition over two comparisons still disjoins" do
      source = """
      rule r {
        when EV {
          if ?x eq 1 OR ?y eq 2 {
            log "either"
          } else {
            log "neither"
          }
        }
      }
      """

      assert logged(source, context_data: %{"x" => 1, "y" => 9}) == ["either"]
      assert logged(source, context_data: %{"x" => 9, "y" => 2}) == ["either"]
      assert logged(source, context_data: %{"x" => 9, "y" => 9}) == ["neither"]
    end

    test "three comparisons disjoin, and one true operand is enough to pass" do
      source = """
      rule r {
        when EV {
          if ?x eq 1 OR ?y eq 2 OR ?z eq 3 {
            log "any"
          } else {
            log "none"
          }
        }
      }
      """

      assert logged(source, context_data: %{"x" => 9, "y" => 9, "z" => 3}) == ["any"]
      assert logged(source, context_data: %{"x" => 9, "y" => 9, "z" => 9}) == ["none"]
    end
  end

  describe "mixed operands" do
    test "a false operand is the identity of OR and drops out" do
      source = """
      rule r {
        when EV {
          let update = false OR (:h IN A "1.2.3.4")
          log @update
        }
      }
      """

      assert logged(source) == [["h", "IN", "A", "1.2.3.4"]]
    end

    test "a true operand is absorbing and answers for the whole expression" do
      source = """
      rule r {
        when EV {
          let update = true OR (:h IN A "1.2.3.4")
          log @update
        }
      }
      """

      assert logged(source) == [true]
    end

    test "a trailing true does not absorb an earlier value operand" do
      # Alternation is ordered, so `true` answers only when it is the first
      # available operand. Strict duality with `AND` — where a falsey operand
      # is absorbing wherever it sits — would answer `true` here instead. That
      # is deliberately not what happens: `(A) OR true` reads as "A, or else
      # true", and a fallback that discards the value it was a fallback for
      # would make `OR` useless in value position.
      source = """
      rule r {
        when EV {
          let update = (:h IN A "1.2.3.4") OR true
          log @update
        }
      }
      """

      assert logged(source) == [["h", "IN", "A", "1.2.3.4"]]
    end

    test "when every operand is falsey the first one answers" do
      source = """
      rule r {
        when EV {
          let update = false OR ?missing
          log @update
        }
      }
      """

      # `false` and not `nil`: pairwise `||` used to answer the *last* falsey
      # operand, which is the one behaviour this change actually alters.
      assert logged(source) == [false]
    end
  end

  describe "evaluation is eager over the whole spine (A-56)" do
    test "a module call in a later operand is dispatched even when an earlier one answers" do
      source = """
      rule r {
        when EV {
          let pick = ?present OR [REC::second] OR [REC::third]
          log @pick
        }
      }
      """

      {:ok, ast} = Parser.parse(source)
      {:ok, %{rules: [compiled]}} = Compiler.compile(ast)
      {:ok, registry} = ModuleRegistry.start_link([])
      :ok = ModuleRegistry.register(registry, "REC", Recorder)

      context = %{
        registry: registry,
        _verb_context: %{test_pid: self()},
        context_data: %{"present" => "here"}
      }

      {:ok, ops, _bindings} = compiled.handler.("EV", context, %{})

      assert [%{type: :log, value: "here"}] = ops
      assert_received {:called, "second"}
      assert_received {:called, "third"}
    end
  end
end
