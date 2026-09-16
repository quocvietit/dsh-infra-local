// Orchestrate assessment or full delivery.
// Required args: projectId, projectPath, urdPath, runPath
// Optional args.mode: assessment | full-delivery (default full-delivery)

const required = ['projectId', 'projectPath', 'urdPath', 'runPath']
for (const key of required) {
  if (!args || typeof args[key] !== 'string' || args[key].trim() === '') {
    throw new Error(`Missing workflow arg: ${key}`)
  }
}

const mode = args.mode === 'assessment' ? 'assessment' : 'full-delivery'
const OBJ = { type: 'object', additionalProperties: true }

function asText(value) {
  if (value == null) return ''
  if (typeof value === 'string') return value
  try { return JSON.stringify(value) } catch { return String(value) }
}

function asObject(value) {
  if (value == null) return null
  if (typeof value === 'object') return value
  if (typeof value !== 'string') return null
  try { return JSON.parse(value) } catch { return null }
}

function taskList(value) {
  const obj = asObject(value)
  if (!obj || !Array.isArray(obj.tasks)) return []
  return obj.tasks.filter(task => task && typeof task.id === 'string')
}

function resourceKeys(task) {
  return [...(task.files || []), ...(task.symbols || [])].map(item => String(item))
}

function nextWave(tasks, doneIds) {
  const remaining = tasks.filter(task => !doneIds.has(task.id))
  const ready = remaining.filter(task => (task.dependsOn || []).every(dep => doneIds.has(dep)))
  const wave = []
  const locked = new Set()
  for (const task of ready) {
    const keys = resourceKeys(task)
    if (keys.some(key => locked.has(key))) continue
    wave.push(task)
    for (const key of keys) locked.add(key)
  }
  if (wave.length === 0 && ready.length > 0) wave.push(ready[0])
  return wave
}

function boardPayload(statusRows) {
  return {
    runPath: args.runPath,
    projectId: args.projectId,
    mode,
    updatedAt: 'workflow',
    tasks: statusRows,
  }
}

async function scribe(statusRows, note) {
  log(note)
  const payload = asText(boardPayload(statusRows))
  const result = await agent(
    `You are a scribe. Do not edit project source. Create directory ${args.runPath} if needed.
Write exactly this JSON to ${args.runPath}/board.json:\n${payload}\n
Update ${args.runPath}/report.md with a markdown table of id, label, skill, phase, status.
Note: ${note}
Return JSON only: {"written":true,"boardPath":"...","reportPath":"..."}`,
    { label: 'scribe', phase: 'Report', schema: OBJ },
  )
  if (result === null) throw new Error('scribe failed')
  return result
}

const statusRows = []

function remember(id, label, skill, phase, status) {
  const existing = statusRows.find(row => row.id === id && row.phase === phase)
  const row = { id, label, skill, status, phase }
  if (existing) Object.assign(existing, row)
  else statusRows.push(row)
}

log(`${mode} start: ${args.projectId}`)

phase('Analyze')
const [requirements, sourceAnalysis] = await parallel([
  () => agent(
    `Load skill urd-analyzer. Read URD at ${args.urdPath}. Return JSON only.`,
    { label: 'urd-analyzer', phase: 'Analyze', schema: OBJ },
  ),
  () => agent(
    `Load skill source-analyzer. Analyze project ${args.projectPath}. Use CodeGraph first when available. Return JSON only.`,
    { label: 'source-analyzer', phase: 'Analyze', schema: OBJ },
  ),
])
if (requirements === null || sourceAnalysis === null) throw new Error('initial analysis failed')
remember('REQ', 'urd-analyzer', 'urd-analyzer', 'Analyze', 'completed')
remember('SRC', 'source-analyzer', 'source-analyzer', 'Analyze', 'completed')

phase('Compliance')
const compliance = await agent(
  `Load skill requirement-checker. Project: ${args.projectPath}\nRequirements:\n${asText(requirements)}\nSource analysis:\n${asText(sourceAnalysis)}\nReturn JSON only.`,
  { label: 'requirement-checker', phase: 'Compliance', schema: OBJ },
)
if (compliance === null) throw new Error('requirement-checker failed')
remember('CMP', 'requirement-checker', 'requirement-checker', 'Compliance', 'completed')

phase('Plan')
let tasks = await agent(
  `Load skill task-planner. Project: ${args.projectPath}\nRequirements:\n${asText(requirements)}\nCompliance:\n${asText(compliance)}\nSource analysis:\n${asText(sourceAnalysis)}\nReturn JSON only.`,
  { label: 'task-planner', phase: 'Plan', schema: OBJ },
)
if (tasks === null) throw new Error('task-planner failed')

