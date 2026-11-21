# 0014. The MCP server is a Swift program over standard input and output

Status: Accepted

## Context

The PRD's Clients section calls for the whole agent interface to be
available through MCP to an agent that connects on the same machine.
The contract already defines each operation, request schema, and role.
The choice fixes a transport, a process boundary, and how the server
keeps a lease alive between client calls (AM-1 to AM-5, AM-10).

## Decision

- Bundle `LeverageMCP` as a Swift executable that the MCP client starts
  for its seat. Use newline-delimited JSON-RPC on standard input and
  output. The server negotiates revisions 2025-11-25, 2025-06-18,
  2025-03-26 and 2024-11-05, with 2025-06-18 as its fallback.
- Reuse LeverageKit for HTTP, retry keys, configuration and diagnostic
  logging. Generate the tools and role lists from the existing HTTP
  contract. A supplied role filters listing and dispatch. An invalid
  role prevents startup. Omitting it exposes all agent tools for
  discovery, with the API enforcing the token's actual role.
- Take the seat token from the environment supplied by the client. Keep
  protocol traffic on standard output and diagnostics on standard error.
  The API remains the source of truth for the caller, work and events.
- Serialize tool calls and heartbeats. The server renews a tracked task
  or review lease every 60 seconds while the last tool call is less than
  10 minutes old. A criterion pass announces its start first if needed.
  The action completion tool requires a start the session observed or
  learned from the briefing.

## Alternatives considered

- A network MCP service adds a listening port and a new authentication
  boundary for a client on the same machine.
- An MCP SDK or a second language runtime adds a direct dependency and
  duplicates the HTTP and configuration code already in LeverageKit.
- Requiring the client to heartbeat leaves a stock client responsible
  for scheduling work between tool calls. Unbounded automatic heartbeats
  would retain a lease after the client stopped using the tools.

## Consequences

- The client settings contain the executable path, the API address and
  a way to pass the seat token into the process. Keep any settings file
  containing the token private.
- An external agent can act outside the MCP tools. Refusing an action
  completion with no start cannot prevent an act already performed.
- The protocol runs over pipes in tests. The developer check used
  Claude Code 2.1.325 at revision 2025-11-25 with a stand-in reviewer.
  The other named clients and the owner's own run remain unverified.
