# Task board

Each task is one package of the development plan. Below is a summary of every task; click a key for the details.

## Overview

| Stage | Stage goal | Progress |
|---|---|---|
| **E1** Planning and architecture | Requirements, architecture, tasks, performance criteria and test projects approved. | 🟩🟩🟩🟩🟩🟩🟩🟩⬜⬜ 4/5 |
| **E2** System foundation | The test suite runs with no network access and without consuming the model service. | 🟩🟩🟩🟩🟩🟩🟩🟩🟩🟩 5/5 |
| **E3** The agent and its tools | An agent solves a real task with its cost recorded, and switching providers does not touch the core. | ⬜⬜⬜⬜⬜⬜⬜⬜⬜⬜ 0/6 |
| **E4** Task production line | A task goes through the six states, is rejected on purpose, is reworked and completes. | ⬜⬜⬜⬜⬜⬜⬜⬜⬜⬜ 0/8 |
| **E5** Parallelism and fault tolerance | Three tasks in parallel; killing one midway does not affect the others, and it returns to the queue. | ⬜⬜⬜⬜⬜⬜⬜⬜⬜⬜ 0/6 |
| **E6** Project memory | The agent cites the earlier decision, with the right source, instead of deciding again. | ⬜⬜⬜⬜⬜⬜⬜⬜⬜⬜ 0/6 |
| **E7** Dashboard and automation | A whole project followed on screen, from request to delivery, with live cost. | ⬜⬜⬜⬜⬜⬜⬜⬜⬜⬜ 0/8 |

## E1 — Planning and architecture

**Stage goal:** Requirements, architecture, tasks, performance criteria and test projects approved.  
**Progress:** 🟩🟩🟩🟩🟩🟩🟩🟩⬜⬜ 4/5

| Key | Title | What it did | Status |
|---|---|---|---|
| [FAB-101](E1-planning-and-architecture/FAB-101-gather-requirements-r1r15.md) | **Gather requirements R1–R15** | Define what the system must do (R1–R8) and under which constraints (R9–R15), each with an owning stage and a way to verify it. | ✅ Done |
| [FAB-102](E1-planning-and-architecture/FAB-102-study-the-state-of-the-art.md) | **Study the state of the art** | Compare existing multi-agent systems and show where governance-by-structure is original. | ✅ Done |
| [FAB-103](E1-planning-and-architecture/FAB-103-design-the-architecture.md) | **Design the architecture** | Four layers, the six task states, the two gates and the failure-response ladder; pick the stack (Elixir/OTP). | ✅ Done |
| [FAB-104](E1-planning-and-architecture/FAB-104-break-down-the-work-and-define-performance-criteri.md) | **Break down the work and define performance criteria** | Split E2–E7 into tasks with executable acceptance criteria and fix the 8 performance criteria used in validation. | ✅ Done |
| [FAB-105](E1-planning-and-architecture/FAB-105-define-the-five-test-projects.md) | **Define the five test projects** | Choose five real requests, of different sizes and domains, that validation (E8–E10) will run with no intervention. | 🔄 In progress |

## E2 — System foundation

**Stage goal:** The test suite runs with no network access and without consuming the model service.  
**Progress:** 🟩🟩🟩🟩🟩🟩🟩🟩🟩🟩 5/5

| Key | Title | What it did | Status |
|---|---|---|---|
| [FAB-201](E2-system-foundation/FAB-201-set-up-the-environment-and-one-command-verificatio.md) | **Set up the environment and one-command verification** | Phoenix project with formatting, warning-free compile, strict Credo, tests and Dialyzer chained in `mix factory.ci`. | ✅ Done |
| [FAB-202](E2-system-foundation/FAB-202-create-the-database-and-cost-accounting.md) | **Create the database and cost accounting** | Schema for projects, tasks, cycles, dispatches and usage; cost counted in two units (quota and dollars). | ✅ Done |
| [FAB-203](E2-system-foundation/FAB-203-create-model-and-search-boundaries-with-test-doubl.md) | **Create model and search boundaries, with test doubles** | Behaviours for the agent runner and for the embedding generator, each with a fake adapter used by the tests. | ✅ Done |
| [FAB-204](E2-system-foundation/FAB-204-database-backup.md) | **Database backup** | `mix factory.backup` and `mix factory.restore`, with the round trip proven in its own verification stage. | ✅ Done |
| [FAB-205](E2-system-foundation/FAB-205-milestone-e2-the-suite-runs-offline-and-without-qu.md) | **MILESTONE E2 — the suite runs offline and without quota** | Permanent test that fails on any network traffic, loaded HTTP client or access key in the environment. | ✅ Done |

## E3 — The agent and its tools

**Stage goal:** An agent solves a real task with its cost recorded, and switching providers does not touch the core.  
**Progress:** ⬜⬜⬜⬜⬜⬜⬜⬜⬜⬜ 0/6

