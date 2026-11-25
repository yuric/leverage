'use strict';

const billing = createMockBilling();
const workspace = document.querySelector('#workspace');
const accountButton = document.querySelector('#account-button');
const accountMenu = document.querySelector('#account-menu');
const appearance = document.querySelector('#appearance');
const announcement = document.querySelector('#announcement');
const dialog = document.querySelector('#flow');
const dialogContent = document.querySelector('#flow-content');
const money = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD', maximumFractionDigits: 0 });
const calendar = new Intl.DateTimeFormat('en-US', { dateStyle: 'medium', timeZone: 'UTC' });
const methodNames = { apple_pay: 'Apple Pay', link: 'Link', card: 'Credit or debit card' };
let screen = 'subscription';
let dialogStage = null;
let returnFocus;

function escapeText(value) {
  return String(value).replace(/[&<>"']/g, char => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[char]);
}

function price(cents) { return money.format(cents / 100); }
function date(iso) { return calendar.format(new Date(iso + 'T00:00:00Z')); }
function planFor(snapshot, id) { return snapshot.plans.find(plan => plan.id === id); }
function pricePerMonth(plan) { return price(plan.amountCents) + ' a month'; }

function button(action, label, style = '', value = '') {
  return `<button type="button" class="${style}" data-action="${action}" data-value="${escapeText(value)}">${escapeText(label)}</button>`;
}

function heading(title, description = '') {
  return `<header class="section-heading"><div><h2>${title}</h2>
    ${description ? `<p>${description}</p>` : ''}</div></header>`;
}

function plansPage(snapshot, changing) {
  const cards = snapshot.plans.map(plan => {
    const current = changing && snapshot.planId === plan.id;
    return `<article class="plan${current ? ' is-current' : ''}">
      <div><h3>${plan.name}</h3><p class="price"><strong>${price(plan.amountCents)}</strong> / month</p></div>
      <div class="plan-details"><p>Plan details pending</p><p>Support details pending</p></div>
      ${current ? '<button type="button" disabled>Your plan</button>'
        : button(changing ? 'pick-change' : 'choose', 'Choose ' + plan.name, 'primary', plan.id)}
    </article>`;
  }).join('');
  return `${changing ? button('subscription', '‹ Subscription', 'quiet') : ''}
    ${heading(changing ? 'Change plan' : 'Subscription', 'Monthly plans in US dollars.')}
    <div class="plans">${cards}</div>
    ${changing ? '' : '<p class="plan-footer">Pay with Apple Pay, Link or a card through Stripe.</p>'}`;
}

function paymentSummary(method) {
  if (method.kind !== 'card') return methodNames[method.kind];
  const expiry = String(method.expiresMonth).padStart(2, '0') + '/' + method.expiresYear;
  return `${escapeText(method.brand)} ending in ${escapeText(method.last4)} · Expires ${escapeText(expiry)}`;
}

function subscriptionPage(snapshot) {
  if (snapshot.status === 'none') return plansPage(snapshot, false);
  const plan = planFor(snapshot, snapshot.planId);
  const due = snapshot.paymentDue;
  const scheduled = planFor(snapshot, snapshot.scheduledPlanId);
  const active = snapshot.status === 'active';
  const manageable = active || snapshot.status === 'payment_due';
  const receipts = snapshot.receipts.map(receipt => `<div class="panel-row">
    <div class="paid-receipt"><time datetime="${escapeText(receipt.paidOn)}">${date(receipt.paidOn)}</time>
    <strong>${price(receipt.amountCents)}</strong><span>${planFor(snapshot, receipt.planId).name}</span><span class="badge">Paid</span></div>
    ${button('receipt', 'View', '', receipt.id)}</div>`).join('');
  return `${heading('Subscription')}<div class="stack">
    ${due ? `<section class="banner"><strong>Your subscription payment didn’t go through.</strong>
      <p>Update your payment method by ${date(due.graceUntil)}. Until then, everything keeps working.</p></section>` : ''}
    <section class="panel"><div class="panel-row"><div><h3>${plan.name} · ${pricePerMonth(plan)}</h3>
      ${snapshot.cancelOn ? `<p class="detail">Ends ${date(snapshot.cancelOn)}. No further payment is scheduled.</p>`
        : due ? `<p class="detail">Payment due ${price(due.amountCents)}.</p>`
        : `<p class="detail">Next payment ${price((scheduled ?? plan).amountCents)} on ${date(snapshot.nextPaymentOn)}.</p>`}
      ${scheduled ? `<p class="detail">Changing to ${scheduled.name} at renewal.</p>` : ''}
      <p class="detail">Plan and subscriber support details pending.</p></div>
      ${manageable ? button('change', 'Change plan') : ''}</div></section>
    <section class="panel"><div class="panel-row"><div><h3>Payment method</h3>
      <p class="detail">${paymentSummary(snapshot.paymentMethod)}</p></div>${button('update', 'Update')}</div></section>
    <section class="panel"><h3>Receipts</h3>${receipts}</section>
    ${manageable ? '<div>' + button('cancel-subscription', 'Cancel subscription', 'danger') + '</div>' : ''}
    ${active || due ? `<div class="preview-actions">
      ${active ? button('fail', 'Simulate failed renewal') : button('recover', 'Simulate successful retry')}
      <span>Preview controls · dates are illustrative</span></div>` : ''}
    </div>`;
}

function needsPage(snapshot) {
  const due = snapshot.paymentDue;
  return `${heading('Needs you')}${due
    ? `<section class="panel stack"><div><span class="badge">Subscription</span>
      <h3>Your subscription payment didn’t go through</h3>
      <p class="detail">${price(due.amountCents)} for ${planFor(snapshot, due.planId).name} · Declined ${date(due.failedOn)}</p></div>
      <div class="actions">${button('update', 'Update payment method', 'primary')}${button('subscription', 'Open Subscription')}</div></section>`
    : '<p class="empty">No subscription items need your attention.</p>'}`;
}

function render() {
  const snapshot = billing.getSnapshot();
  const plan = planFor(snapshot, snapshot.planId);
  const due = snapshot.status === 'payment_due';
  const rowLabel = due ? 'Card declined' : plan?.name ?? 'No subscription';
  const accountPlan = document.querySelector('#account-plan');
  accountPlan.textContent = rowLabel;
  accountPlan.classList.toggle('payment-due', due);
  accountButton.setAttribute('aria-label', 'Subscription, settings and sign out, name@example.com, ' + rowLabel);
  accountButton.classList.toggle('active', screen === 'subscription' || screen === 'change');
  document.querySelector('#menu-plan').textContent = plan ? plan.name + ', ' + pricePerMonth(plan) : rowLabel;
  document.querySelector('#needs-count').hidden = !due;
  document.querySelectorAll('.navigation [data-action]').forEach(item => {
    if (item.dataset.action === screen) item.setAttribute('aria-current', 'page');
    else item.removeAttribute('aria-current');
  });
  if (screen === 'board') {
    workspace.innerHTML = `${heading('Task board')}
      <section class="panel task-card"><h3>Review the onboarding draft</h3>
      <p class="detail">Sample project</p><span class="badge">In progress</span></section>`;
  } else if (screen === 'needs') {
    workspace.innerHTML = needsPage(snapshot);
  } else {
    workspace.innerHTML = screen === 'change' ? plansPage(snapshot, true) : subscriptionPage(snapshot);
  }
}

function setMenu(open) {
  accountMenu.hidden = !open;
  accountButton.setAttribute('aria-expanded', String(open));
  if (open) accountMenu.querySelector('button').focus();
}

function navigate(view) {
  screen = view;
  render();
  workspace.focus();
}

function showDialog(stage, title, content, actions) {
  if (!dialog.open) returnFocus = document.activeElement;
  dialogStage = stage;
  dialogContent.innerHTML = `<h2 id="flow-title">${title}</h2>${content}<div class="actions">${actions}</div>`;
  if (!dialog.open) dialog.showModal();
  dialogContent.querySelector('button').focus();
}

function closeDialog() {
  dialogStage = null;
  dialog.close();
  (returnFocus?.isConnected ? returnFocus : workspace).focus();
}

function subscribe(plan) {
  showDialog('subscribe', 'Subscribe to ' + plan.name,
    `<p>${pricePerMonth(plan)}, starting today.</p>
    <ul><li>Apple Pay <span class="detail">(in Safari, with Touch ID or your iPhone)</span></li>
    <li>Link</li><li>Credit or debit card</li></ul>
    <p>Live checkout opens on Stripe’s secure page in your browser. This preview simulates it here and collects no card details.</p>`,
    button('dismiss', 'Cancel') + button('start-checkout', 'Continue to checkout', 'primary', plan.id));
}

function waitForCheckout() {
  showDialog('waiting', 'Finish paying in your browser',
    '<p>Use the simulated checkout to see the result here.</p>',
    button('cancel-checkout', 'Cancel') + button('browser', 'Open checkout again', 'primary'));
}

function paymentChoices(selected) {
  return `<fieldset><legend>Payment method</legend>${Object.entries(methodNames).map(([method, name]) =>
    `<label class="choice"><input name="method" type="radio" value="${method}"${method === selected ? ' checked' : ''}> ${name}</label>`).join('')}</fieldset>`;
}

function simulatedCheckout(snapshot, failed = false) {
  const plan = planFor(snapshot, snapshot.checkout.planId);
  showDialog('browser', 'Simulated Stripe Checkout',
    `<p>${plan.name} · ${pricePerMonth(plan)}. Choose a sample method. No payment details are collected.</p>
    ${failed ? '<p class="banner" role="alert">Payment declined in this simulation. Try again or return to Leverage.</p>' : ''}
    ${paymentChoices('card')}`,
    button('waiting', 'Return to Leverage') + button('decline-checkout', 'Simulate decline') + button('pay', 'Simulate payment', 'primary'));
}

function resetPreview() {
  billing.reset();
  if (dialog.open) closeDialog();
  navigate('subscription');
  announcement.textContent = 'Preview reset.';
}

function changeConfirmation(snapshot, plan) {
  const renewal = snapshot.paymentDue ? 'At renewal' : 'At renewal · ' + date(snapshot.nextPaymentOn);
  showDialog('pick-change', 'Change to ' + plan.name,
    `<p>New monthly price ${price(plan.amountCents)}. Try either timing. Live billing and proration rules are pending.</p>
    <fieldset><legend>When to apply this example</legend>
    <label class="choice"><input type="radio" name="timing" value="immediate" checked> Immediately</label>
    <label class="choice"><input type="radio" name="timing" value="renewal"> ${renewal}</label></fieldset>`,
    button('dismiss', 'Cancel') + button('apply-change', 'Apply in preview', 'primary', plan.id));
}

function selected(name) {
  return dialogContent.querySelector('input[name="' + name + '"]:checked').value;
}

function cancelCheckout() {
  billing.cancelCheckout(billing.getSnapshot().checkout.id);
  closeDialog();
  announcement.textContent = 'Checkout cancelled.';
}

function setAppearance(theme) {
  appearance.value = theme;
  document.body.dataset.theme = theme;
}

function handleAction(action, value) {
  const snapshot = billing.getSnapshot();
  switch (action) {
    case 'menu': setMenu(accountMenu.hidden); break;
    case 'board': case 'needs': case 'subscription': case 'change': navigate(action); break;
    case 'reset': case 'confirm-signout': resetPreview(); break;
    case 'settings':
      showDialog('settings', 'Settings',
        `<div class="form-field"><label for="mock-appearance">Appearance</label>
        <select id="mock-appearance">${appearance.innerHTML}</select></div>`, button('dismiss', 'Done'));
      dialogContent.querySelector('select').value = appearance.value;
      break;
    case 'signout':
      showDialog('signout', 'Sign out of the preview?',
        '<p>This clears the sample subscription session.</p>',
        button('dismiss', 'Cancel') + button('confirm-signout', 'Sign out', 'primary'));
      break;
    case 'choose': subscribe(planFor(snapshot, value)); break;
    case 'pick-change': changeConfirmation(snapshot, planFor(snapshot, value)); break;
    case 'dismiss': closeDialog(); break;
    case 'start-checkout': billing.startCheckout(value); waitForCheckout(); break;
    case 'waiting': waitForCheckout(); break;
    case 'cancel-checkout': cancelCheckout(); break;
    case 'browser': simulatedCheckout(snapshot); break;
    case 'decline-checkout': simulatedCheckout(snapshot, true); break;
    case 'pay': {
      const paid = billing.finishCheckout(snapshot.checkout.id, selected('method'));
      const plan = planFor(paid, paid.planId);
      render();
      showDialog('subscribed', 'You’re on ' + plan.name,
        `<p>Next payment ${price(plan.amountCents)} on ${date(paid.nextPaymentOn)}.</p>`,
        button('dismiss', 'Done', 'primary'));
      break;
    }
    case 'fail':
      billing.failRenewal(); render(); workspace.focus();
      announcement.textContent = 'Payment due. One new item in Needs you.';
      break;
    case 'update':
      showDialog('update', 'Simulated Stripe payment update',
        '<p>Choose a sample method. A failed renewal clears when the payment succeeds.</p>' +
        paymentChoices(snapshot.paymentMethod.kind),
        button('dismiss', 'Cancel') + button('save-method', 'Save in preview', 'primary'));
      break;
    case 'save-method':
      billing.updatePaymentMethod(selected('method')); render(); closeDialog();
      announcement.textContent = 'Sample payment method updated.';
      break;
    case 'recover':
      billing.recoverPayment(); render(); workspace.focus();
      announcement.textContent = 'Payment received. The subscription item cleared.';
      break;
    case 'receipt': {
      const receipt = snapshot.receipts.find(receipt => receipt.id === value);
      showDialog('receipt', 'Sample Stripe receipt',
        `<p>${price(receipt.amountCents)} · ${planFor(snapshot, receipt.planId).name} · Paid ${date(receipt.paidOn)}</p>`,
        button('dismiss', 'Done', 'primary'));
      break;
    }
    case 'apply-change':
      billing.changePlan(value, selected('timing')); render(); closeDialog(); navigate('subscription');
      announcement.textContent = 'Sample plan change saved.';
      break;
    case 'cancel-subscription':
      showDialog('cancel-subscription', 'Cancel subscription?',
        `<p>Your subscription ends on ${date(snapshot.periodEnd)}. No further payment will be taken. Your tasks, rules and history stay on this Mac.</p>`,
        button('dismiss', 'Keep subscription') + button('confirm-cancel', 'Cancel subscription', 'danger'));
      break;
    case 'confirm-cancel':
      billing.cancelSubscription(); render(); closeDialog();
      announcement.textContent = 'Subscription cancellation scheduled in the preview.';
      break;
  }
}

document.addEventListener('click', event => {
  const target = event.target.closest('button[data-action]');
  if (target?.dataset.action !== 'menu' && !accountMenu.hidden) {
    setMenu(false);
    if (target && accountMenu.contains(target)) accountButton.focus();
  }
  if (target) handleAction(target.dataset.action, target.dataset.value);
});

document.addEventListener('change', event => {
  if (event.target === appearance || event.target.id === 'mock-appearance') setAppearance(event.target.value);
});

document.addEventListener('keydown', event => {
  if (event.key === 'Escape' && !accountMenu.hidden) {
    setMenu(false);
    accountButton.focus();
  }
});

dialog.addEventListener('cancel', event => {
  event.preventDefault();
  if (dialogStage === 'browser') waitForCheckout();
  else if (dialogStage === 'waiting') cancelCheckout();
  else closeDialog();
});

render();
