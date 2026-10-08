# Factory — a multi-agent software factory

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

## Como acompanhar este repositório (TCC)

O desenvolvimento segue o plano em cascata: **cada etapa é uma branch**, criada a partir da
anterior, com um commit por entrega. No dia da apresentação de cada etapa, a branch dela entra
na `main`.

| Branch | Etapa | Entrega |
|---|---|---|
| `etapa/e1-planejamento` | E1 · Planejamento e arquitetura | requisitos, arquitetura, tarefas, critérios |
| `etapa/e2-fundacao` | E2 · Fundação do sistema | testes sem internet e sem cota |
| `etapa/e3-agente` | E3 · O agente e as ferramentas | agente real resolve tarefa real, com custo gravado |
| `etapa/e4-linha-de-producao` | E4 · Linha de produção de tarefas | reprovada de propósito, refeita e concluída |
| `etapa/e5-paralelismo` | E5 · Paralelismo e tolerância a falhas | três em paralelo; matar uma não derruba as outras |
| `etapa/e6-memoria` | E6 · Memória do projeto | o agente cita a decisão anterior |
| `etapa/e7-painel` | E7 · Painel e automação | projeto inteiro acompanhado na tela |

- Planejamento: [`docs/planejamento/`](docs/planejamento/) — requisitos, arquitetura, critérios, projetos de teste.
- Tarefas (estilo Jira, PT e EN): [`docs/tasks/pt/`](docs/tasks/pt/README.md) · [`docs/tasks/en/`](docs/tasks/en/README.md).
- Relatório de cada etapa (Word): [`docs/etapas/`](docs/etapas/).

## Stack

- Elixir 1.19 / Erlang/OTP 28, Phoenix 1.8 + LiveView
- PostgreSQL 18 (state and cost accounting)
- Model providers: a deterministic fake for tests

## Running

Requires PostgreSQL on `127.0.0.1:5432`.

```
mix setup          # dependencies, database and assets
mix phx.server     # http://localhost:4000
```

## Verifying

```
mix factory.ci          # every stage in _management/ci.json
mix factory.ci --fast   # skips Dialyzer
```

Stages run in order and the first failure stops the rest: format, compile (warnings as
errors), strict Credo, tests and Dialyzer.
