# `Anemos.Runtime.Modes`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/runtime/modes.ex#L1)

Modes (PRD §3.13): named, runtime-wide, each active with a value or not
active at all. `[MODE::set "away"]` makes `away` active with the value
`true`, `[MODE::set "level" 2]` with the value `2`, and
`[MODE::unset "away"]` makes it inactive.

`it <mode> { ... }` gates the triggers inside it on the mode holding,
and `as "<mode>"` and `by ... that` run when theirs comes to hold. A
modal reference is `{mode, value}`. It holds when the mode is active and,
for a non-nil `value`, when the mode's value equals it.

`MODE` is the runtime's own module, not a host one. Its state is the
dispatcher's, so a change runs in statement position where the
dispatcher can act on it. `active` and `current` may be read anywhere.

# `ref`

```elixir
@type ref() :: {String.t(), term()}
```

# `t`

```elixir
@type t() :: %{optional(String.t()) =&gt; term()}
```

# `change`

```elixir
@spec change(t(), String.t(), list()) :: {:ok, t(), term()} | {:error, term()}
```

Runs a `MODE` verb in statement position: `{:ok, modes, result}`.

# `holds?`

```elixir
@spec holds?(t(), [ref()]) :: boolean()
```

Whether every modal reference holds.

    iex> Anemos.Runtime.Modes.holds?(%{"away" => true}, [{"away", nil}])
    true

    iex> Anemos.Runtime.Modes.holds?(%{"level" => 1}, [{"level", 2}])
    false

# `read`

```elixir
@spec read(t(), String.t(), list()) :: {:ok, term()} | {:error, term()}
```

Runs a `MODE` verb in value position. Only `active` and `current` read;
`set` and `unset` are refused here.

    iex> Anemos.Runtime.Modes.read(%{"away" => "weekend"}, "current", ["away"])
    {:ok, "weekend"}

    iex> Anemos.Runtime.Modes.read(%{"b" => true, "a" => 1}, "current", [])
    {:ok, ["a", "b"]}

---

*Consult [api-reference.md](api-reference.md) for complete listing*
