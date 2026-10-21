# Quadro de tarefas

Cada tarefa corresponde a um pacote do plano de desenvolvimento. Abaixo, o resumo de todas; clique na chave para ver os detalhes.

## Visão geral

| Etapa | Proposta da etapa | Progresso |
|---|---|---|
| **E1** Planejamento e arquitetura | Requisitos, arquitetura, tarefas, critérios e projetos de teste aprovados. | 🟩🟩🟩🟩🟩🟩🟩🟩⬜⬜ 4/5 |
| **E2** Fundação do sistema | Os testes rodam sem internet e sem consumir o serviço do modelo. | 🟩🟩🟩🟩🟩🟩🟩🟩🟩🟩 5/5 |
| **E3** O agente e as ferramentas | Um agente resolve uma tarefa real com o custo gravado, e trocar de fornecedor não mexe no núcleo. | 🟩🟩🟩🟩🟩🟩🟩🟩🟩🟩 6/6 |
| **E4** Linha de produção de tarefas | Uma tarefa percorre os seis estados, é reprovada de propósito, é refeita e conclui. | 🟩🟩🟩🟩🟩🟩🟩🟩🟩🟩 8/8 |
| **E5** Paralelismo e tolerância a falhas | Três tarefas em paralelo; encerrar uma no meio não afeta as outras, e ela volta à fila. | ⬜⬜⬜⬜⬜⬜⬜⬜⬜⬜ 0/6 |
| **E6** Memória do projeto | O agente cita a decisão anterior, com a fonte certa, em vez de decidir de novo. | ⬜⬜⬜⬜⬜⬜⬜⬜⬜⬜ 0/6 |
| **E7** Painel e automação | Um projeto inteiro acompanhado na tela, do pedido à entrega, com o custo em tempo real. | ⬜⬜⬜⬜⬜⬜⬜⬜⬜⬜ 0/8 |

## E1 — Planejamento e arquitetura

**Proposta da etapa:** Requisitos, arquitetura, tarefas, critérios e projetos de teste aprovados.  
**Progresso:** 🟩🟩🟩🟩🟩🟩🟩🟩⬜⬜ 4/5

| Chave | Título | O que fez | Status |
|---|---|---|---|
| [FAB-101](E1-planejamento-e-arquitetura/FAB-101-levantar-os-requisitos-r1r15.md) | **Levantar os requisitos R1–R15** | Definir o que o sistema precisa fazer (R1–R8) e sob quais restrições (R9–R15), cada um com etapa e forma de verificar. | ✅ Concluída |
| [FAB-102](E1-planejamento-e-arquitetura/FAB-102-estudar-o-estado-da-arte.md) | **Estudar o estado da arte** | Comparar os sistemas multi-agente existentes e mostrar onde a governança por estrutura é original. | ✅ Concluída |
| [FAB-103](E1-planejamento-e-arquitetura/FAB-103-desenhar-a-arquitetura.md) | **Desenhar a arquitetura** | Quatro camadas, os seis estados da tarefa, os dois portões e a escada de resposta à falha; escolher a pilha (Elixir/OTP). | ✅ Concluída |
| [FAB-104](E1-planejamento-e-arquitetura/FAB-104-dividir-o-trabalho-e-definir-os-criterios-de-desem.md) | **Dividir o trabalho e definir os critérios de desempenho** | Quebrar E2–E7 em tarefas com critérios de aceite executáveis e fixar os 8 critérios de desempenho da validação. | ✅ Concluída |
| [FAB-105](E1-planejamento-e-arquitetura/FAB-105-definir-os-cinco-projetos-de-teste.md) | **Definir os cinco projetos de teste** | Escolher cinco pedidos reais, de tamanhos e domínios diferentes, que a validação (E8–E10) vai executar sem intervenção. | 🔄 Em andamento |

## E2 — Fundação do sistema

**Proposta da etapa:** Os testes rodam sem internet e sem consumir o serviço do modelo.  
**Progresso:** 🟩🟩🟩🟩🟩🟩🟩🟩🟩🟩 5/5

