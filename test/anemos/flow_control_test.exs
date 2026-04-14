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
