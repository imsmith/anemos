# Anemos

Anemos is an event-driven automation language on the BEAM. Write policies that
listen for events, make decisions, retain state, and invoke commands supplied
by an Elixir host application.

**Start with [Programming Anemos](docs/manual/README.md)**, the user manual.
It teaches the language from first principles, then covers embedding,
deployment, troubleshooting, and the full language reference.

## A first rule

```text
rule garage-motion {
  context "garage" {
    when MOTION {
      log "Garage motion detected"
    }
  }
}
```

The rule listens for `MOTION` events arriving from `garage` or a descendant
context such as `garage.sensor`. Its body runs when an eligible event arrives.
Host actions use commands such as `[DEVICE::set "garage.lights" "on"]`;
the host registers the implementation behind each module and verb.

## Build and try it

Use the Erlang/Elixir versions in [.tool-versions](.tool-versions). The project
requires Elixir `~> 1.20`.

```sh
mix deps.get
mix compile
mix anemos.run docs/manual/examples/garage.rule \
  --event MOTION --context garage.sensor
```

Dependencies are pinned in `mix.lock`; no sibling checkout is required.
The CLI dispatches one event and exits. Payload fields can be supplied as
repeatable `--context-data KEY=VALUE` options; these values are strings.
See [the first chapter](docs/manual/01-first-policy.md) for a guided session.

Run the accompanying examples, which check their own answers:

```sh
mix run docs/manual/examples/walkthrough.exs
mix run docs/manual/examples/data_models.exs
mix run docs/manual/examples/workshop.exs
```

## Embed a persistent interpreter

```elixir
children = [{Anemos.Runtime, name: :anemos}]
Supervisor.start_link(children, strategy: :one_for_one)

# This log-only policy needs no command modules.
source = File.read!("docs/manual/examples/garage.rule")
:ok = Anemos.Runtime.load(:anemos, source, policy: "garage.rule")
{:ok, results} = Anemos.Runtime.dispatch(:anemos, "MOTION",
  %{context_path: "garage.sensor", context_data: %{}})
```

Register host command modules before using them. The persistent runtime starts
with `POLICY`; it does not inherit the one-shot runner's development `DEVICE`
and `FILE` stubs. Those stubs perform no external I/O. The other bundled
example doubles require explicit opt-in with `--stub-modules` or
`modules: Anemos.example_modules()`.

Named loads replace the previous contents of that policy ID. Inspect all
load outcomes: `:ok`, `{:partial, failures}` (installed with inert declarations),
and `{:error, reason}` (not installed). An outer `{:ok, results}` from dispatch
can contain individual `{:error, reason}` entries.

See [embedding](docs/manual/09-embedding.md) for complete module, event,
channel, and data-handler examples, and [operation](docs/manual/10-operation.md)
for policy replacement, directory watching, signing, and recovery.

## Documentation

[Programming Anemos](docs/manual/README.md) contains twelve chapters, a language
and API reference, a glossary, a subject index, exercises, and runnable examples.
For direct lookup:

- [Values, sigils, and operators](docs/manual/03-values-and-expressions.md)
- [Conditions and capabilities](docs/manual/06-conditions-and-capabilities.md)
- [Time and duration](docs/manual/07-time.md)
- [Datasets, queries, and facts](docs/manual/08-data.md)
- [Troubleshooting](docs/manual/11-troubleshooting.md)
- [Language reference and implementation limits](docs/manual/reference.md)

Generate the navigable manual and module API documentation together:

```sh
mix docs
# Open doc/index.html in a browser.
```

The historical [design notes](docs/design-notes/README.md) describe motivation
and possible extensions. The manual describes current behavior. In particular,
read its feature-status table before relying on demand gating, `until`, triple
query values, pipeline `emit`, or schedules inside context boundaries.

## Development

```sh
mix check
mix test test/anemos/manual_test.exs
```

`mix check` runs formatting, strict Credo, and the test suite. `mix dialyzer`
is a separate optional analysis. Documentation tests parse and compile every
complete `anemos` listing and exercise the main tutorial behaviors.

## License

[AGPL-3.0-or-later](LICENSE).