| Chave | Título | O que fez | Status |
|---|---|---|---|
| [FAB-201](E2-fundacao-do-sistema/FAB-201-montar-o-ambiente-e-a-verificacao-em-um-comando.md) | **Montar o ambiente e a verificação em um comando** | Projeto Phoenix com formatação, compilação sem avisos, Credo estrito, testes e Dialyzer encadeados em `mix factory.ci`. | ✅ Concluída |
| [FAB-202](E2-fundacao-do-sistema/FAB-202-criar-o-banco-de-dados-e-a-contagem-de-custo.md) | **Criar o banco de dados e a contagem de custo** | Esquema de projetos, tarefas, ciclos, despachos e consumos; custo contado em duas unidades (cota e dólar). | ✅ Concluída |
| [FAB-203](E2-fundacao-do-sistema/FAB-203-criar-as-fronteiras-do-modelo-e-da-busca-com-subst.md) | **Criar as fronteiras do modelo e da busca, com substitutos de teste** | Behaviours para o executor de agentes e para o gerador de embeddings, cada um com um adaptador falso usado nos testes. | ✅ Concluída |
| [FAB-204](E2-fundacao-do-sistema/FAB-204-copia-de-seguranca-do-banco.md) | **Cópia de segurança do banco** | `mix factory.backup` e `mix factory.restore`, com ida e volta provada num estágio próprio da verificação. | ✅ Concluída |
| [FAB-205](E2-fundacao-do-sistema/FAB-205-marco-e2-a-suite-roda-sem-internet-e-sem-cota.md) | **MARCO E2 — a suíte roda sem internet e sem cota** | Teste permanente que falha se houver tráfego de rede, cliente HTTP carregado ou chave de acesso no ambiente. | ✅ Concluída |

## E3 — O agente e as ferramentas

**Proposta da etapa:** Um agente resolve uma tarefa real com o custo gravado, e trocar de fornecedor não mexe no núcleo.  
**Progresso:** 🟩🟩🟩🟩🟩🟩🟩🟩🟩🟩 6/6

| Chave | Título | O que fez | Status |
|---|---|---|---|
| [FAB-301](E3-o-agente-e-as-ferramentas/FAB-301-ferramentas-de-arquivo-e-de-comando.md) | **Ferramentas de arquivo e de comando** | Ler, listar, buscar, escrever e editar arquivos; rodar comando com prazo, matando a árvore de processos inteira. | ✅ Concluída |
| [FAB-302](E3-o-agente-e-as-ferramentas/FAB-302-confinamento-nenhum-agente-escreve-fora-do-projeto.md) | **Confinamento: nenhum agente escreve fora do projeto** | Toda ferramenta resolve o caminho real e recusa absoluto, `..`, link, junção, UNC e dispositivo; o shell do agente roda em sandbox. | ✅ Concluída |
| [FAB-303](E3-o-agente-e-as-ferramentas/FAB-303-resumo-do-projeto-para-orientar-o-agente.md) | **Resumo do projeto para orientar o agente** | Índice denso gerado do código (árvore + assinaturas) e prefixo estável do prompt, com pontos de cache. | ✅ Concluída |
| [FAB-304](E3-o-agente-e-as-ferramentas/FAB-304-o-agente-como-processo-supervisionado-com-limite-d.md) | **O agente como processo supervisionado, com limite de chamadas** | Laço de uso de ferramentas como processo OTP; teto de chamadas por papel imposto pelo sistema, não pedido no prompt. | ✅ Concluída |
| [FAB-305](E3-o-agente-e-as-ferramentas/FAB-305-adaptadores-do-fornecedor-com-o-controle-medido-an.md) | **Adaptadores do fornecedor, com o controle medido antes** | Dois adaptadores atrás da mesma fronteira: o CLI do fornecedor (assinatura) e a API por token. A governança do CLI foi medida antes de decidir. | ✅ Concluída |
| [FAB-306](E3-o-agente-e-as-ferramentas/FAB-306-marco-e3-um-agente-real-resolve-uma-tarefa-real-co.md) | **MARCO E3 — um agente real resolve uma tarefa real, com o custo gravado** | Probe contra o modelo real: o agente escreve o arquivo pedido, há uma linha de consumo por volta e a soma bate com o banco. | ✅ Concluída |

