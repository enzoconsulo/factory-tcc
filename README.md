# Factory — a multi-agent software factory

**English** · [Português (BR)](README.pt-BR.md)

Final-year thesis (TCC) project. The system takes a project request in natural language and
builds it end to end: agents plan, implement, verify and review the work, each with limited
authority. Governance is enforced by the structure of the program, not by instructions in the
prompt:

| Rule | Where it lives |
|---|---|
| Never write outside the project | the file tools refuse the path; the agent's shell runs sandboxed |
| At most three attempts | a counter in the database that agents cannot change |
| Whoever builds does not approve | the reviewer gets no write tool |
| Never exceed the budget | work that does not fit the ceiling never starts |

## Following this repository (TCC)

Development follows a waterfall plan: **each stage is a branch**, created from the previous
one, with one commit per deliverable. On the day each stage is presented, its branch is merged
into `main`. Branch names keep the Portuguese word for stage (`etapa`).

| Branch | Stage | Deliverable |
|---|---|---|
| `etapa/e1-planejamento` | E1 · Planning and architecture | requirements, architecture, tasks, criteria |
| `etapa/e2-fundacao` | E2 · System foundation | tests run offline and without quota |
| `etapa/e3-agente` | E3 · The agent and its tools | a real agent solves a real task, with its cost recorded |
| `etapa/e4-linha-de-producao` | E4 · Task production line | rejected on purpose, reworked and done |
| `etapa/e5-paralelismo` | E5 · Parallelism and fault tolerance | three in parallel; killing one does not bring the others down |
| `etapa/e6-memoria` | E6 · Project memory | the agent cites the earlier decision |
| `etapa/e7-painel` | E7 · Dashboard and automation | a whole project followed on screen |

- Planning: [`docs/planning/`](docs/planning/README.md) — requirements, architecture, criteria, test projects. Portuguese: [`docs/planejamento/`](docs/planejamento/).
- Tasks (Jira style): [`docs/tasks/en/`](docs/tasks/en/README.md). Portuguese: [`docs/tasks/pt/`](docs/tasks/pt/README.md).
- Stage reports (Word): [`docs/etapas/`](docs/etapas/) (Portuguese).

## Stack

- Elixir 1.19 / Erlang/OTP 28, Phoenix 1.8 + LiveView
- PostgreSQL 18 (state and cost accounting)
- Req (HTTP adapter)
- Model providers: provider CLI (default), token API, and a deterministic fake for tests

## Running

Requires PostgreSQL 18. The binaries directory is set with `FACTORY_PG_BIN` (default
`C:/pgsql/18/bin`) and the cluster's data directory with `FACTORY_PG_DATA` (default
`C:/pgsql/data`).

```
mix factory.db init    # once, on a new machine: creates the cluster
mix factory.db start   # starts PostgreSQL on 127.0.0.1:5432
mix setup              # dependencies, database and assets
mix phx.server         # http://localhost:4000
mix factory.db stop    # when done
```

## Verifying

```
mix factory.ci          # every stage in _management/ci.json
mix factory.ci --fast   # skips Dialyzer
```

Stages run in order and the first failure stops the rest: format, compile (warnings as
errors), strict Credo, tests, Dialyzer and the isolated backup/restore cycle
(`mix test.backup`). The suite runs offline: every HTTP request raises, and the configured
provider and embedder are fakes.

## Milestones

| Stage | Proof |
|---|---|
| E2 | `mix test test/factory/milestone_e2_test.exs` — the suite runs with no network, quota or API key |
| E3 | `mix run priv/probes/milestone_e3_agent.exs` — a real agent solves a real task; one usage row per turn (uses quota) |
| E4 | `mix test test/factory/milestone_e4_test.exs` — six states, rejected on purpose, reworked on a stronger model, done |

## Other tasks

- `mix factory.db start | stop | status | init` — the local PostgreSQL cluster
- `mix factory.backup` / `mix factory.restore --latest` — database dump and restore
- `mix factory.plan "<request>" --project <name>` — turn a request into tasks
- `mix factory.map` — generate the dense project index
