# Requirements

**English** · [Português (BR)](../planejamento/requisitos.md)

Two codes are used throughout the project: **E1–E10** are the stages and **R1–R15** are the requirements.

## What the system must do

| # | Requirement | How it will be verified | Stage |
|---|---|---|---|
| R1 | Turn a project description into a specification, a plan and tasks | a real request produces all three | E4 |
| R2 | Take each task through six states, recording a report and the cost | the history shows the six transitions | E4 |
| R3 | Judge every delivery twice: does it work, and is it what was asked | the two gates reject for different reasons | E4 |
| R4 | Return a rejected delivery with what was missing and decide how to redo it | a provoked rejection leads to the right decision | E4 |
| R5 | Limit rework: replan once and, if that fails, hand over to a human | an impossible task reaches the human in four cycles | E4 |
| R6 | Run independent tasks in parallel, without contention over files | three tasks in parallel, with no conflict | E5 |
| R7 | Consult the project history before deciding, citing the source | the agent cites the correct earlier decision | E6 |
| R8 | Show progress, cost and agent output, live | a whole project followed on screen | E7 |

## Under which constraints

| # | Constraint | The mechanism that guarantees it | Stage |
|---|---|---|---|
| R9 | Run on 8 GB of memory and 4 cores | the only heavy component, search, is swappable and chosen by measurement | E6 |
| R10 | Account for cost in quota consumed and in money | a table fed on every model response | E2 |
| R11 | No agent writes outside the project folder | the write tool itself refuses the path | E3 |
| R12 | Tests run offline and without consuming the model service | test doubles; a test fails if the access key is present | E2 |
| R13 | One agent crashing neither brings the others down nor loses work | isolated processes; the queue returns the task | E5 |
| R14 | No round goes over the spending ceiling | it prevents starting what does not fit, and never cuts work midway | E4 |
| R15 | Switch the model provider without touching the core | the provider comes in through a boundary | E3 |