## E4 — Linha de produção de tarefas

**Proposta da etapa:** Uma tarefa percorre os seis estados, é reprovada de propósito, é refeita e conclui.  
**Progresso:** 🟩🟩🟩🟩🟩🟩🟩🟩🟩🟩 8/8

| Chave | Título | O que fez | Status |
|---|---|---|---|
| [FAB-401](E4-linha-de-producao-de-tarefas/FAB-401-os-seis-estados-com-a-mudanca-gravada-de-uma-vez-s.md) | **Os seis estados, com a mudança gravada de uma vez só** | Máquina de estados pura e transição transacional: estado, relatório e custo na mesma transação. | ✅ Concluída |
| [FAB-402](E4-linha-de-producao-de-tarefas/FAB-402-fila-por-dependencias-e-equipe-especializada.md) | **Fila por dependências e equipe especializada** | Promover tarefas cujas dependências concluíram e ordenar a fila; resolver o especialista que constrói cada tarefa. | ✅ Concluída |
| [FAB-403](E4-linha-de-producao-de-tarefas/FAB-403-criterios-de-aceite-executados-sozinhos.md) | **Critérios de aceite executados sozinhos** | Ler os comandos `verify:` da tarefa, rodar só os permitidos e separar comando quebrado de entrega errada. | ✅ Concluída |
| [FAB-403.1](E4-linha-de-producao-de-tarefas/FAB-403.1-teste-de-prazo-independe-da-velocidade-da-maquina.md) | **↳ Teste de prazo esgotado independe da velocidade da máquina** | Subtarefa de FAB-403: O teste da repetição após prazo esgotado usa um comando que nunca termina, em vez de depender de a máquina ser lenta. | ✅ Concluída |
| [FAB-404](E4-linha-de-producao-de-tarefas/FAB-404-os-dois-portoes.md) | **Os dois portões** | Verificador (funciona?) e revisor (é o que foi pedido? está correto?). O revisor não recebe ferramenta de escrita. | ✅ Concluída |
| [FAB-405](E4-linha-de-producao-de-tarefas/FAB-405-diagnostico-da-reprovacao-e-escada-de-resposta.md) | **Diagnóstico da reprovação e escada de resposta** | Decidir COMO refazer: modelo mais forte, outro especialista, replanejar e, se a substituta também esgotar os ciclos, passar ao humano. | ✅ Concluída |
| [FAB-406](E4-linha-de-producao-de-tarefas/FAB-406-teto-de-gasto-por-rodada-e-por-tarefa.md) | **Teto de gasto por rodada e por tarefa** | O sistema não deixa começar o trabalho que não cabe no teto — e nunca corta no meio. | ✅ Concluída |
| [FAB-406.1](E4-linha-de-producao-de-tarefas/FAB-406.1-estimativa-padrao-por-tarefa-recalibrada.md) | **↳ Estimativa padrão por tarefa recalibrada** | Subtarefa de FAB-406: O valor declarado da estimativa por tarefa concluída passa de US$ 7,8241 para US$ 11,04. | ✅ Concluída |
| [FAB-407](E4-linha-de-producao-de-tarefas/FAB-407-do-pedido-as-tarefas-o-planejador.md) | **Do pedido às tarefas: o planejador** | Traduzir um pedido em linguagem natural num grafo de 8 a 12 tarefas validado, gravado numa transação, e publicar tarefas em markdown. | ✅ Concluída |
| [FAB-407.1](E4-linha-de-producao-de-tarefas/FAB-407.1-doutrina-do-planejador-exige-ci-json-e-contrato-de-saida.md) | **↳ Doutrina do planejador: ci.json na fundação e contrato do código de saída** | Subtarefa de FAB-407: A doutrina manda a primeira tarefa criar `_management/ci.json` e diz que um comando de critério passa com código de saída 0. | ✅ Concluída |
| [FAB-407.2](E4-linha-de-producao-de-tarefas/FAB-407.2-mix-factory-plan-cria-o-projeto-como-repositorio-git-proprio.md) | **↳ `mix factory.plan` cria o projeto como repositório git próprio, com opção `--domain`** | Subtarefa de FAB-407: O projeto novo nasce em `generated-projects/<nome>` como repositório git próprio; `--domain` escolhe o domínio. | ✅ Concluída |
| [FAB-408](E4-linha-de-producao-de-tarefas/FAB-408-marco-e4-reprovada-de-proposito-refeita-e-concluid.md) | **MARCO E4 — reprovada de propósito, refeita e concluída** | Teste permanente: uma tarefa percorre a linha de pronta a concluída, é reprovada por entrega errada, sobe de modelo e conclui. | ✅ Concluída |

