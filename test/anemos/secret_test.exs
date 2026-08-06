defmodule Anemos.SecretTest do
  @moduledoc false
  use ExUnit.Case, async: true

  require Logger

  alias Anemos.Secret

  @plaintext "did_key_67890_super_secret"

  describe "construction and exposure" do
    test "wraps a value and exposes it only through expose/1" do
      s = Secret.new(@plaintext)
      assert Secret.expose(s) == @plaintext
      assert Secret.secret?(s)
      refute Secret.secret?(@plaintext)
    end

    test "new/1 is idempotent — wrapping a secret does not double-wrap" do
      s = Secret.new(@plaintext)
      assert Secret.new(s) == s
    end

    test "map/2 transforms the inner value and keeps the wrapper" do
      s = Secret.new("abc") |> Secret.map(&String.upcase/1)
      assert Secret.expose(s) == "ABC"
      assert Secret.secret?(s)
    end
  end

  describe "redaction" do
    test "inspect/1 does not disclose the plaintext" do
      s = Secret.new(@plaintext)
      out = inspect(s)
      refute out =~ @plaintext
      assert out == "#Anemos.Secret<redacted>"
    end

    test "inspect/1 with a label discloses only the label" do
      s = Secret.new(@plaintext, label: "ddns-key")
      out = inspect(s)
      refute out =~ @plaintext
      assert out == "#Anemos.Secret<redacted ddns-key>"
    end

    test "inspect/1 under every option set still redacts" do
      s = Secret.new(@plaintext)

      for opts <- [
            [limit: :infinity, printable_limit: :infinity],
            [pretty: true, width: 10],
            [syntax_colors: [string: :red]],
            [base: :hex, charlists: :as_lists, binaries: :as_binaries]
          ] do
        refute inspect(s, opts) =~ @plaintext
      end
    end

    test "inspect(structs: false) IS a disclosure path — documented, not fixed" do
      # `structs: false` asks Elixir for the raw underlying map and bypasses
      # every Inspect impl in the language. It is an explicit request for the
      # unwrapped term, in the same bucket as expose/1 and term_to_binary/1.
      # Asserted here so the boundary is visible instead of forgotten.
      s = Secret.new(@plaintext)
      assert inspect(s, structs: false) =~ @plaintext
    end

    test "string interpolation does not disclose the plaintext" do
      s = Secret.new(@plaintext)
      out = "#{s}"
      refute out =~ @plaintext
      assert out == "[REDACTED]"
      assert to_string(s) == "[REDACTED]"
    end

    test "charlist conversion does not disclose the plaintext" do
      s = Secret.new(@plaintext)
      refute to_charlist(s) |> List.to_string() =~ @plaintext
    end

    test "nesting inside maps, lists and tuples still redacts" do
      s = Secret.new(@plaintext)

      nested = %{
        "creds" => [s, %{inner: {s, :tagged}}],
        "other" => "visible"
      }

      out = inspect(nested, limit: :infinity, printable_limit: :infinity)
      refute out =~ @plaintext
      assert out =~ "#Anemos.Secret<redacted>"
      assert out =~ "visible"
    end

    test "Logger does not disclose the plaintext for any common formatting path" do
      s = Secret.new(@plaintext)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Logger.info("inspected: #{inspect(s)}")
          Logger.info("interpolated: #{s}")
          Logger.info(fn -> "lazy: #{inspect(%{key: s})}" end)
          Logger.error("in metadata", secret: s)
        end)

      refute log =~ @plaintext
      assert log =~ "redacted"
    end

    test "raising with a secret in the message does not disclose it" do
      s = Secret.new(@plaintext)
      err = %RuntimeError{message: "boom: #{inspect(s)}"}
      refute Exception.message(err) =~ @plaintext
      refute inspect(err) =~ @plaintext
    end

    test "expose/1 is the only disclosure path and it is explicit" do
      s = Secret.new(@plaintext)
      # Sanity: the plaintext really is recoverable when asked for.
      assert Secret.expose(s) == @plaintext
      # And a non-secret passes through unchanged.
      assert Secret.expose("plain") == "plain"
    end
  end

  describe "summarize/1" do
    test "describes shape without contents" do
      assert Anemos.Redact.summarize(Secret.new(@plaintext)) == "secret(redacted)"
      assert Anemos.Redact.summarize("hello") == "binary(5 bytes)"
      assert Anemos.Redact.summarize(%{a: 1, b: 2}) == "map(2 keys)"
      assert Anemos.Redact.summarize([1, 2, 3]) == "list(3 items)"
      assert Anemos.Redact.summarize({1, 2}) == "tuple(2 elements)"
      assert Anemos.Redact.summarize(42) == "integer"
      assert Anemos.Redact.summarize(1.5) == "float"
      assert Anemos.Redact.summarize(:ok) == "atom"
      assert Anemos.Redact.summarize(nil) == "nil"
      assert Anemos.Redact.summarize(%Anemos.Envelope{payload: 1}) =~ "Anemos.Envelope"
    end

    test "never includes the value itself" do
      refute Anemos.Redact.summarize(@plaintext) =~ @plaintext
      refute Anemos.Redact.summarize(%{token: @plaintext}) =~ @plaintext
      refute Anemos.Redact.summarize([@plaintext]) =~ @plaintext
    end
  end
end
