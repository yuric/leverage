import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import test from 'node:test'
import { mountWorkflow } from '../marketing-page/workflow.mjs'

const page = readFileSync(new URL('../marketing-page/index.html', import.meta.url), 'utf8')

function block(pattern) {
  const match = page.match(pattern)
  assert.ok(match, `the page has no block matching ${pattern}`)
  return match[0]
}

test('the Handoff section appears before the Imaginarium', () => {
  const demoSections = [...page.matchAll(/<section\b[^>]*\sid="(handoffs|imaginarium)"/g)]
    .map(([, id]) => id)
  assert.deepEqual(demoSections, ['handoffs', 'imaginarium'])
})

test('the Handoff section says how far handoff is proven and labels its diagram', () => {
  const section = block(/<section\b[^>]*\sid="handoffs"[\s\S]*?<\/section>/)
  assert.match(section, /href="https:\/\/github\.com\/yuric\/leverage\/blob\/main\/docs\/IMPLEMENTATION\.md#what-the-handoff-milestone-proves-and-how-far"/)
  assert.match(section, /stand-in tools/)
  assert.match(block(/<div class="handoff-header">[\s\S]*?<\/button>/), /class="demo-label">Illustration</)
})

test('the footer says Leverage is not affiliated with any provider the page names', () => {
  const footer = block(/<footer class="site-footer">[\s\S]*?<\/footer>/)
  assert.match(footer, /not affiliated with or endorsed by/)
  const providers = [...block(/<ul aria-label="Example agent providers">[\s\S]*?<\/ul>/)
    .matchAll(/<\/span>\s*([^<]+?)\s*<\/li>/g)].map(([, name]) => name)
  assert.ok(providers.length > 0)
  providers.forEach((name) => assert.match(footer, new RegExp(`\\b${name}\\b`)))
})

const fields = ['title', 'brief', 'check', 'delivery']

function fixture() {
  const ownerDocument = { activeElement: null }

  function element() {
    const control = new EventTarget()
    control.dataset = {}
    control.click = () => {
      control.focus()
      control.dispatchEvent(new Event('click'))
    }
    control.focus = () => { ownerDocument.activeElement = control }
    control.hidden = false
    return control
  }

  const panels = Array.from({ length: 5 }, element)
  const headings = panels.map((panel) => {
    const heading = element()
    panel.querySelector = (selector) => {
      assert.equal(selector, '[data-demo-heading]')
      return heading
    }
    return heading
  })
  const cards = ['Calendar', 'Inventory'].map((example) => {
    const button = element()
    fields.forEach((field) => { button.dataset[field] = `${example} ${field}` })
    return button
  })
  const reset = element()
  const outside = element()
  const status = element()
  const examples = Object.fromEntries(fields.map((field) => [field, [element(), element()]]))
  const children = [[headings[0], ...cards], [headings[1]], [headings[2]], [headings[3]], [headings[4], reset]]
  panels.forEach((panel, index) => {
    panel.contains = (node) => children[index].includes(node)
  })
  const selectors = new Map([
    ...panels.map((panel, index) => [`[data-demo-panel="${index}"]`, panel]),
    ['[data-demo-try]', cards[0]],
    ['[data-demo-reset]', reset],
    ['[data-demo-status]', status],
  ])
  const root = {
    ownerDocument,
    dataset: {},
    querySelector: (selector) => selectors.get(selector),
    querySelectorAll(selector) {
      if (selector === '[data-demo-try]') return cards
      const [, field] = selector.match(/^\[data-example="(\w+)"\]$/)
      return examples[field]
    },
  }
  const timers = new Map()
  let nextTimer = 0
  const scheduler = {
    setTimeout(callback, delay) {
      assert.ok(delay > 0)
      timers.set(++nextTimer, callback)
      return nextTimer
    },
  }
  function advance() {
    assert.equal(timers.size, 1)
    const [handle, callback] = timers.entries().next().value
    timers.delete(handle)
    callback()
  }
  function assertStage(stage, announcement) {
    assert.equal(root.dataset.stage, String(stage))
    assert.deepEqual(panels.map((panel) => panel.hidden), panels.map((_, index) => index !== stage))
    if (announcement) assert.equal(status.textContent, announcement)
  }
  function assertExample(card) {
    fields.forEach((field) => {
      examples[field].forEach((node) => assert.equal(node.textContent, card.dataset[field]))
    })
  }

  mountWorkflow(root, scheduler)
  return { root, ownerDocument, headings, cards, reset, outside, timers, advance, assertStage, assertExample }
}

const playback = ['Ready', 'Building', 'In review', 'Done']

test('one Try click fills the selected example and automatically plays through all four stages', () => {
  const demo = fixture()
  assert.equal(demo.root.dataset.enhanced, '')
  demo.assertStage(0)

  const card = demo.cards[1]
  card.click()
  playback.forEach((announcement, index) => {
    if (index > 0) demo.advance()
    demo.assertStage(index + 1, announcement)
    demo.assertExample(card)
    assert.equal(demo.ownerDocument.activeElement, demo.headings[index + 1])
  })
  assert.equal(demo.timers.size, 0)

  demo.reset.click()
  demo.assertStage(0, 'Gallery')
  assert.equal(demo.ownerDocument.activeElement, card)

  const otherCard = demo.cards[0]
  otherCard.click()
  playback.forEach((announcement, index) => {
    if (index > 0) demo.advance()
    demo.assertStage(index + 1, announcement)
    demo.assertExample(otherCard)
  })
  assert.equal(demo.timers.size, 0)
})

test('timed transitions announce stages without stealing external focus', () => {
  const demo = fixture()
  demo.cards[0].click()
  demo.outside.focus()

  playback.slice(1).forEach((announcement, index) => {
    demo.advance()
    demo.assertStage(index + 2, announcement)
    assert.equal(demo.ownerDocument.activeElement, demo.outside)
  })
})

test('ignores hidden controls while playback is active', () => {
  const demo = fixture()
  demo.cards[0].click()
  demo.cards[1].dispatchEvent(new Event('click'))
  demo.reset.dispatchEvent(new Event('click'))
  demo.assertStage(1, 'Ready')
  demo.assertExample(demo.cards[0])
  assert.equal(demo.timers.size, 1)
})
