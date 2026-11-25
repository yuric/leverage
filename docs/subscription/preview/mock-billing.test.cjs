const assert = require('node:assert/strict');
const test = require('node:test');
const { createMockBilling } = require('./mock-billing.js');

function subscribe(billing, planId = 'plus', method = 'card') {
  const checkout = billing.startCheckout(planId);
  return billing.finishCheckout(checkout.id, method);
}

test('activates each plan at its listed price and saves only the method summary', () => {
  const plans = [
    { id: 'pro', name: 'Pro', amountCents: 10000 },
    { id: 'starter', name: 'Starter', amountCents: 700 },
    { id: 'plus', name: 'Plus', amountCents: 2000 },
  ];
  const methods = [
    { kind: 'apple_pay' },
    { kind: 'link' },
    { kind: 'card', brand: 'Visa', last4: '0123', expiresMonth: 1, expiresYear: 2029 },
  ];

  assert.deepEqual(createMockBilling().getSnapshot(), {
    plans,
    status: 'none',
    planId: null,
    checkout: null,
    paymentMethod: null,
    nextPaymentOn: null,
    periodEnd: null,
    cancelOn: null,
    scheduledPlanId: null,
    paymentDue: null,
    receipts: [],
  });
  for (const [index, plan] of plans.entries()) {
    const billing = createMockBilling();
    const method = methods[index];
    const state = subscribe(billing, plan.id, method.kind);
    assert.equal(state.status, 'active');
    assert.equal(state.planId, plan.id);
    assert.equal(state.checkout, null);
    assert.deepEqual(state.paymentMethod, method);
    assert.equal(state.nextPaymentOn, '2027-02-15');
    assert.equal(state.periodEnd, state.nextPaymentOn);
    assert.deepEqual(state.receipts, [
      { id: state.receipts[0].id, amountCents: plan.amountCents, paidOn: '2027-01-15', planId: plan.id },
    ]);
  }
});

test('reuses one pending checkout and completes a checkout only once', () => {
  const billing = createMockBilling();
  const pending = billing.startCheckout('starter');
  const repeated = billing.startCheckout('starter');
  assert.deepEqual(repeated, pending);
  assert.notEqual(repeated, pending);
  assert.throws(() => billing.startCheckout('pro'));
  assert.equal(billing.getSnapshot().status, 'none');
  assert.deepEqual(billing.getSnapshot().receipts, []);
  const activated = billing.finishCheckout(pending.id, 'link');
  const repeatedConfirmation = billing.finishCheckout(pending.id, 'card');
  assert.deepEqual(repeatedConfirmation, activated);
  assert.notEqual(repeatedConfirmation, activated);
  assert.throws(() => billing.startCheckout('starter'));
});

test('abandoning checkout leaves the original subscription state and permits retry', () => {
  const billing = createMockBilling();
  const initial = billing.getSnapshot();
  const first = billing.startCheckout('starter');
  assert.deepEqual(billing.cancelCheckout(first.id), initial);
  const second = billing.startCheckout('starter');
  assert.notEqual(second.id, first.id);
  assert.throws(() => billing.finishCheckout(first.id, 'card'));
  assert.throws(() => billing.cancelCheckout(first.id));
  assert.deepEqual(billing.getSnapshot().checkout, second);
  assert.equal(billing.finishCheckout(second.id, 'card').status, 'active');
});

test('a failed payment appears once and a successful retry records one receipt', () => {
  const billing = createMockBilling();
  const active = subscribe(billing);
  const due = billing.failRenewal();
  assert.equal(due.status, 'payment_due');
  assert.deepEqual(due.paymentDue, {
    amountCents: 2000, failedOn: '2027-02-15', graceUntil: '2027-02-22', planId: 'plus',
  });
  assert.deepEqual(due.receipts, active.receipts);
  assert.equal(due.nextPaymentOn, active.nextPaymentOn);
  assert.deepEqual(billing.failRenewal(), due);
  const updated = billing.updatePaymentMethod('apple_pay');
  assert.deepEqual(updated.paymentMethod, { kind: 'apple_pay' });
  assert.deepEqual(updated.paymentDue, due.paymentDue);

  const recovered = billing.recoverPayment();
  assert.equal(recovered.status, 'active');
  assert.equal(recovered.paymentDue, null);
  assert.equal(recovered.nextPaymentOn, '2027-03-15');
  assert.equal(recovered.periodEnd, recovered.nextPaymentOn);
  assert.deepEqual(recovered.receipts, [
    { id: recovered.receipts[0].id, amountCents: 2000, paidOn: '2027-02-15', planId: 'plus' },
    ...active.receipts,
  ]);
  assert.deepEqual(billing.recoverPayment(), recovered);
  assert.equal(billing.failRenewal().paymentDue.graceUntil, '2027-03-22');
  assert.equal(billing.recoverPayment().nextPaymentOn, '2027-04-15');
});

test('applies immediate changes without a receipt and replaces a scheduled change', () => {
  const billing = createMockBilling();
  const active = subscribe(billing);
  billing.changePlan('pro', 'renewal');
  const changed = billing.changePlan('starter', 'immediate');
  assert.equal(changed.planId, 'starter');
  assert.equal(changed.scheduledPlanId, null);
  assert.equal(changed.nextPaymentOn, active.nextPaymentOn);
  assert.deepEqual(changed.receipts, active.receipts);

  billing.changePlan('pro', 'renewal');
  const scheduled = billing.changePlan('plus', 'renewal');
  assert.equal(scheduled.planId, 'starter');
  assert.equal(scheduled.scheduledPlanId, 'plus');
  const due = billing.failRenewal();
  assert.equal(due.planId, 'starter');
  assert.equal(due.scheduledPlanId, null);
  assert.equal(due.paymentDue.planId, 'plus');
  assert.equal(due.paymentDue.amountCents, 2000);
  const recovered = billing.recoverPayment();
  assert.equal(recovered.planId, 'plus');
  assert.equal(recovered.scheduledPlanId, null);
  assert.equal(recovered.receipts[0].planId, 'plus');
  assert.equal(recovered.receipts[0].amountCents, 2000);
});