## E5 — Paralelismo e tolerância a falhas

**Proposta da etapa:** Três tarefas em paralelo; encerrar uma no meio não afeta as outras, e ela volta à fila.  
**Progresso:** ⬜⬜⬜⬜⬜⬜⬜⬜⬜⬜ 0/6

| Chave | Título | O que fez | Status |
|---|---|---|---|
| [FAB-501](E5-paralelismo-e-tolerancia-a-falhas/FAB-501-um-processo-supervisionado-por-tarefa.md) | **Um processo supervisionado por tarefa** | Árvore de supervisão e registro dos agentes em voo; a queda de um não afeta os outros. | ⬜ A fazer |
| [FAB-502](E5-paralelismo-e-tolerancia-a-falhas/FAB-502-fila-duravel-no-banco.md) | **Fila durável no banco** | Enfileirar o trabalho e mudar o estado da tarefa na mesma transação (Oban). | ⬜ A fazer |
| [FAB-503](E5-paralelismo-e-tolerancia-a-falhas/FAB-503-tarefas-em-paralelo-sem-disputar-arquivo.md) | **Tarefas em paralelo sem disputar arquivo** | As áreas declaradas de cada tarefa funcionam como exclusão mútua; o número em voo respeita o perfil de 8 GB. | ⬜ A fazer |
| [FAB-504](E5-paralelismo-e-tolerancia-a-falhas/FAB-504-reconhecer-o-limite-de-uso-do-fornecedor-e-retomar.md) | **Reconhecer o limite de uso do fornecedor e retomar** | Ao bater na cota, pausar sem perder nada, dormir até a reabertura anunciada e rearmar sozinho. | ⬜ A fazer |
| [FAB-505](E5-paralelismo-e-tolerancia-a-falhas/FAB-505-recuperar-trabalho-interrompido.md) | **Recuperar trabalho interrompido** | Depois de uma queda, achar as tarefas órfãs, devolver o estado delas e commitar o trabalho parcial em nome da tarefa. | ⬜ A fazer |
| [FAB-506](E5-paralelismo-e-tolerancia-a-falhas/FAB-506-marco-e5-tres-em-paralelo-e-matar-uma-nao-derruba-.md) | **MARCO E5 — três em paralelo, e matar uma não derruba as outras** | Teste permanente com processos reais: três agentes em voo, um é morto, os outros seguem e o morto volta à fila. | ⬜ A fazer |

## E6 — Memória do projeto

**Proposta da etapa:** O agente cita a decisão anterior, com a fonte certa, em vez de decidir de novo.  
**Progresso:** ⬜⬜⬜⬜⬜⬜⬜⬜⬜⬜ 0/6

