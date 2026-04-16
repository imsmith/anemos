defmodule Anemos.QueryBlockTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Anemos.{Parser, Compiler}

  test "parses and compiles a query block" do
    input = """
    query find-user {
      expect :name
      users {
        lookup ?name
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
    query find {
      expect :name
      db { select ?name }
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

  test "query block handler returns engine info" do
    input = """
    query city-lookup {
      expect :city
      wikidata {
        SELECT ?city WHERE { ?city :type :city }
      }
      return ?city
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, result} = Compiler.compile(ast)

    assert [query] = result.query_blocks
    {:ok, result} = query.handler.(%{city: "Paris"}, %{})
    assert result.engine == "wikidata"
    assert is_binary(result.body)
    assert result.bindings == %{city: "Paris"}
  end
end
