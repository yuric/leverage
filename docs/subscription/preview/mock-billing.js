function createMockBilling() {
  const plans = [
    { id: 'pro', name: 'Pro', amountCents: 10000 },
    { id: 'starter', name: 'Starter', amountCents: 700 },
    { id: 'plus', name: 'Plus', amountCents: 2000 },
  ];
  const paymentMethods = new Map([
    ['apple_pay', { kind: 'apple_pay' }],
    ['link', { kind: 'link' }],
    ['card', { kind: 'card', brand: 'Visa', last4: '0123', expiresMonth: 1, expiresYear: 2029 }],
  ]);
  const firstPaymentOn = '2027-01-15';
  let checkoutCount = 0;
  let completedCheckoutId = null;
  let state;

  function getSnapshot() {
    return {
      ...state,
      plans: plans.map(plan => ({ ...plan })),
      checkout: state.checkout && { ...state.checkout },
      paymentMethod: state.paymentMethod && { ...state.paymentMethod },
      paymentDue: state.paymentDue && { ...state.paymentDue },
      receipts: state.receipts.map(receipt => ({ ...receipt })),
    };
  }

  function reset() {
    completedCheckoutId = null;
    state = {
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
    };
    return getSnapshot();
  }

  function getPlan(planId) {
    const plan = plans.find(plan => plan.id === planId);
    if (!plan) throw new Error('Choose a listed plan.');
    return plan;
  }

  function getPaymentMethod(method) {
    const paymentMethod = paymentMethods.get(method);
    if (!paymentMethod) throw new Error('Choose a listed payment method.');
    return paymentMethod;
  }

  function startCheckout(planId) {
    getPlan(planId);
    if (state.status !== 'none') throw new Error('A subscription already exists.');
    if (state.checkout) {
      if (state.checkout.planId !== planId) throw new Error('Finish or cancel the open checkout.');
    } else {
      checkoutCount += 1;
      state.checkout = { id: `checkout-${checkoutCount}`, planId };
    }
    return { ...state.checkout };
  }

  function startPaidPeriod(plan, paidOn) {
    const nextPayment = new Date(`${paidOn}T00:00:00Z`);
    nextPayment.setUTCMonth(nextPayment.getUTCMonth() + 1);
    state.nextPaymentOn = nextPayment.toISOString().slice(0, 10);
    state.periodEnd = state.nextPaymentOn;
    state.planId = plan.id;
    state.status = 'active';
    state.receipts.unshift({
      id: `receipt-${state.receipts.length + 1}`,
      amountCents: plan.amountCents,
      paidOn,
      planId: plan.id,
    });
  }

  function finishCheckout(sessionId, method) {
    if (completedCheckoutId !== null && completedCheckoutId === sessionId) return getSnapshot();
    if (!state.checkout || state.checkout.id !== sessionId) throw new Error('Open checkout first.');
    const plan = getPlan(state.checkout.planId);
    state.paymentMethod = getPaymentMethod(method);
    startPaidPeriod(plan, firstPaymentOn);
    completedCheckoutId = sessionId;
    state.checkout = null;
    return getSnapshot();
  }

  function cancelCheckout(sessionId) {
    if (!state.checkout) return getSnapshot();
    if (state.checkout.id !== sessionId) throw new Error('This checkout is no longer open.');
    state.checkout = null;
    return getSnapshot();
  }

  function failRenewal() {
    if (state.status === 'payment_due') return getSnapshot();
    if (state.status !== 'active') throw new Error('There is no active subscription to renew.');
    const plan = getPlan(state.scheduledPlanId ?? state.planId);
    const failedOn = state.nextPaymentOn;
    const graceUntil = new Date(`${failedOn}T00:00:00Z`);
    graceUntil.setUTCDate(graceUntil.getUTCDate() + 7);
    state.paymentDue = {
      amountCents: plan.amountCents,
      failedOn,
      graceUntil: graceUntil.toISOString().slice(0, 10),
      planId: plan.id,
    };
    state.scheduledPlanId = null;
    state.status = 'payment_due';
    return getSnapshot();
  }

  function updatePaymentMethod(method) {
    if (state.status === 'none') throw new Error('Subscribe before updating your payment method.');
    state.paymentMethod = getPaymentMethod(method);
    return getSnapshot();
  }

  function recoverPayment() {
    if (!state.paymentDue) return getSnapshot();
    const { planId, failedOn } = state.paymentDue;
    startPaidPeriod(getPlan(planId), failedOn);
    state.paymentDue = null;
    return getSnapshot();
  }

  function isManageable() {
    return state.status === 'active' || state.status === 'payment_due';
  }

  function changePlan(planId, timing) {
    if (!isManageable()) throw new Error('A subscription is required to change plans.');
    const plan = getPlan(planId);
    if (timing === 'immediate') {
      state.planId = planId;
      state.scheduledPlanId = null;
      if (state.paymentDue) {
        state.paymentDue.planId = plan.id;
        state.paymentDue.amountCents = plan.amountCents;
      }
    } else if (timing === 'renewal') {
      const current = state.paymentDue?.planId ?? state.planId;
      state.scheduledPlanId = planId === current ? null : planId;
    } else {
      throw new Error('Choose when the plan change takes effect.');
    }
    return getSnapshot();
  }

  function cancelSubscription() {
    if (state.status === 'cancel_at_period_end') return getSnapshot();
    if (!isManageable()) throw new Error('A subscription is required to cancel.');
    state.status = 'cancel_at_period_end';
    state.cancelOn = state.periodEnd;
    state.nextPaymentOn = null;
    state.scheduledPlanId = null;
    state.paymentDue = null;
    return getSnapshot();
  }

  reset();
  return {
    getSnapshot,
    startCheckout,
    finishCheckout,
    cancelCheckout,
    failRenewal,
    updatePaymentMethod,
    recoverPayment,
    changePlan,
    cancelSubscription,
    reset,
  };
}

if (typeof module !== 'undefined') module.exports = { createMockBilling };