| Key | Title | What it did | Status |
|---|---|---|---|
| [FAB-301](E3-the-agent-and-its-tools/FAB-301-file-and-command-tools.md) | **File and command tools** | Read, list, search, write and edit files; run a command with a deadline, killing the whole process tree. | ⬜ To do |
| [FAB-302](E3-the-agent-and-its-tools/FAB-302-confinement-no-agent-writes-outside-the-project.md) | **Confinement: no agent writes outside the project** | Every tool resolves the real path and rejects absolute paths, `..`, links, junctions, UNC and devices; the agent's shell runs sandboxed. | ⬜ To do |
| [FAB-303](E3-the-agent-and-its-tools/FAB-303-project-summary-to-guide-the-agent.md) | **Project summary to guide the agent** | Dense index generated from the code (tree + signatures) and a stable prompt prefix with cache breakpoints. | ⬜ To do |
| [FAB-304](E3-the-agent-and-its-tools/FAB-304-the-agent-as-a-supervised-process-with-a-call-limi.md) | **The agent as a supervised process, with a call limit** | Tool-use loop as an OTP process; per-role call ceiling enforced by the system, not requested in the prompt. | ⬜ To do |
| [FAB-305](E3-the-agent-and-its-tools/FAB-305-provider-adapters-with-control-measured-first.md) | **Provider adapters, with control measured first** | Two adapters behind the same boundary: the provider CLI (subscription) and the token API. CLI governance was measured before deciding. | ⬜ To do |
| [FAB-306](E3-the-agent-and-its-tools/FAB-306-milestone-e3-a-real-agent-solves-a-real-task-with-.md) | **MILESTONE E3 — a real agent solves a real task, with cost recorded** | Probe against the real model: the agent writes the requested file, there is one usage row per turn and the total matches the database. | ⬜ To do |

## E4 — Task production line

**Stage goal:** A task goes through the six states, is rejected on purpose, is reworked and completes.  
**Progress:** ⬜⬜⬜⬜⬜⬜⬜⬜⬜⬜ 0/8

| Key | Title | What it did | Status |
|---|---|---|---|
| [FAB-401](E4-task-production-line/FAB-401-the-six-states-with-each-change-stored-atomically.md) | **The six states, with each change stored atomically** | Pure state machine and transactional transition: state, report and cost in the same transaction. | ⬜ To do |
| [FAB-402](E4-task-production-line/FAB-402-dependency-queue-and-specialist-team.md) | **Dependency queue and specialist team** | Promote tasks whose dependencies are done and order the queue; resolve the specialist that builds each task. | ⬜ To do |
| [FAB-403](E4-task-production-line/FAB-403-acceptance-criteria-executed-automatically.md) | **Acceptance criteria executed automatically** | Read the task's `verify:` commands, run only allowed ones and tell a broken command from a wrong delivery. | ⬜ To do |
| [FAB-404](E4-task-production-line/FAB-404-the-two-gates.md) | **The two gates** | Verifier (does it work?) and reviewer (is it what was asked? is it correct?). The reviewer gets no write tool. | ⬜ To do |
| [FAB-405](E4-task-production-line/FAB-405-rejection-diagnosis-and-response-ladder.md) | **Rejection diagnosis and response ladder** | Decide HOW to redo: stronger model, another specialist, replan and, if the replacement also exhausts its cycles, hand over to a human. | ⬜ To do |
| [FAB-406](E4-task-production-line/FAB-406-spending-ceiling-per-round-and-per-task.md) | **Spending ceiling per round and per task** | The system does not let work start if it does not fit the ceiling — and never cuts work midway. | ⬜ To do |
| [FAB-407](E4-task-production-line/FAB-407-from-request-to-tasks-the-planner.md) | **From request to tasks: the planner** | Turn a natural-language request into a validated graph of 8 to 12 tasks, stored in one transaction, and publish tasks as markdown. | ⬜ To do |
| [FAB-408](E4-task-production-line/FAB-408-milestone-e4-rejected-on-purpose-reworked-and-done.md) | **MILESTONE E4 — rejected on purpose, reworked and done** | Permanent test: a task goes down the line from ready to done, is rejected for a wrong delivery, gets a stronger model and completes. | ⬜ To do |

## E5 — Parallelism and fault tolerance

**Stage goal:** Three tasks in parallel; killing one midway does not affect the others, and it returns to the queue.  
**Progress:** ⬜⬜⬜⬜⬜⬜⬜⬜⬜⬜ 0/6

