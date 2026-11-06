# Factory — uma fábrica de software multi-agente

[English](README.md) · **Português (BR)**

Projeto do Trabalho de Conclusão de Curso (TCC). O sistema recebe o pedido de um projeto em
linguagem natural e o constrói de ponta a ponta: agentes planejam, implementam, verificam e revisam
o trabalho, cada um com autoridade limitada. A governança é imposta pela estrutura do programa, não
por instruções no prompt:

| Regra | Onde mora |
|---|---|
| Nunca escrever fora do projeto | as ferramentas de arquivo recusam o caminho; o shell do agente roda em sandbox |
| No máximo três tentativas | um contador no banco que os agentes não alteram |
| Quem constrói não aprova | o revisor não recebe ferramenta de escrita |
| Nunca estourar o orçamento | trabalho que não cabe no teto nunca começa |

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

- Planejamento: [`docs/planejamento/`](docs/planejamento/) — requisitos, arquitetura, critérios, projetos de teste. Inglês: [`docs/planning/`](docs/planning/README.md).
- Tarefas (estilo Jira): [`docs/tasks/pt/`](docs/tasks/pt/README.md). Inglês: [`docs/tasks/en/`](docs/tasks/en/README.md).
- Relatório de cada etapa (Word): [`docs/etapas/`](docs/etapas/).

## Pilha

- Elixir 1.19 / Erlang/OTP 28, Phoenix 1.8 + LiveView
- PostgreSQL 18 (estado e contabilidade de custo)
- Req (adaptador HTTP)
- Fornecedores do modelo: CLI do fornecedor (padrão), API por token e um falso determinístico para os testes

## Como rodar

Exige o PostgreSQL 18. A pasta dos binários vem de `FACTORY_PG_BIN` (padrão
`C:/pgsql/18/bin`) e a pasta de dados do cluster de `FACTORY_PG_DATA` (padrão
`C:/pgsql/data`).

```
mix factory.db init    # uma vez, em máquina nova: cria o cluster
mix factory.db start   # sobe o PostgreSQL em 127.0.0.1:5432
mix setup              # dependências, banco e assets
mix phx.server         # http://localhost:4000
mix factory.db stop    # ao terminar
```

## Como verificar

```
mix factory.ci          # todos os estágios de _management/ci.json
mix factory.ci --fast   # pula o Dialyzer
```

Os estágios rodam em ordem e a primeira falha interrompe os seguintes: formatação, compilação
(aviso conta como erro), Credo estrito, testes, Dialyzer e o ciclo isolado de backup e restauração
(`mix test.backup`). A suíte roda sem internet: toda requisição HTTP levanta erro, e o fornecedor e
o embedder configurados são falsos.

## Marcos

| Etapa | Prova |
|---|---|
| E2 | `mix test test/factory/milestone_e2_test.exs` — a suíte roda sem rede, sem cota e sem chave de API |
| E3 | `mix run priv/probes/milestone_e3_agent.exs` — um agente real resolve uma tarefa real; uma linha de consumo por volta (gasta cota) |
| E4 | `mix test test/factory/milestone_e4_test.exs` — seis estados, reprovada de propósito, refeita num modelo mais forte, concluída |

## Outras tarefas

- `mix factory.db start | stop | status | init` — o cluster PostgreSQL local
- `mix factory.backup` / `mix factory.restore --latest` — dump e restauração do banco
- `mix factory.plan "<pedido>" --project <nome>` — transforma um pedido em tarefas
- `mix factory.map` — gera o índice denso do projeto
