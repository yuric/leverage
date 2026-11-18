# Contributing to leverage

Thank you for considering a contribution. This document explains how to
propose a change and what to expect when you do.

By participating you agree to follow the
[Code of Conduct](CODE_OF_CONDUCT.md).

## Where the project is

leverage is in its definition phase: the requirements in
[docs/PRD.md](docs/PRD.md) are being written and there is no code yet. Right
now the most valuable contributions are:

- feedback on a requirement, or a requirement that is missing;
- questions that expose an ambiguity;
- corrections to the documentation.

## Ways to contribute

- **Discuss a requirement or idea:** open an issue using the feature request
  template.
- **Report a problem:** open an issue using the bug report template.
- **Report a security vulnerability:** do **not** open an issue. Follow
  [SECURITY.md](SECURITY.md).
- **Change something:** open a pull request.

For anything larger than a small fix, please open an issue first so the
approach can be agreed before you spend time on it.

## Pull requests

1. Fork the repository and create a branch from `main`.
2. Make your change. Keep it focused: one logical change per pull request.
3. Update the documentation the change affects, and add a line to the
   `Unreleased` section of [CHANGELOG.md](CHANGELOG.md) if it is user-visible.
4. Write commit messages that follow
   [Conventional Commits](https://www.conventionalcommits.org/), for example
   `docs: clarify FR-003 acceptance criteria`.
5. Open the pull request and fill in the template. Reference the requirement
   ID (`FR-…`, `NFR-…`) or issue it relates to.
6. Add yourself to [AUTHORS](AUTHORS) in your first pull request.

A maintainer will review it. Expect questions and requested changes; that is
the process working, not a rejection.

## AI-assisted contributions

AI-assisted contributions are welcome. You are responsible for everything you
submit: read it, understand it, and verify it before opening a pull request.
Say in the pull request description that an AI tool was used, and keep any
`Co-Authored-By` trailer the tool adds. Agents should follow
[AGENTS.md](AGENTS.md).

## Licensing of contributions

leverage is licensed under the [MIT License](LICENSE). By submitting a
contribution you agree that it is licensed under the same terms, and you
confirm that you have the right to submit it. Do not submit code or content
you do not have the right to license this way. If you include third-party
material, say so in the pull request and keep its copyright and license
notices intact.
