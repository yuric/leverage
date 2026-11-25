# Leverage

Leverage is a Mac app for coordinating AI agents from multiple providers
without opening a terminal. Connect provider accounts and add a task in a
form. Leverage is built to keep work moving when a provider hits a limit or
a login expires; so far that has been shown only with stand-in tools, not
on a real provider
([how far it is proven](docs/IMPLEMENTATION.md#what-the-handoff-milestone-proves-and-how-far)).

> **Status: in development.** See
> [Implementation progress](docs/IMPLEMENTATION.md) for the milestones
> and what each check proved.

Leverage is an open source project that is being specified in the open. The
requirements are written first, in [docs/PRD.md](docs/PRD.md); architecture,
deployment, and implementation follow from them.

## What is here

| File | Purpose |
|------|---------|
| [docs/PRD.md](docs/PRD.md) | Product requirements. The source of truth for what gets built. |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | The architecture rules every pull request answers, and the system design, filled in as requirements settle. |
| [docs/DEPLOY.md](docs/DEPLOY.md) | How to run and operate Leverage on the owner's Mac. |
| [docs/IMPLEMENTATION.md](docs/IMPLEMENTATION.md) | Where the build stands, milestone by milestone. |
| `docs/adr/` | Architecture decision records, listed in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#architecture-decision-records). |
| `api/` | The server: a Rails application in API mode, run with PostgreSQL in Docker containers (`compose.yaml`, `.env.example`). |
| `mac/` | A Swift package with the Mac app, helper, reference runner, MCP server and shared library. |
| [`marketing-page/`](marketing-page/) | Age of Lever, the public-facing site for Leverage. |
| [docs/design/](docs/design/README.md) | The design reference: a working mockup of the owner-facing screens. |
| [AGENTS.md](AGENTS.md) | Instructions for AI coding agents working in this repository. |
| [CONTRIBUTING.md](CONTRIBUTING.md) | How to propose changes, including the rules for AI-assisted contributions. |
| [MAINTENANCE.md](MAINTENANCE.md) | What to expect from the maintainer, and what is in and out of scope. |
| [SECURITY.md](SECURITY.md) | How to report a vulnerability. |
| [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) | Expected behavior in project spaces. |
| [CHANGELOG.md](CHANGELOG.md) | Notable changes, release by release. |
| [docs/research/](docs/research/open-source-practices/README.md) | Research behind the project's repository practices: advice versus what young popular repositories do. |
| [docs/research/prd-review/](docs/research/prd-review/README.md) | The adversarial review of the PRD: 89 findings for the owner to accept or reject. |

## Preview the marketing page locally

From the repository root, serve the static files:

```bash
python3 -m http.server 8765 --bind 127.0.0.1 --directory marketing-page
```

Open <http://127.0.0.1:8765/>. Run the workflow demo tests with
`node --test scripts/test_marketing_demo.mjs`.

## Getting involved

The most useful contribution right now is feedback on the requirements:

- **Discuss a requirement** by opening an
  [issue](https://github.com/yuric/leverage/issues).
- **Propose a change** with a pull request against
  [docs/PRD.md](docs/PRD.md). Pull requests are welcome at any time; you do
  not need to open an issue first.

Read [CONTRIBUTING.md](CONTRIBUTING.md) before you start, and
[MAINTENANCE.md](MAINTENANCE.md) to know what to expect: Leverage has one
maintainer, and responses are best effort.

## How it is built

Leverage is developed largely with AI coding agents, directed and reviewed by
the maintainer. Every change to `main` goes through a pull request and
automated checks. Contributors may use AI tools too, under the
[same rules](CONTRIBUTING.md#ai-assisted-contributions).

## Attribution

Leverage is created and maintained by Yuri ([@yuric](https://github.com/yuric))
and its contributors, listed in [AUTHORS](AUTHORS).

Codex, Grok, Claude, Gemini and the other provider names in this
repository belong to their respective owners. Leverage is an independent
project and is not affiliated with or endorsed by them.

## License

[MIT](LICENSE) © 2026 Leverage contributors.
