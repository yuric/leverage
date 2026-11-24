const stages = ['Browse', 'Send', 'In progress', 'Done']

export function mountWorkflow(root, scheduler = globalThis) {
  const steps = stages.map((_, index) => root.querySelector(`[data-demo-step="${index}"]`))
  const panels = stages.map((_, index) => root.querySelector(`[data-demo-panel="${index}"]`))
  const status = root.querySelector('[data-demo-status]')
  let stage = 0
  let playback = null

  function show(next, { focusHeading = false, announce = true } = {}) {
    stage = next
    root.dataset.stage = String(stage)
    panels.forEach((panel, index) => {
      panel.hidden = index !== stage
      if (index === stage) {
        steps[index].setAttribute('aria-current', 'step')
      } else {
        steps[index].removeAttribute('aria-current')
      }
    })

    status.textContent = announce && !focusHeading ? stages[stage] : ''
    if (focusHeading) panels[stage].querySelector('[data-demo-heading]').focus()
  }

  steps.forEach((step, index) => {
    step.addEventListener('click', () => {
      if (playback !== null) {
        scheduler.clearTimeout(playback)
        playback = null
      }
      show(index)
    })
  })

  root.querySelector('[data-demo-try]').addEventListener('click', () => {
    show(1, { focusHeading: true })
  })
  root.querySelector('[data-demo-run]').addEventListener('click', () => {
    show(2, { focusHeading: true })
    playback = scheduler.setTimeout(() => {
      playback = null
      const focusHeading = panels[stage].contains(root.ownerDocument.activeElement)
      show(3, { focusHeading })
    }, 2300)
  })
  root.querySelector('[data-demo-reset]').addEventListener('click', () => {
    show(0, { focusHeading: true })
  })

  show(0, { announce: false })
  root.dataset.enhanced = ''
}

if (typeof document !== 'undefined') {
  document.querySelectorAll('[data-workflow]').forEach((root) => mountWorkflow(root))
}
