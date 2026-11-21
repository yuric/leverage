# 0017. API tokens, the Keychain and the local channel

Status: Accepted

## Context

The owner can add API tokens and check them with their providers. The
server manages credential records and the handoff order. The helper is
the component that can authenticate to a provider (CR-7, CR-9, CR-31,
TK-1, TK-2).

## Decision

The app sends a pasted value on the current helper's standard input.
The helper holds the value in memory for at most 60 seconds pending
Add. The server receives the same fixed mask for every token. After a
successful check, the bundled helper stores a generic password with
service `leverage API token` and the credential ID as account. The
file-based Security API uses the user's default Keychain for insertion
and search list for lookups. The standard setup uses the login Keychain.
The helper uses the in-memory vault for development, Linux and smoke.

Remove follows the completed server command with a local forget
message. The helper cancels work for that ID, deletes the matching
Keychain item and removes a settings folder when the helper can prove
ownership. See [Deployment](../DEPLOY.md#where-things-live) for upgrade
and interrupted cleanup behavior.

`ProviderCatalog` prescribes one GET per service for checking a token
or reading usage. The services are hosted APIs. Their versions are
the paths and explicit headers in the table.

| Service | HTTPS host and path | Auth header | Version |
| --- | --- | --- | --- |
| OpenRouter | `openrouter.ai/api/v1/key` | Bearer authorization | `/api/v1` |
| Anthropic | `api.anthropic.com/v1/models` | Bearer authorization | `/v1`, `anthropic-version: 2026-10-21` |
| OpenAI | `api.openai.com/v1/models` | Bearer authorization | `/v1` |
| Google Gemini | `generativelanguage.googleapis.com/v1beta/models` | `x-goog-api-key` | `/v1beta` |
| xAI | `api.x.ai/v1/api-key` | Bearer authorization | `/v1` |

## Alternatives considered

- Put a token into Add or a helper request over HTTP. That would give
  the server the provider secret.
- Write a local secret file or pass the token as an argument. A local
  process channel and the platform vault keep the value out of both.
- Retain token characters for identification. The name distinguishes
  rows, and the fixed mask carries no token characters.
- Add a server request for local cleanup. The same local channel can
  carry forget without storing local secret information on the server.

## Consequences

The app's ad-hoc signature can prompt for approval after a rebuild.
Actual Keychain operations await the owner's first test with a real
token. Token checks and usage use made-up replies in automated tests.
Tokens take a place in the order and work continues on logins.
