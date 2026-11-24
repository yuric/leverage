import assert from 'node:assert/strict'
import test from 'node:test'
import { mountWorkflow } from '../marketing-page/workflow.mjs'

function fixture() {
  const ownerDocument = { activeElement: null }
  const elements = new Map()

  function element(selector) {
    const attributes = new Map()
    const control = new EventTarget()
    control.click = () => {
      control.focus()
      control.dispatchEvent(new Event('click'))
    }
    control.focus = () => { ownerDocument.activeElement = control }
    control.setAttribute = (name, value) => attributes.set(name, value)
    control.getAttribute = (name) => attributes.get(name)
    control.removeAttribute = (name) => attributes.delete(name)
    elements.set(selector, control)
    return control
  }

  const steps = Array.from({ length: 4 }, (_, index) => element(`[data-demo-step="${index}"]`))
  const panels = Array.from({ length: 4 }, (_, index) => element(`[data-demo-panel="${index}"]`))
  const headings = panels.map((panel) => {
    const heading = element(Symbol())
    panel.querySelector = (selector) => {
      assert.equal(selector, '[data-demo-heading]')
      return heading
    }
    return heading
  })
  const tryIt = element('[data-demo-try]')
  const run = element('[data-demo-run]')
  const reset = element('[data-demo-reset]')
  const outside = element(Symbol())
  const status = element('[data-demo-status]')
  const children = [[headings[0], tryIt], [headings[1], run], [headings[2]], [headings[3], reset]]
  panels.forEach((panel, index) => {
    panel.contains = (node) => children[index].includes(node)
  })
  const root = {
    ownerDocument,
    dataset: {},
    querySelector: (selector) => elements.get(selector),
  }
  const timers = new Map()
  let nextTimer = 0
  const scheduler = {
    setTimeout(callback, delay) {
      assert.equal(delay, 2300)
      timers.set(++nextTimer, callback)
      return nextTimer
    },
    clearTimeout(handle) {
      timers.delete(handle)
    },
  }
  function finishPlayback() {
    assert.equal(timers.size, 1)
    const [handle, callback] = timers.entries().next().value
    timers.delete(handle)
    callback()
  }
  function assertStage(stage) {
    assert.equal(root.dataset.stage, String(stage))
    assert.deepEqual(panels.map((panel) => panel.hidden), panels.map((_, index) => index !== stage))
    assert.deepEqual(steps.map((step) => step.getAttribute('aria-current')),
      steps.map((_, index) => index === stage ? 'step' : undefined))
  }

  mountWorkflow(root, scheduler)
  return { root, ownerDocument, steps, headings, tryIt, run, reset, outside, status, timers, finishPlayback, assertStage }
}

test('Try it and Send to Ready play through Done and move focus as panels hide', () => {
  const demo = fixture()
  assert.equal(demo.root.dataset.enhanced, '')
  demo.assertStage(0)

  demo.tryIt.click()
  demo.assertStage(1)
  assert.equal(demo.ownerDocument.activeElement, demo.headings[1])

  demo.run.click()
  demo.assertStage(2)
  assert.equal(demo.ownerDocument.activeElement, demo.headings[2])

  demo.finishPlayback()
  demo.assertStage(3)
  assert.equal(demo.ownerDocument.activeElement, demo.headings[3])
  assert.equal(demo.status.textContent, '')
})

test('step buttons cancel playback, retain focus and announce the new stage', () => {
  const demo = fixture()
  demo.tryIt.click()
  demo.run.click()
  assert.equal(demo.timers.size, 1)

  demo.steps[0].click()
  demo.assertStage(0)
  assert.equal(demo.ownerDocument.activeElement, demo.steps[0])
  assert.equal(demo.timers.size, 0)
  assert.match(demo.status.textContent, /browse/i)

  demo.steps[3].click()
  demo.assertStage(3)
  assert.equal(demo.ownerDocument.activeElement, demo.steps[3])
})

test('playback announces Done without moving external focus and can be replayed', () => {
  const demo = fixture()
  demo.steps[1].click()
  demo.run.click()
  demo.outside.focus()

  demo.finishPlayback()
  demo.assertStage(3)
  assert.equal(demo.ownerDocument.activeElement, demo.outside)
  assert.match(demo.status.textContent, /done/i)

  demo.reset.click()
  demo.assertStage(0)
  assert.equal(demo.ownerDocument.activeElement, demo.headings[0])
  demo.tryIt.click()
  demo.run.click()
  demo.finishPlayback()
  demo.assertStage(3)
})
