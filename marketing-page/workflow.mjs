const stages = ['Gallery', 'Ready', 'Building', 'In review', 'Done']
const stageDurations = [0, 1300, 2000, 2000]
const exampleFields = ['title', 'brief', 'check', 'delivery']

export function mountWorkflow(root, scheduler = globalThis) {
  const panels = stages.map((_, index) => root.querySelector(`[data-demo-panel="${index}"]`))
  const headings = panels.map((panel) => panel.querySelector('[data-demo-heading]'))
  const status = root.querySelector('[data-demo-status]')
  const exampleNodes = exampleFields.map((field) => root.querySelectorAll(`[data-example="${field}"]`))
  let stage = 0
  let selectedCard = null

  function show(next, { focusTarget, announce = true } = {}) {
    stage = next
    root.dataset.stage = String(stage)
    panels.forEach((panel, index) => { panel.hidden = index !== stage })
    status.textContent = announce ? stages[stage] : ''
    focusTarget?.focus()
  }

  function advance() {
    const next = stage + 1
    const focusTarget = panels[stage].contains(root.ownerDocument.activeElement) ? headings[next] : null
    show(next, { focusTarget })
    scheduleAdvance()
  }

  function scheduleAdvance() {
    const duration = stageDurations[stage]
    if (duration) scheduler.setTimeout(advance, duration)
  }

  root.querySelectorAll('[data-demo-try]').forEach((button) => {
    button.addEventListener('click', () => {
      if (stage !== 0) return

      selectedCard = button
      exampleFields.forEach((field, index) => {
        exampleNodes[index].forEach((node) => { node.textContent = button.dataset[field] })
      })
      show(1, { focusTarget: headings[1] })
      scheduleAdvance()
    })
  })

  root.querySelector('[data-demo-reset]').addEventListener('click', () => {
    if (stage !== stages.length - 1) return

    const focusTarget = panels[0].contains(selectedCard) ? selectedCard : headings[0]
    show(0, { focusTarget })
    selectedCard = null
  })

  show(0, { announce: false })
  root.dataset.enhanced = ''
}

if (typeof document !== 'undefined') {
  document.querySelectorAll('[data-workflow]').forEach((root) => mountWorkflow(root))
}
