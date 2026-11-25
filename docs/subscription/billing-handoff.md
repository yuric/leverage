# Subscription billing handoff

This handoff describes the work needed to take Leverage from the offline
Subscription preview to Stripe sandbox and then live billing.

## Before integrating Stripe

The preview uses sample data and can be reviewed without Stripe. The Stripe
integration needs a maintainer-run subscription service, an authenticated
owner binding, and a webhook receiver. Record how the Mac app reaches the
service in an ADR before building FR-007 through FR-020, as required by
FR-024. Declare the external service and any SDK in the
integration PR under AR-004, including applicable terms or license, pinned API,
webhook and SDK versions, and justification.
[Subscription PRD](../PRD.md#subscription),
[architecture rules](../ARCHITECTURE.md#rules).

## Configure the Stripe environments

- Choose one Stripe account for each deployment environment, or use a Stripe
  sandbox and live mode within one account. Keep keys, webhook destinations,
  signing secrets, Customers, Products, Prices, portal configurations and
  service data separate by environment. Use a restricted API key with the
  permissions the service needs, or the appropriate server-side secret key if
  restricted permissions cannot cover those operations. Keep the API key and
  each endpoint's signing secret in the hosted service's secret store.
  [Stripe API keys](https://docs.stripe.com/keys#sandbox-versus-live-mode),
  [Stripe webhooks](https://docs.stripe.com/webhooks).
- Create a separate recurring Price in each environment for each plan of
  FR-007, at the price, currency and interval FR-007 gives. Configure the
  service to map stable plan keys to those Price IDs. Set up Checkout for cards, Link and Apple Pay and
  enable payment-method updates in the customer portal. Configure receipt
  delivery and trusted, fixed HTTPS URLs for Checkout success and cancel and
  for the portal return. Verify the environment, account, Price amounts,
  currency and intervals, portal and payment-method settings, and browser
  return URLs before enabling billing. Register a publicly reachable HTTPS
  webhook endpoint, configure its event subscriptions, and confirm signed
  delivery in Stripe. [Checkout Sessions](https://docs.stripe.com/api/checkout/sessions/create),
  [portal configuration](https://docs.stripe.com/customer-management/configure-portal),
  [Stripe receipts](https://docs.stripe.com/receipts).
- Checkout opens as FR-009 says, and Stripe collects all payment details.
  Include Safari on a Mac with compatible Touch ID or an iPhone in the test
  matrix. Confirm, as the PRD's open decision on Stripe's details asks, that
  hosted Checkout needs no merchant domain registration for Apple Pay.
  [Stripe Apple Pay](https://docs.stripe.com/apple-pay?platform=web),
  [wallet product support](https://docs.stripe.com/payments/wallets#product-support).

### Configuration to collect

| Service setting | Stripe or deployment source |
| --- | --- |
| Stripe API key | Secret store entry for the selected Stripe environment |
| Webhook signing secret | Secret store entry for that environment's Stripe webhook destination |
| The Price ID of each plan of FR-007 | One recurring Price per plan from that environment |
| Payment methods | Stripe Checkout and portal configuration for the selected environment |
| Portal configuration ID, if overriding the default | That environment's Customer Portal configuration |
| Service base URL and return URLs | Approved HTTPS host, with fixed paths for browser return and signed webhooks |

Cards, Link and Apple Pay use the Stripe environment and its payment-method
settings. They do not need separate Leverage credentials. Keep the preview
available as a separate mode so adding server secrets cannot turn a simulated
flow into a live payment.

## Implement the billing flow

- Bind the owner to the service-issued owner ID and to the Stripe Customer for
  that environment. The service verifies that binding and authorizes every
  billing operation. FR-022 says what identifies the owner to the service and
  what Stripe receives. For plan selection, the Mac app supplies a stable plan
  key and authenticated owner context. The service resolves the Price and
  controls session creation. Besides the secret key of FR-021, signing
  secrets and Stripe client secrets also stay off the Mac. Email alone is
  insufficient for authentication.
- Today the owner's sign-in is checked only by the server on the owner's own
  Mac, and nothing verifies the sign-in email, so neither proves anything to
  the service. The ADR of FR-024 settles what the Mac app presents to the
  service, where that is kept on the Mac, how the binding is recovered on
  another Mac or revoked, and whether the email is proven before it is bound
  to a Customer.
- Serialize Checkout creation for the owner, deduplicate repeated requests and
  use Stripe idempotency keys for writes. Reopen the same pending Checkout
  session. Expire open sessions on Cancel and reconcile a completion that wins
  the race with expiration. Verify that duplicate or concurrent attempts
  cannot create a second subscription. [Expire a Checkout Session](https://docs.stripe.com/api/checkout/sessions/expire).
- Use provider responses and browser URLs to open Stripe pages. The app reads
  subscription state from the service and refreshes while Checkout is pending
  and after browser return. Base paid state and any future access decision on
  service reconciliation after a signed Stripe event. Verify the webhook's
  signature over the raw request body, match the environment and owner binding,
  deduplicate event IDs and make updates idempotent. Handle retries and
  out-of-order delivery by reconciling current Stripe objects for the related
  Customer, subscription and invoice. Cover Checkout completion and expiration,
  subscription updates and end, invoice payment and failure, and changes to the
  effective payment method. [Checkout fulfillment](https://docs.stripe.com/checkout/fulfillment),
  [subscription webhooks](https://docs.stripe.com/billing/subscriptions/webhooks),
  [Stripe webhooks](https://docs.stripe.com/webhooks).
- Return what the Subscription page of FR-012 shows. Update, View and the
  Needs you button open the Stripe pages of FR-013 and FR-018 for the bound
  Customer. Verify which methods actually appear in the portal update flow.
  If that flow falls short of FR-013, research Stripe-hosted Checkout setup
  mode and confirm wallet availability before proposing it. A portal update
  may change only the customer default. Check that recovery uses the effective
  subscription payment method and that the failed invoice is paid before
  undoing the three changes of FR-017.
  [Portal deep links](https://docs.stripe.com/customer-management/portal-deep-links),
  [Checkout setup mode](https://docs.stripe.com/payments/checkout/save-and-reuse?payment-ui=stripe-hosted),
  [payment retry behavior](https://docs.stripe.com/billing/revenue-recovery/smart-retries#payment-method-ordering).
- Change the existing subscription using the owner's decision on timing and
  proration. Cancel as FR-015 says, by scheduling the end at the paid period
  in Stripe. A failed payment stays within FR-020. Wire the single Needs you
  item and macOS notification as called for by FR-018.
- Keep the service's data limited to billing and owner binding. Keep
  subscription state on the Mac as FR-023 says, holding only the payment
  summary of FR-016. Keep card numbers, CVC, secrets and customer data out of the
  repository, operational logs and Leverage event log. Keep raw webhook bodies,
  receipt URLs and hosted session URLs out of logs.

## Owner decisions and sandbox acceptance

The owner settles plan inclusions, subscriber support, use without a
subscription, the failed-payment deadline and what happens after it, and the
timing and price handling of mid-month changes. The owner also settles the
service host, privacy notice and sales tax. The preview marks plan inclusions
as pending and uses sample dates and billing states. Set live copy, retry and
plan-change settings, and any access policy only after the owner decides them.
[PRD open decisions](../PRD.md#open-decisions).

Before enabling live billing, run the PRD's acceptance checks in Stripe
sandbox. Pay for Plus in the browser and verify the app updates without a
restart. Test cards, Link and eligible Apple Pay for initial Checkout and test
each in Update, including whether it can pay a failed renewal. Check receipt
links, renewal failure and recovery, one Needs you item, and an in-progress run
that continues. Exercise cancellation during Checkout, duplicate Checkout
attempts, plan changes, cancellation at the paid-period end, missing or forged
webhooks, and duplicate and out-of-order deliveries. Verify that an owner
cannot read or change another owner's subscription, and inspect the repository,
operational logs and event log for customer data, card data and secrets. Repeat
configuration and reachability checks against the separate live environment
before turning it on.
[PRD acceptance criteria](../PRD.md#acceptance-criteria-for-subscription),
[Stripe sandbox testing](https://docs.stripe.com/billing/testing).
