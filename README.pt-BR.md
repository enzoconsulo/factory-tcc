# Fábrica de Software Multi-Agente

[English](README.md) · **Português (BR)**

Trabalho de Conclusão de Curso — Enzo Consulo.

Um sistema que recebe a descrição de um projeto em linguagem natural e o constrói de ponta a ponta com agentes especializados, com as regras de governança impostas pela estrutura do programa.

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
