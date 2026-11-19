# leverage

> **Status: definition phase.** There is no product code yet and nothing to install or
> run. This repository currently holds the product requirements document (PRD)
> and the project's ground rules.

leverage is an open source project that is being specified in the open. The
requirements are written first, in [docs/PRD.md](docs/PRD.md); architecture,
deployment, and implementation follow from them.

## What is here

| File | Purpose |
|------|---------|
| [docs/PRD.md](docs/PRD.md) | Product requirements. The source of truth for what gets built. |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | The architecture rules every pull request answers, and the system design, filled in as requirements settle. |
| [docs/DEPLOY.md](docs/DEPLOY.md) | How to deploy and operate. Filled in once there is something to deploy. |
| [AGENTS.md](AGENTS.md) | Instructions for AI coding agents working in this repository. |
| [CONTRIBUTING.md](CONTRIBUTING.md) | How to propose changes, including the rules for AI-assisted contributions. |
| [MAINTENANCE.md](MAINTENANCE.md) | What to expect from the maintainer, and what is in and out of scope. |
| [SECURITY.md](SECURITY.md) | How to report a vulnerability. |
| [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) | Expected behavior in project spaces. |
| [CHANGELOG.md](CHANGELOG.md) | Notable changes, release by release. |
| [docs/research/](docs/research/open-source-practices/README.md) | Research behind the project's repository practices: advice versus what young popular repositories do. |

## Getting involved

The most useful contribution right now is feedback on the requirements:

- **Discuss a requirement** by opening an
  [issue](https://github.com/yuric/leverage/issues).
- **Propose a change** with a pull request against
  [docs/PRD.md](docs/PRD.md). Pull requests are welcome at any time; you do
  not need to open an issue first.

Read [CONTRIBUTING.md](CONTRIBUTING.md) before you start, and
[MAINTENANCE.md](MAINTENANCE.md) to know what to expect: leverage has one
maintainer, and responses are best effort.

## How it is built

leverage is developed largely with AI coding agents, directed and reviewed by
the maintainer. Every change to `main` goes through a pull request and
automated checks. Contributors may use AI tools too, under the
[same rules](CONTRIBUTING.md#ai-assisted-contributions).

## Attribution

leverage is created and maintained by Yuri ([@yuric](https://github.com/yuric))
and its contributors, listed in [AUTHORS](AUTHORS).

## License

[MIT](LICENSE) © 2026 leverage contributors.
