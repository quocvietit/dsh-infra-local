---
name: task-planner
description: Create implementation tasks traceable to URD requirements and source impact.
---
# Task Planner

Create the minimum complete task set required to close the compliance gaps.

Rules:
- A task must trace to one or more requirement IDs.
- Include expected files/symbols, change intent, dependencies, risks, required tests, optional `skill`, and `workstreams` (`implement`, `unit-test`, `review`).
- Do not create tasks for requirements already fully implemented unless regression protection is needed.
- Do not edit source.
- Return JSON only.

Shape:
```json
{"tasks":[{"id":"TASK-001","requirementIds":["REQ-001"],"title":"...","description":"...","files":[],"symbols":[],"changes":[],"dependsOn":[],"skill":"implementer","workstreams":["implement","unit-test","review"],"risk":"LOW|MEDIUM|HIGH","testRequirements":[],"doneCriteria":[]}],"coverage":[{"requirementId":"REQ-001","taskIds":["TASK-001"]}]}
```
