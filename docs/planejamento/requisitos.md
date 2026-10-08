# Requisitos

Duas siglas no projeto inteiro: **E1–E10** são as etapas e **R1–R15** são os requisitos.

## O que o sistema precisa fazer

| # | Requisito | Como será verificado | Etapa |
|---|---|---|---|
| R1 | Transformar a descrição de um projeto em especificação, plano e tarefas | um pedido real gera as três coisas | E4 |
| R2 | Levar cada tarefa por seis estados, registrando relatório e custo | o histórico mostra as seis passagens | E4 |
| R3 | Julgar toda entrega duas vezes: se funciona e se é o que foi pedido | os dois portões reprovam por motivos diferentes | E4 |
| R4 | Devolver a entrega reprovada com o que faltou e decidir como refazer | uma reprovação provocada gera a decisão certa | E4 |
| R5 | Limitar o retrabalho: replanejar uma vez e, se falhar, passar ao humano | uma tarefa impossível chega ao humano em quatro ciclos | E4 |
| R6 | Executar tarefas independentes em paralelo, sem disputa de arquivo | três tarefas em paralelo, sem conflito | E5 |
| R7 | Consultar o histórico do projeto antes de decidir, citando a fonte | o agente cita a decisão anterior correta | E6 |
| R8 | Mostrar andamento, custo e saída dos agentes, ao vivo | um projeto inteiro acompanhado na tela | E7 |

## Sob que restrições

| # | Restrição | O mecanismo que a garante | Etapa |
|---|---|---|---|
| R9 | Rodar em 8 GB de memória e 4 núcleos | o único componente pesado, a busca, é trocável e escolhido por medição | E6 |
| R10 | Contar o custo em cota consumida e em dinheiro | tabela alimentada a cada resposta do modelo | E2 |
| R11 | Nenhum agente escreve fora da pasta do projeto | a própria ferramenta de escrita recusa o caminho | E3 |
| R12 | Testes sem internet e sem consumir o serviço do modelo | substitutos para teste; um teste falha se a chave de acesso existir | E2 |
| R13 | A queda de um agente não derruba os outros nem perde trabalho | processos isolados; a fila devolve a tarefa | E5 |
| R14 | Nenhuma rodada passa do teto de gasto | impede começar o que não cabe, e nunca corta no meio | E4 |
| R15 | Trocar o fornecedor do modelo sem mexer no núcleo | o fornecedor entra por uma fronteira | E3 |
