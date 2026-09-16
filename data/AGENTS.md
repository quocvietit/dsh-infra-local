# Delivery agent conventions

- Orchestrate through the DSH `workflow` tool and `/data/workflows/*.js`.
- Fan-out by skill, by project, or by task DAG (`dependsOn`); never parallel-edit overlapping `files`.
- Persist artifacts under `/data/runs/<projectId>/<timestamp>/`.
- Trusted no-ask operations: `/data/policies/trusted-operations.yml`. Bash does not keep `cd` across calls.
