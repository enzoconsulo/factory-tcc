# The five test projects

**English** · [Português (BR)](../planejamento/projetos-de-teste.md)

> **Proposal — to be validated with the advisor.**

Chosen to vary size, kind of deliverable and risk. They are not used during construction
(E2–E7): they only come in at validation, so the yardstick is not tuned to the system.

| # | Project | Request (summary) | Size | Done when |
|---|---|---|---|---|
| P1 | Command-line to-do list | "A terminal program to add, list, complete and remove tasks, saved to a file." | small | the four commands work and the tests pass |
| P2 | Library API | "A REST API to register books and readers and record loans and returns, with a database." | medium | CRUD + the loan rule (no book lent twice) tested |
| P3 | Report from a spreadsheet | "Read a sales CSV, validate the rows and produce a report with totals per month and per product." | small | invalid rows are flagged; totals match an answer key |
| P4 | Portfolio website | "A static three-page website (home, projects, contact), responsive and accessible." | medium | the three pages exist, pass an accessibility check and have a screenshot |
| P5 | Slide deck from data | "An 8-slide deck on the results of P3, with one chart per data slide." | small (non-code) | the 8 slides exist and every number matches the P3 report |
