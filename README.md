# Multi-Agent Software Factory

**English** · [Português (BR)](README.pt-BR.md)

Final-year thesis (TCC) — Enzo Consulo.

A system that takes the description of a project in natural language and builds it end to end with
specialised agents, with the governance rules enforced by the structure of the program.

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
