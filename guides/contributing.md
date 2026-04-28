# Contributing

This repo follows a parity-first workflow against the upstream Python GEPA repository while keeping Elixir-native boundaries.

## Development Loop

Use TDD/RGR:

1. Red: identify or add the smallest failing test, source-policy check, docs expectation, or live-smoke command.
2. Green: make the smallest implementation or documentation change that passes it.
3. Refactor: simplify while keeping the targeted check green.

## Quality Gate

Run the full gate before a checkpoint commit:

```bash
mix format --check-formatted
mix compile --warnings-as-errors --force
mix test
mix docs
mix dialyzer
mix credo --strict
```

For live integration work, also run the relevant live smoke command, for example:

```bash
docker compose up -d qdrant
examples/run_all.sh --simple --provider gemini --timeout 120000 --max-metric-calls 1
```

## Scope Rules

- Keep examples live-only.
- Keep deterministic providers in tests.
- Prefer behaviors/facades over provider-specific coupling.
- Do not add MCP runtime, transports, live examples, or user guides unless scope is explicitly reopened.
- Keep Qdrant replaceable behind the vector-store behavior.
- Keep W&B and MLflow replaceable behind `GEPA.Tracking`.

## Documentation

New user-facing docs belong in `guides/*.md` and must be added to `mix.exs` `extras` and `groups_for_extras`.

Use `examples/README.md` for example run instructions. Use module docs for API-level contracts.