test('cancels at the end of the paid period and clears the scheduled change', () => {
  const billing = createMockBilling();
  const active = subscribe(billing);
  billing.changePlan('pro', 'renewal');
  const cancelled = billing.cancelSubscription();
  assert.equal(cancelled.status, 'cancel_at_period_end');
  assert.equal(cancelled.planId, active.planId);
  assert.equal(cancelled.cancelOn, active.periodEnd);
  assert.equal(cancelled.periodEnd, active.periodEnd);
  assert.equal(cancelled.nextPaymentOn, null);
  assert.equal(cancelled.scheduledPlanId, null);
  assert.deepEqual(cancelled.receipts, active.receipts);
  assert.deepEqual(billing.cancelSubscription(), cancelled);
  assert.throws(() => billing.changePlan('pro', 'immediate'));
  assert.throws(() => billing.failRenewal());
});

test('cancels while a payment is due and takes no further payment', () => {
  const billing = createMockBilling();
  const active = subscribe(billing);
  billing.changePlan('pro', 'renewal');
  const due = billing.failRenewal();
  const cancelled = billing.cancelSubscription();
  assert.equal(cancelled.status, 'cancel_at_period_end');
  assert.equal(cancelled.paymentDue, null);
  assert.equal(cancelled.cancelOn, due.periodEnd);
  assert.equal(cancelled.nextPaymentOn, null);
  assert.equal(cancelled.scheduledPlanId, null);
  assert.deepEqual(cancelled.receipts, active.receipts);
  assert.deepEqual(billing.recoverPayment(), cancelled);
  assert.deepEqual(billing.cancelSubscription(), cancelled);
});

test('changes plan while a payment is due and bills the new plan on retry', () => {
  const billing = createMockBilling();
  subscribe(billing, 'plus');
  billing.failRenewal();
  const changed = billing.changePlan('pro', 'immediate');
  assert.equal(changed.status, 'payment_due');
  assert.equal(changed.planId, 'pro');
  assert.equal(changed.paymentDue.planId, 'pro');
  assert.equal(changed.paymentDue.amountCents, 10000);
  const recovered = billing.recoverPayment();
  assert.equal(recovered.planId, 'pro');
  assert.equal(recovered.receipts[0].planId, 'pro');
  assert.equal(recovered.receipts[0].amountCents, 10000);

  billing.failRenewal();
  const scheduled = billing.changePlan('starter', 'renewal');
  assert.equal(scheduled.status, 'payment_due');
  assert.equal(scheduled.scheduledPlanId, 'starter');
  assert.equal(scheduled.paymentDue.planId, 'pro');
  const retried = billing.recoverPayment();
  assert.equal(retried.planId, 'pro');
  assert.equal(retried.receipts[0].planId, 'pro');
  assert.equal(retried.scheduledPlanId, 'starter');
});

test('snapshots, independent instances, and reset keep state isolated', () => {
  const billing = createMockBilling();
  const initial = createMockBilling().getSnapshot();
  const session = billing.startCheckout('pro');
  session.planId = 'starter';
  const pending = billing.getSnapshot();
  pending.checkout.planId = 'starter';
  assert.equal(billing.getSnapshot().checkout.planId, 'pro');
  const active = billing.finishCheckout(session.id, 'card');
  active.plans[0].amountCents = 0;
  active.paymentMethod.kind = 'link';
  active.receipts[0].amountCents = 0;
  const due = billing.failRenewal();
  assert.equal(due.paymentMethod.kind, 'card');
  assert.equal(due.receipts[0].amountCents, 10000);
  assert.equal(due.paymentDue.amountCents, 10000);
  due.paymentDue.planId = 'plus';
  assert.equal(billing.getSnapshot().paymentDue.planId, 'pro');
  assert.deepEqual(createMockBilling().getSnapshot(), initial);
  assert.deepEqual(billing.reset(), initial);

  const newSession = billing.startCheckout('pro');
  assert.notEqual(newSession.id, session.id);
  assert.throws(() => billing.finishCheckout(session.id, 'card'));
  assert.doesNotThrow(() => billing.finishCheckout(newSession.id, 'card'));
});

test('invalid inputs leave the current snapshot intact', () => {
  const billing = createMockBilling();
  assert.throws(() => billing.startCheckout('unknown'));
  assert.throws(() => billing.updatePaymentMethod('link'));
  assert.throws(() => billing.changePlan('plus', 'immediate'));

  const session = billing.startCheckout('plus');
  const pending = billing.getSnapshot();
  assert.throws(() => billing.finishCheckout(session.id, 'unknown'));
  assert.deepEqual(billing.getSnapshot(), pending);

  const active = billing.finishCheckout(session.id, 'link');
  assert.throws(() => billing.changePlan('pro', 'unknown'));
  assert.throws(() => billing.changePlan('unknown', 'renewal'));
  assert.throws(() => billing.updatePaymentMethod('constructor'));
  assert.deepEqual(billing.getSnapshot(), active);
});