phase('Task review')
let taskReview = null
for (let attempt = 1; attempt <= 3; attempt++) {
  taskReview = await agent(
    `Load skill task-reviewer. Attempt ${attempt}/3. Project: ${args.projectPath}\nRequirements:\n${asText(requirements)}\nCompliance:\n${asText(compliance)}\nTasks:\n${asText(tasks)}\nUse Ponytail and CodeGraph when available. Return JSON only.`,
    { label: `task-reviewer ${attempt}`, phase: 'Task review', schema: OBJ },
  )
  if (taskReview === null) throw new Error('task-reviewer failed')
  const passed = /"decision"\s*:\s*"PASS"/i.test(asText(taskReview))
  if (passed) break
  if (attempt < 3) {
    tasks = await agent(
      `Load skill task-planner. Revise rejected plan.\nRequirements:\n${asText(requirements)}\nCompliance:\n${asText(compliance)}\nPrevious tasks:\n${asText(tasks)}\nReview:\n${asText(taskReview)}\nReturn JSON only.`,
      { label: `task-planner revise ${attempt}`, phase: 'Plan', schema: OBJ },
    )
    if (tasks === null) throw new Error('task-plan revision failed')
  }
}

remember('PLAN', 'task-planner', 'task-planner', 'Plan', 'completed')
remember('TREV', 'task-reviewer', 'task-reviewer', 'Task review', /"decision"\s*:\s*"PASS"/i.test(asText(taskReview)) ? 'completed' : 'failed')
await scribe(statusRows, 'planning complete')

if (mode === 'assessment') {
  return {
    mode: 'assessment',
    projectId: args.projectId,
    projectPath: args.projectPath,
    urdPath: args.urdPath,
    runPath: args.runPath,
    reportPath: `${args.runPath}/report.md`,
    boardPath: `${args.runPath}/board.json`,
    requirements, sourceAnalysis, compliance, tasks, taskReview,
  }
}

if (!/"decision"\s*:\s*"PASS"/i.test(asText(taskReview || ''))) {
  return {
    mode: 'full-delivery',
    decision: 'STOP_TASK_REVIEW',
    projectId: args.projectId,
    runPath: args.runPath,
    reportPath: `${args.runPath}/report.md`,
    requirements, sourceAnalysis, compliance, tasks, taskReview,
  }
}

const planned = taskList(tasks)
if (planned.length === 0) throw new Error('task-planner returned no tasks')
for (const task of planned) {
  remember(task.id, `${task.id} implementer`, 'implementer', 'Implement', 'pending')
}

const doneIds = new Set()
const implementations = []
let guard = 0
phase('Implement')
while (doneIds.size < planned.length) {
  guard += 1
  if (guard > planned.length + 2) throw new Error('task DAG could not make progress (cycle or missing dependsOn)')
  const wave = nextWave(planned, doneIds)
  if (wave.length === 0) throw new Error('task DAG stalled')
  for (const task of wave) remember(task.id, `${task.id} implementer`, 'implementer', 'Implement', 'running')
  await scribe(statusRows, `implement wave ${wave.map(task => task.id).join(',')}`)

  const waveResults = await pipeline(
    wave,
    (_prev, task) => agent(
      `Load skill implementer. Implement only task ${task.id} in ${args.projectPath}.
runPath: ${args.runPath}
Approved task JSON:\n${asText(task)}\n
Requirements:\n${asText(requirements)}\n
Return JSON only.`,
      { label: `${task.id} implementer`, phase: 'Implement', schema: OBJ },
    ),
    (implementation, task) => {
      implementations.push({ taskId: task.id, implementation })
      const ok = implementation !== null && !/"status"\s*:\s*"BLOCKED"/i.test(asText(implementation))
      remember(task.id, `${task.id} implementer`, 'implementer', 'Implement', ok ? 'completed' : 'failed')
      return agent(
        `Load skill unit-test-agent. Project ${args.projectPath}. Focus on task ${task.id}.
runPath: ${args.runPath}
Approved task:\n${asText(task)}\n
Implementation:\n${asText(implementation)}\n
Return JSON only.`,
        { label: `${task.id} unit-test`, phase: 'Test', schema: OBJ },
      )
    },
  )

  for (let i = 0; i < wave.length; i++) {
    const task = wave[i]
    const unit = waveResults[i]
    remember(`${task.id}-ut`, `${task.id} unit-test`, 'unit-test-agent', 'Test', unit === null ? 'failed' : 'completed')
    doneIds.add(task.id)
  }
}

phase('Test')
let [unitTests, testCases] = await parallel([
  () => agent(
    `Load skill unit-test-agent. Project ${args.projectPath}. Reconcile unit tests for all approved tasks.
runPath: ${args.runPath}
Approved tasks:\n${asText(tasks)}\n
Implementations:\n${asText(implementations)}\n
Return JSON only.`,
    { label: 'unit-test-agent', phase: 'Test', schema: OBJ },
  ),
  () => agent(
    `Load skill testcase-designer. URD ${args.urdPath}. Requirements:\n${asText(requirements)}\nTasks:\n${asText(tasks)}\nReturn JSON only.`,
    { label: 'testcase-designer', phase: 'Test', schema: OBJ },
  ),
])
if (unitTests === null || testCases === null) throw new Error('test preparation failed')
remember('UT', 'unit-test-agent', 'unit-test-agent', 'Test', 'completed')
remember('TC', 'testcase-designer', 'testcase-designer', 'Test', 'completed')