| Chave | Título | O que fez | Status |
|---|---|---|---|
| [FAB-601](E6-memoria-do-projeto/FAB-601-medir-antes-de-escolher-onde-a-busca-roda.md) | **Medir antes de escolher onde a busca roda** | Medir memória e tempo do embedding local e escolher o adaptador; dimensão do índice conferida contra o modelo. | ⬜ A fazer |
| [FAB-602](E6-memoria-do-projeto/FAB-602-guardar-o-historico-em-trechos-consultaveis.md) | **Guardar o histórico em trechos consultáveis** | Quebrar o histórico do projeto em trechos por seção e gravá-los com embedding, reprocessando só o que mudou. | ⬜ A fazer |
| [FAB-603](E6-memoria-do-projeto/FAB-603-busca-por-significado-e-por-termo-exato.md) | **Busca por significado e por termo exato** | Busca híbrida com fusão recíproca de postos, filtrada por projeto antes da distância vetorial. | ⬜ A fazer |
| [FAB-604](E6-memoria-do-projeto/FAB-604-entregar-o-contexto-com-a-fonte-citada.md) | **Entregar o contexto com a fonte citada** | Montar o bloco de contexto recuperado, com a fonte de cada trecho, pronto para entrar no despacho depois da faixa cacheada. | ⬜ A fazer |
| [FAB-605](E6-memoria-do-projeto/FAB-605-avaliar-a-qualidade-da-busca.md) | **Avaliar a qualidade da busca** | Conjunto de perguntas com resposta conhecida; recall@8, recall@1 e MRR; busca abaixo da linha de base desliga o bloco. | ⬜ A fazer |
| [FAB-606](E6-memoria-do-projeto/FAB-606-marco-e6-o-agente-cita-a-decisao-anterior.md) | **MARCO E6 — o agente cita a decisão anterior** | Observar um agente real recebendo o bloco recuperado e citando a decisão anterior com a fonte certa. | ⬜ A fazer |

## E7 — Painel e automação

**Proposta da etapa:** Um projeto inteiro acompanhado na tela, do pedido à entrega, com o custo em tempo real.  
**Progresso:** ⬜⬜⬜⬜⬜⬜⬜⬜⬜⬜ 0/8

| Chave | Título | O que fez | Status |
|---|---|---|---|
| [FAB-701](E7-painel-e-automacao/FAB-701-medidas-de-cada-execucao.md) | **Medidas de cada execução** | Barramento de eventos do motor: início e fim de cada despacho, cada volta (tokens e custo), mudança de estado e cota. | ⬜ A fazer |
| [FAB-702](E7-painel-e-automacao/FAB-702-quadro-de-tarefas-e-console-ao-vivo-com-custo.md) | **Quadro de tarefas e console ao vivo, com custo** | LiveView com o quadro por estado (com o custo de cada tarefa) e o console com os agentes em execução, o custo e a cota. | ⬜ A fazer |
| [FAB-703](E7-painel-e-automacao/FAB-703-parar-e-retomar.md) | **Parar e retomar** | Um botão encerra o processo supervisionado da tarefa, que volta à fila sem perder o trabalho. | ⬜ A fazer |
| [FAB-704](E7-painel-e-automacao/FAB-704-rodadas-automaticas-com-teto-de-gasto.md) | **Rodadas automáticas com teto de gasto** | Piloto automático: encadeia rodadas até um critério de parada, com teto de gasto e de rodadas obrigatórios. | ⬜ A fazer |
| [FAB-705](E7-painel-e-automacao/FAB-705-entregas-que-nao-sao-codigo.md) | **Entregas que não são código** | Trilha genérica: o artefato tem gerador e verificador próprios, e todo critério recebe um grau de prova obrigatório. | ⬜ A fazer |
| [FAB-706](E7-painel-e-automacao/FAB-706-busca-de-segredos-antes-de-publicar.md) | **Busca de segredos antes de publicar** | Varredura de chaves e credenciais no que vai ser commitado ou publicado. | ⬜ A fazer |
| [FAB-707](E7-painel-e-automacao/FAB-707-o-agente-real-de-ponta-a-ponta.md) | **O agente real de ponta a ponta** | Despacho montado a partir da tarefa e da doutrina de cada papel; a fila sobe o agente real e fecha o laço com os portões. | ⬜ A fazer |
| [FAB-708](E7-painel-e-automacao/FAB-708-marco-e7-um-projeto-inteiro-sem-intervencao-acompa.md) | **MARCO E7 — um projeto inteiro, sem intervenção, acompanhado na tela** | Do pedido à entrega com uma única intervenção humana (o pedido), com teto de gasto e custo ao vivo. | ⬜ A fazer |
