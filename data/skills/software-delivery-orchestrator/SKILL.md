---
name: software-delivery-orchestrator
description: Orchestrate URD-to-code assessment and delivery using specialized DSH subagents, including parallel fan-out by skill, project, or task DAG.
---
# Software Delivery Orchestrator

Use this skill when a user asks to assess a URD against source code, create implementation tasks, implement approved tasks, test, review, generate final traceability, or run several of those jobs at once.

## Important runtime fact
DSH workflows are caller-supplied JavaScript; the files under `/data/workflows` are templates, not automatically registered saved workflows. Always run orchestration through the `workflow` tool so the Web UI workflow-run board can show members as running or completed.

## Choose a split
Read the user request and pick one strategy (combine when needed):

1. **By skill** — independent roles in the same project (URD vs source analysis; unit tests vs test-case design).
2. **By project** — one workflow run per `projectId` from `/data/projects/*.yml` (or paths the user named). Aggregate each run's `runPath` at the end.
3. **By work / DAG** — after task review PASSes, the workflow fans each `TASK-xxx` to child agents (implement, then unit-test) in waves. Tasks that share `files` or `symbols` stay serial.

## Paths
- `runPath` must be `/data/runs/<projectId>/<timestamp>/`. Create that directory (via a short bash `mkdir -p`) before starting the workflow.
- Instruct the workflow args so child agents write `<skill>-<taskId>.json` under `runPath`.
- After the workflow returns, tell the user the `runPath`, `board.json`, `report.md`, and `final-report.json` (full delivery). Do not dump every artifact into chat.

Required `args`: `projectId`, `projectPath`, `urdPath`, `runPath`. Optional `mode`: `assessment` | `full-delivery`.

For assessment:
1. Read `/data/workflows/assessment.js` **or** `/data/workflows/orchestrate.js` with `mode: assessment`.
2. Call the DSH `workflow` tool with that file body as `script`.
3. Pass `args` containing `projectId`, `projectPath`, `urdPath`, `runPath`.
4. Do not enable source writes for assessment.

For full delivery:
1. Read `/data/workflows/full-delivery.js` **or** `/data/workflows/orchestrate.js` with `mode: full-delivery`.
2. Call the `workflow` tool with that file body as `script`.
3. Pass the same args plus `mode` when using orchestrate.js.
4. Only run when project policy allows source writes (`/data/projects/<id>.yml` `policy.sourceWrite`) and the task review gate has passed (the script enforces the gate).

Never skip a gate merely because a previous agent sounded confident.

Trusted operations that should not re-prompt the user are listed in `/data/policies/trusted-operations.yml`. Each bash call is a new shell — use `workdir` or `cd … && …` in one command.
