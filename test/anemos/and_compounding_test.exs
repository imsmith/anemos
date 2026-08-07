defmodule Anemos.AndCompoundingTest do
  @moduledoc """
  A-73. `AND` over non-boolean operands compounds; over booleans it conjoins.

  The defect this pins was `l && r`, which in Elixir *answers `r`* whenever
  `l` is truthy — so the left operand was evaluated and thrown away.
  """
  use ExUnit.Case, async: true

  defp logged(source, opts \\ []) do
    {:ok, ops} = Anemos.run(source, Keyword.merge([event: "EV"], opts))
    for %{type: :log, value: v} <- ops, do: v
  end

  describe "compounding over non-boolean operands (A-73)" do
    test "a single triple pattern is a flat four-element list" do
      source = """
      rule r {
        when EV {
          let update = (:h IN A "1.2.3.4")
          log @update
        }
      }
      """

      assert logged(source) == [["h", "IN", "A", "1.2.3.4"]]
    end

    test "two triples compound to a two-element list, keeping the left operand" do
      source = """
      rule r {
        when EV {
          let update = (:h IN A "1.1.1.1") AND (:h IN AAAA "::1")
          log @update
        }
      }
      """

      assert logged(source) == [
               [
                 ["h", "IN", "A", "1.1.1.1"],
                 ["h", "IN", "AAAA", "::1"]
               ]
             ]
    end

    test "three triples compound to a three-element list, not a nested pair" do
      source = """
      rule r {
        when EV {
          let update = (:h IN A "1") AND (:h IN AAAA "2") AND (:h IN TXT "3")
          log @update
        }
      }
      """

      assert logged(source) == [
               [
                 ["h", "IN", "A", "1"],
                 ["h", "IN", "AAAA", "2"],
                 ["h", "IN", "TXT", "3"]
               ]
             ]
    end

    test "lowercase `and` is the same operator and compounds too" do
      source = """
      rule r {
        when EV {
          let update = (:h IN A "1") and (:h IN AAAA "2")
          log @update
        }
      }
      """

      assert logged(source) == [[["h", "IN", "A", "1"], ["h", "IN", "AAAA", "2"]]]
    end

    test "compounded strings keep both operands" do
      source = """
      rule r {
        when EV {
          let both = ?a AND ?b
          log @both
        }
      }
      """

      assert logged(source, context_data: %{"a" => "left", "b" => "right"}) == [
               ["left", "right"]
             ]
    end
  end

  describe "logical conjunction over boolean operands is retained" do
    test "an if condition over two comparisons still conjoins" do
      source = """
      rule r {
        when EV {
          if ?x eq 1 AND ?y eq 2 {
            log "both"
          } else {
            log "not both"
          }
        }
      }
      """

      assert logged(source, context_data: %{"x" => 1, "y" => 2}) == ["both"]
      assert logged(source, context_data: %{"x" => 1, "y" => 9}) == ["not both"]
      assert logged(source, context_data: %{"x" => 9, "y" => 2}) == ["not both"]
    end

    test "three comparisons conjoin, and one false operand is enough to fail" do
      source = """
      rule r {
        when EV {
          if ?x eq 1 AND ?y eq 2 AND ?z eq 3 {
            log "all"
          } else {
            log "not all"
          }
        }
      }
      """

      assert logged(source, context_data: %{"x" => 1, "y" => 2, "z" => 3}) == ["all"]
      assert logged(source, context_data: %{"x" => 1, "y" => 2, "z" => 9}) == ["not all"]
      assert logged(source, context_data: %{"x" => 1, "y" => 9, "z" => 3}) == ["not all"]
    end

    test "a block unless-guard over AND comparisons is unchanged" do
      source = """
      rule r {
        when EV unless ?a eq 1 AND ?b eq 2 {
          log "ran"
        }
      }
      """

      assert logged(source, context_data: %{"a" => 1, "b" => 2}) == []
      assert logged(source, context_data: %{"a" => 1, "b" => 9}) == ["ran"]
    end

    test "an absent operand still makes the whole AND falsey" do
      source = """
      rule r {
        when EV {
          if ?missing AND ?present {
            log "yes"
          } else {
            log "no"
          }
        }
      }
      """

      assert logged(source, context_data: %{"present" => "here"}) == ["no"]
    end
  end

  describe "mixed operands" do
    test "a true operand is the identity of AND and drops out of the compound" do
      source = """
      rule r {
        when EV {
          let update = true AND (:h IN A "1.2.3.4")
          log @update
        }
      }
      """

      assert logged(source) == [["h", "IN", "A", "1.2.3.4"]]
    end

    test "a false operand answers false rather than compounding" do
      source = """
      rule r {
        when EV {
          let update = false AND (:h IN A "1.2.3.4")
          if @update {
            log "truthy"
          } else {
            log "falsey"
          }
        }
      }
      """

      assert logged(source) == ["falsey"]
    end
  end

  describe "the symbolic && stays logical" do
    test "&& over non-boolean operands answers the right operand" do
      source = """
      rule r {
        when EV {
          let update = (:h IN A "1.1.1.1") && (:h IN AAAA "::1")
          log @update
        }
      }
      """

      assert logged(source) == [["h", "IN", "AAAA", "::1"]]
    end
  end
end
