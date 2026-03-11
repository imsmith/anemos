# Anemos

An event-driven automation DSL built on the BEAM. Anemos lets you define
reactive rules that listen for events, evaluate conditions, and execute
operations — all expressed in a concise, domain-specific language.

## Example

```
rule garage-lights-on {
  context "garage.motion.sensor" {
    when SENSOR_MOTION_DETECTED {
      [DEVICE::set "garage.lights" "on"]
    }
  }
}

rule garage-lights-off {
  context "garage.motion.sensor" {
    when SENSOR_NO_MOTION for 10min {
      [DEVICE::set "garage.lights" "off"]
    }
  }
}
```

More examples in `priv/examples/`.

## Install and Run

Requires Elixir 1.19+ / OTP 28+.

```bash
git clone <repo-url> && cd anemos
mix deps.get
mix compile
```

### Usage

```bash
mix anemos.run <file> --event <EVENT_NAME>
```

Examples:

```bash
$ mix anemos.run priv/examples/garage-lights.rule --event SENSOR_MOTION_DETECTED
Parsing priv/examples/garage-lights.rule...
Dispatched SENSOR_MOTION_DETECTED -- 1 operation(s):

  [DEVICE::set "garage.lights" "on"]

$ mix anemos.run priv/examples/garage-lights.rule --event SENSOR_NO_MOTION
Parsing priv/examples/garage-lights.rule...
Dispatched SENSOR_NO_MOTION -- 1 operation(s):

  [DEVICE::set "garage.lights" "off"]
```

### Programmatic API

```elixir
source = File.read!("priv/examples/garage-lights.rule")
{:ok, results} = Anemos.run(source, event: "SENSOR_MOTION_DETECTED")
```

## Pipeline

The core pipeline works end-to-end:

1. **Lexer** — tokenizes `.rule` source files
2. **Parser** — produces a typed AST
3. **Compiler** — compiles AST nodes into executable closures
4. **Dispatcher** — routes events to matching rule handlers
5. **Module Registry** — resolves command targets at dispatch time

## Project Status

**v0.1.0** — Core pipeline is functional. Not production-ready. No external
integrations, no persistence, no real module backends yet. This release proves
out the language design and execution model.

## Language Spec

See `docs/plans/2026-03-10-anemos-v0.1.0.md` for the full design notes and
language specification.

## License

AGPL-3.0
