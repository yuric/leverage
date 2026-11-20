# 0006. Owner sign-in and tokens

Status: Accepted

## Context

The Core loop milestone is the first code that crosses the line between the
Mac and the server, and three kinds of caller reach the server: the owner
through the Mac app, the helper, and each seat. The contract
([ADR 0003](0003-contract-format.md)) gave each a bearer scheme and stores
each token only as a hash, and the PRD requires every seat token to be
revocable. It does not say how the owner's password is kept, how a token is
made, how the first owner comes to exist, or what transport the API uses on
the Mac. Changing any of these later means changing every stored row and
every client, so they are recorded here (rule AR-003).

## Decision

1. **Passwords with `bcrypt`.** The owner's password is kept as
   `users.password_digest` through Rails' `has_secure_password`, which needs
   the `bcrypt` gem, pinned to 3.1.22 (MIT) in `api/Gemfile`. A new
   password has at least 8 characters. The password is checked in the
   controller with `User.authenticate_by`, before the command runs, and is
   left out of the request hash the command stores.
2. **Opaque tokens, stored hashed.** A token is a prefix that names its kind
   (`lvs_` a seat, `lvh_` the helper, `lvo_` an owner session) followed by
   32 random bytes in URL-safe base64 (`Leverage::Tokens`). The server keeps
   only the SHA-256 hex digest in `token_hash` and finds the caller by it.
   The prefix lets the Mac side's redaction and the secret scan recognise a
   token anywhere. A token appears only in the response that issues it; a
   repeat of the same idempotency key answers the contract's `*Repeated`
   form, without the token.
3. **What ends a token.** An owner session lasts until sign-out, which
   deletes its row; it has no expiry in version 1. The helper's token ends
   when the next one is issued, which the app does each time it starts the
   helper. A seat's token ends when the next one is issued for it, when its
   run is reported stopped, and when the seat is removed. So Stop ends the
   token of a seat the app runs, and Remove ends any seat's.
4. **The setup call.** `GET /v1/owner/setup` says whether an owner exists.
   `POST /v1/owner/setup` creates the workspace, the one owner and a session
   in one transaction under a PostgreSQL advisory lock on a fixed key, and
   answers `404` to a new key once any owner exists. Until then it is open
   to any caller that can reach the API, which listens on the Mac's loopback
   address only.
5. **Plain HTTP on loopback.** `compose.yaml` publishes the API on
   `127.0.0.1` only, and the Mac side calls it over plain HTTP. HTTPS is
   required before the server leaves the Mac; `Configuration` already
   accepts an `https` address.
6. **Where each token lives on the Mac.** The owner's session token is kept
   in the owner's login Keychain (`KeychainSessionStore`). The helper's
   token and a seat's token are only ever in the environment of the process
   that uses them, never in a file, a log, an argument or the Keychain.

## Alternatives considered

- **Signed tokens (JWT).** They cannot be ended one by one without a
  revocation list, which is the stored row this design already has.
- **A setup command in a terminal** for the first owner. It breaks the
  milestone's "without a terminal".
- **HTTPS on the Mac** with a local certificate. It adds a certificate to
  make, trust and renew, for a server only the Mac itself can reach.

## Consequences

- No forgotten-password path exists in version 1: an owner who loses the
  password cannot sign in again without access to the database.
- Anyone who can reach the Mac's loopback address before the owner has
  created the sign-in could create it first; the window is from the first
  start of the server to the owner's setup.
- Before the server leaves the Mac, the transport must change to HTTPS,
  and that change supersedes point 5.