| Key | Title | What it did | Status |
|---|---|---|---|
| [FAB-501](E5-parallelism-and-fault-tolerance/FAB-501-one-supervised-process-per-task.md) | **One supervised process per task** | Supervision tree and registry of running agents; one crashing does not affect the others. | ⬜ To do |
| [FAB-502](E5-parallelism-and-fault-tolerance/FAB-502-durable-queue-in-the-database.md) | **Durable queue in the database** | Enqueue work and change the task state in the same transaction (Oban). | ⬜ To do |
| [FAB-503](E5-parallelism-and-fault-tolerance/FAB-503-parallel-tasks-without-file-contention.md) | **Parallel tasks without file contention** | Each task's declared areas act as mutual exclusion; the number in flight respects the 8 GB profile. | ⬜ To do |
| [FAB-504](E5-parallelism-and-fault-tolerance/FAB-504-recognise-the-provider-usage-limit-and-resume.md) | **Recognise the provider usage limit and resume** | On hitting the quota, pause without losing anything, sleep until the announced reset and re-arm automatically. | ⬜ To do |
| [FAB-505](E5-parallelism-and-fault-tolerance/FAB-505-recover-interrupted-work.md) | **Recover interrupted work** | After a crash, find orphan tasks, restore their state and commit their partial work on behalf of the task. | ⬜ To do |
| [FAB-506](E5-parallelism-and-fault-tolerance/FAB-506-milestone-e5-three-in-parallel-killing-one-does-no.md) | **MILESTONE E5 — three in parallel, killing one does not bring down the others** | Permanent test with real processes: three agents in flight, one is killed, the others continue and the killed one returns to the queue. | ⬜ To do |

## E6 — Project memory

**Stage goal:** The agent cites the earlier decision, with the right source, instead of deciding again.  
**Progress:** ⬜⬜⬜⬜⬜⬜⬜⬜⬜⬜ 0/6

| Key | Title | What it did | Status |
|---|---|---|---|
| [FAB-601](E6-project-memory/FAB-601-measure-before-choosing-where-search-runs.md) | **Measure before choosing where search runs** | Measure memory and time of local embedding and choose the adapter; index dimension checked against the model. | ⬜ To do |
| [FAB-602](E6-project-memory/FAB-602-store-history-as-searchable-chunks.md) | **Store history as searchable chunks** | Split the project history into chunks by section and store them with embeddings, reprocessing only what changed. | ⬜ To do |
| [FAB-603](E6-project-memory/FAB-603-search-by-meaning-and-by-exact-term.md) | **Search by meaning and by exact term** | Hybrid search with reciprocal rank fusion, filtered by project before vector distance. | ⬜ To do |
| [FAB-604](E6-project-memory/FAB-604-deliver-context-with-its-source-cited.md) | **Deliver context with its source cited** | Build the retrieved context block, citing each chunk's source, ready to go into the dispatch after the cached band. | ⬜ To do |
| [FAB-605](E6-project-memory/FAB-605-evaluate-search-quality.md) | **Evaluate search quality** | Question set with known answers; recall@8, recall@1 and MRR; search below baseline turns the block off. | ⬜ To do |
| [FAB-606](E6-project-memory/FAB-606-milestone-e6-the-agent-cites-the-earlier-decision.md) | **MILESTONE E6 — the agent cites the earlier decision** | Watch a real agent receive the retrieved block and cite the earlier decision with the right source. | ⬜ To do |

## E7 — Dashboard and automation

**Stage goal:** A whole project followed on screen, from request to delivery, with live cost.  
**Progress:** ⬜⬜⬜⬜⬜⬜⬜⬜⬜⬜ 0/8

| Key | Title | What it did | Status |
|---|---|---|---|
| [FAB-701](E7-dashboard-and-automation/FAB-701-per-run-measurements.md) | **Per-run measurements** | The engine's event bus: start and stop of each dispatch, each turn (tokens and cost), state changes and quota. | ⬜ To do |
| [FAB-702](E7-dashboard-and-automation/FAB-702-live-task-board-and-console-with-cost.md) | **Live task board and console, with cost** | LiveView with the board by state (with each task's cost) and the console with agents in flight, cost and quota. | ⬜ To do |
| [FAB-703](E7-dashboard-and-automation/FAB-703-stop-and-resume.md) | **Stop and resume** | A button stops the task's supervised process, which returns to the queue without losing work. | ⬜ To do |
| [FAB-704](E7-dashboard-and-automation/FAB-704-automatic-rounds-with-a-spending-ceiling.md) | **Automatic rounds with a spending ceiling** | Autopilot: chains rounds until a stop criterion, with mandatory spending and round ceilings. | ⬜ To do |
| [FAB-705](E7-dashboard-and-automation/FAB-705-non-code-deliverables.md) | **Non-code deliverables** | Generic track: the artifact has its own generator and verifier, and every criterion gets a mandatory proof grade. | ⬜ To do |
| [FAB-706](E7-dashboard-and-automation/FAB-706-secret-scanning-before-publishing.md) | **Secret scanning before publishing** | Scan for keys and credentials in what is about to be committed or published. | ⬜ To do |
| [FAB-707](E7-dashboard-and-automation/FAB-707-the-real-agent-end-to-end.md) | **The real agent end to end** | Dispatch built from the task and each role's doctrine; the queue starts the real agent and closes the loop with the gates. | ⬜ To do |
| [FAB-708](E7-dashboard-and-automation/FAB-708-milestone-e7-a-whole-project-no-intervention-follo.md) | **MILESTONE E7 — a whole project, no intervention, followed on screen** | From request to delivery with a single human intervention (the request), with a spending ceiling and live cost. | ⬜ To do |
