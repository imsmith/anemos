defmodule Anemos.FlowControlTest do
  @moduledoc false
  use ExUnit.Case

  alias Anemos.AST

  test "Return struct has optional value" do
    node = %AST.Return{value: :expr, line: 1}
    assert node.value == :expr
  end

  test "Return struct defaults value to nil" do
    node = %AST.Return{line: 1}
    assert node.value == nil
  end

  test "Done struct has line" do
    node = %AST.Done{line: 1}
    assert node.line == 1
  end

  test "NextEvent struct has target and optional args" do
    node = %AST.NextEvent{target: "other-handler", args: %{}, line: 1}
    assert node.target == "other-handler"
  end

  test "NextRule struct has target and optional args" do
    node = %AST.NextRule{target: "other-rule", args: %{}, line: 1}
    assert node.target == "other-rule"
  end

  # --- Parser tests ---

  test "parses return with value" do
    input = """
    rule r {
      when EV {
        return "done"
      }
    }
    """

    {:ok, %AST.Program{declarations: [rule]}} = Anemos.Parser.parse(input)
    [%AST.When{body: [%AST.Return{} = r]}] = rule.body
    assert %AST.Literal{value: "done"} = r.value
  end

  test "parses return without value" do
    input = """
    rule r {
      when EV {
        return
        log "unreachable"
      }
    }
    """

    {:ok, %AST.Program{declarations: [rule]}} = Anemos.Parser.parse(input)
    [%AST.When{body: [%AST.Return{} = r, %AST.Log{}]}] = rule.body
    assert r.value == nil
  end

  test "parses done" do
    input = """
    rule r {
      when EV {
        done
      }
    }
    """

    {:ok, %AST.Program{declarations: [rule]}} = Anemos.Parser.parse(input)
    [%AST.When{body: [%AST.Done{}]}] = rule.body
  end

  test "parses nextevent with target" do
    input = """
    rule r {
      when EV {
        nextevent OTHER_HANDLER
      }
    }
    """

    {:ok, %AST.Program{declarations: [rule]}} = Anemos.Parser.parse(input)
    [%AST.When{body: [%AST.NextEvent{} = ne]}] = rule.body
    assert ne.target == "OTHER_HANDLER"
  end

  # --- Compiler tests ---

  test "return stops execution and discards subsequent ops" do
    input = """
    rule r {
      when EV {
        log "before"
        return
        log "after"
      }
    }
    """

    {:ok, results} = Anemos.run(input, event: "EV")
    log_values = for %{type: :log, value: v} <- results, do: v
    assert log_values == ["before"]
  end

  test "done stops execution" do
    input = """
    rule r {
      when EV {
        log "before"
        done
        log "after"
      }
    }
    """

    {:ok, results} = Anemos.run(input, event: "EV")
    log_values = for %{type: :log, value: v} <- results, do: v
    assert log_values == ["before"]
  end

  test "return inside if block exits the handler" do
    input = """
    rule r {
      when EV {
        if true {
          log "in-if"
          return
        }
        log "after-if"
      }
    }
    """

    {:ok, results} = Anemos.run(input, event: "EV")
    log_values = for %{type: :log, value: v} <- results, do: v
    assert log_values == ["in-if"]
  end

  test "return inside while loop exits the handler" do
    input = """
    rule r {
      when EV {
        set i = 0
        while true {
          set i = $i + 1
          if $i == 3 {
            return
          }
          log $i
        }
        log "unreachable"
      }
    }
    """

    {:ok, results} = Anemos.run(input, event: "EV")
    log_values = for %{type: :log, value: v} <- results, do: v
    assert log_values == [1, 2]
  end

  test "return inside for loop exits the handler" do
    input = """
    rule r {
      when EV {
        for item in ?items {
          if @item == 2 {
            return
          }
          log @item
        }
      }
    }
    """

    context = %{context_data: %{"items" => [1, 2, 3]}}
    {:ok, results} = Anemos.run(input, event: "EV", context: context)
    log_values = for %{type: :log, value: v} <- results, do: v
    assert log_values == [1]
  end

  # --- Dispatcher integration tests ---

  test "nextevent re-enters same rule at different when block" do
    input = """
    rule multi {
      when START {
        log "start"
        nextevent STEP_TWO
      }

      when STEP_TWO {
        log "step two"
      }
    }
    """

    {:ok, results} = Anemos.run(input, event: "START")
    log_values = for %{type: :log, value: v} <- results, do: v
    assert "start" in log_values
    assert "step two" in log_values
  end

  test "nextrule dispatches to another rule by name" do
    input = """
    rule first {
      when EV {
        log "first"
        nextrule second
      }
    }

    rule second {
      when OTHER {
        log "second"
      }
    }
    """

    {:ok, results} = Anemos.run(input, event: "EV")
    log_values = for %{type: :log, value: v} <- results, do: v
    assert "first" in log_values
    assert "second" in log_values
  end

  test "nextrule stops executing current handler" do
    input = """
    rule first {
      when EV {
        log "before"
        nextrule second
        log "after-nextrule"
      }
    }

    rule second {
      when OTHER {
        log "second"
      }
    }
    """

    {:ok, results} = Anemos.run(input, event: "EV")
    log_values = for %{type: :log, value: v} <- results, do: v
    assert "before" in log_values
    assert "second" in log_values
    refute "after-nextrule" in log_values
  end

  test "parses nextrule with target" do
    input = """
    rule r {
      when EV {
        nextrule other-rule
      }
    }
    """

    {:ok, %AST.Program{declarations: [rule]}} = Anemos.Parser.parse(input)
    [%AST.When{body: [%AST.NextRule{} = nr]}] = rule.body
    assert nr.target == "other-rule"
  end
end
