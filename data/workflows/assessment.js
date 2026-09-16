// Assessment workflow (read-only). Required args: projectId, projectPath, urdPath, runPath

const required = ['projectId', 'projectPath', 'urdPath', 'runPath']
for (const key of required) {
  if (!args || typeof args[key] !== 'string' || args[key].trim() === '') {
    throw new Error(`Missing workflow arg: ${key}`)
  }
}

const OBJ = { type: 'object', additionalProperties: true }
function asText(value) {
  if (value == null) return ''
  if (typeof value === 'string') return value
  try { return JSON.stringify(value) } catch { return String(value) }
}

log(`assessment start: ${args.projectId}`)
phase('Analyze')
const [requirements, sourceAnalysis] = await parallel([
  () => agent(
    `Load skill urd-analyzer. Read URD at ${args.urdPath}. Return the required JSON only.`,
    { label: 'urd-analyzer', phase: 'Analyze', schema: OBJ },
  ),
  () => agent(
    `Load skill source-analyzer. Analyze project ${args.projectPath}. Use CodeGraph MCP first when available. Source is read-only. Return the required JSON only.`,
    { label: 'source-analyzer', phase: 'Analyze', schema: OBJ },
  ),
])
if (requirements === null) throw new Error('urd-analyzer failed')
if (sourceAnalysis === null) throw new Error('source-analyzer failed')

phase('Compliance')
const compliance = await agent(
  `Load skill requirement-checker.
Project: ${args.projectPath}
URD path: ${args.urdPath}
Normalized requirements:\n${asText(requirements)}\n
Source analysis:\n${asText(sourceAnalysis)}\n
Return the required JSON only.`,
  { label: 'requirement-checker', phase: 'Compliance', schema: OBJ },
)
if (compliance === null) throw new Error('requirement-checker failed')

phase('Plan')
let tasks = await agent(
  `Load skill task-planner.
Project: ${args.projectPath}
Requirements:\n${asText(requirements)}\n
Compliance:\n${asText(compliance)}\n
Source analysis:\n${asText(sourceAnalysis)}\n
Return the required JSON only.`,
  { label: 'task-planner', phase: 'Plan', schema: OBJ },
)
if (tasks === null) throw new Error('task-planner failed')

phase('Task review')
let taskReview = null
for (let attempt = 1; attempt <= 3; attempt++) {
  taskReview = await agent(
    `Load skill task-reviewer.
Review attempt: ${attempt}/3
Project: ${args.projectPath}
Requirements:\n${asText(requirements)}\n
Compliance:\n${asText(compliance)}\n
Proposed tasks:\n${asText(tasks)}\n
Use Ponytail and CodeGraph when available. Return the required JSON only.`,
    { label: `task-reviewer ${attempt}`, phase: 'Task review', schema: OBJ },
  )
  if (taskReview === null) throw new Error('task-reviewer failed')
  if (/"decision"\s*:\s*"PASS"/i.test(asText(taskReview))) break

  if (attempt < 3) {
    tasks = await agent(
      `Load skill task-planner.
Revise the plan based on the independent review.
Project: ${args.projectPath}
Requirements:\n${asText(requirements)}\n
Compliance:\n${asText(compliance)}\n
Previous tasks:\n${asText(tasks)}\n
Review:\n${asText(taskReview)}\n
Return the required JSON only.`,
      { label: `task-planner revise ${attempt}`, phase: 'Plan', schema: OBJ },
    )
    if (tasks === null) throw new Error('task-planner revision failed')
  }
}

phase('Report')
await agent(
  `You are a scribe. Do not edit project source. Create ${args.runPath} if needed.
Write ${args.runPath}/board.json summarizing assessment members (urd-analyzer, source-analyzer, requirement-checker, task-planner, task-reviewer) with status completed or failed from this review:\n${asText(taskReview)}\n
Write a short ${args.runPath}/report.md. Return JSON {"written":true}.`,
  { label: 'scribe', phase: 'Report', schema: OBJ },
)

return {
  mode: 'assessment',
  projectId: args.projectId,
  projectPath: args.projectPath,
  urdPath: args.urdPath,
  runPath: args.runPath,
  reportPath: `${args.runPath}/report.md`,
  boardPath: `${args.runPath}/board.json`,
  requirements,
  sourceAnalysis,
  compliance,
  tasks,
  taskReview,
}