let integrationTests = await agent(
  `Load skill integration-test-agent. Project ${args.projectPath}.
runPath: ${args.runPath}
Requirements:\n${asText(requirements)}\nTasks:\n${asText(tasks)}\nTest cases:\n${asText(testCases)}\nReturn JSON only.`,
  { label: 'integration-test-agent', phase: 'Test', schema: OBJ },
)
if (integrationTests === null) throw new Error('integration-test-agent failed')
remember('IT', 'integration-test-agent', 'integration-test-agent', 'Test', 'completed')

phase('Review')
let implementation = implementations
let codeReview = await agent(
  `Load skill code-reviewer. Project ${args.projectPath}.
runPath: ${args.runPath}
Requirements:\n${asText(requirements)}\nApproved tasks:\n${asText(tasks)}\nImplementation:\n${asText(implementation)}\nUnit tests:\n${asText(unitTests)}\nIntegration tests:\n${asText(integrationTests)}\nUse CodeGraph and Ponytail when available. Return JSON only.`,
  { label: 'code-reviewer', phase: 'Review', schema: OBJ },
)
if (codeReview === null) throw new Error('code-reviewer failed')

for (let attempt = 1; attempt <= 3 && /"decision"\s*:\s*"REQUEST_CHANGES"/i.test(asText(codeReview)); attempt++) {
  implementation = await agent(
    `Load skill implementer. Fix only the approved review findings in project ${args.projectPath}.
runPath: ${args.runPath}
Approved tasks:\n${asText(tasks)}\nReview findings:\n${asText(codeReview)}\nReturn JSON only.`,
    { label: `review-fix ${attempt}`, phase: 'Implement', schema: OBJ },
  )
  if (implementation === null) throw new Error('review-fix implementer failed')
  unitTests = await agent(
    `Load skill unit-test-agent. Re-run/update unit tests after review fixes in ${args.projectPath}.
runPath: ${args.runPath}
Tasks:\n${asText(tasks)}\nImplementation:\n${asText(implementation)}\nReturn JSON only.`,
    { label: `unit-test rerun ${attempt}`, phase: 'Test', schema: OBJ },
  )
  if (unitTests === null) throw new Error('unit-test rerun failed')
  integrationTests = await agent(
    `Load skill integration-test-agent. Re-run integration tests after review fixes in ${args.projectPath}.
runPath: ${args.runPath}
Tasks:\n${asText(tasks)}\nReturn JSON only.`,
    { label: `integration rerun ${attempt}`, phase: 'Test', schema: OBJ },
  )
  if (integrationTests === null) throw new Error('integration-test rerun failed')
  codeReview = await agent(
    `Load skill code-reviewer. Re-review project ${args.projectPath} after fixes.
runPath: ${args.runPath}
Requirements:\n${asText(requirements)}\nTasks:\n${asText(tasks)}\nImplementation:\n${asText(implementation)}\nUnit tests:\n${asText(unitTests)}\nIntegration tests:\n${asText(integrationTests)}\nReturn JSON only.`,
    { label: `code-reviewer ${attempt + 1}`, phase: 'Review', schema: OBJ },
  )
  if (codeReview === null) throw new Error('code-review rerun failed')
}

remember('CR', 'code-reviewer', 'code-reviewer', 'Review', /"decision"\s*:\s*"PASS"/i.test(asText(codeReview)) ? 'completed' : 'failed')
await scribe(statusRows, 'review complete')

phase('Report')
const finalReport = await agent(
  `Load skill final-verifier.
runPath: ${args.runPath}
Requirements:\n${asText(requirements)}\nCompliance:\n${asText(compliance)}\nTasks:\n${asText(tasks)}\nTask review:\n${asText(taskReview)}\nImplementation:\n${asText(implementation)}\nUnit tests:\n${asText(unitTests)}\nTest cases:\n${asText(testCases)}\nIntegration tests:\n${asText(integrationTests)}\nCode review:\n${asText(codeReview)}\nReturn JSON only.`,
  { label: 'final-verifier', phase: 'Report', schema: OBJ },
)
if (finalReport === null) throw new Error('final-verifier failed')
remember('FIN', 'final-verifier', 'final-verifier', 'Report', 'completed')
await scribe(statusRows, 'final report written')

return {
  mode: 'full-delivery',
  projectId: args.projectId,
  projectPath: args.projectPath,
  urdPath: args.urdPath,
  runPath: args.runPath,
  reportPath: `${args.runPath}/report.md`,
  boardPath: `${args.runPath}/board.json`,
  finalReportPath: `${args.runPath}/final-report.json`,
  decision: asObject(finalReport)?.decision || null,
}
