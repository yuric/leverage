# Contributing to leverage

Thank you for considering a contribution. This document explains how to
propose a change and what to expect when you do.

By participating you agree to follow the
[Code of Conduct](CODE_OF_CONDUCT.md). Please also read the short
[maintenance policy](MAINTENANCE.md): leverage has one maintainer, responses
are best effort, and the project's scope is deliberately narrow.

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
- **Change something:** open a pull request. Pull requests are welcome at any
  time, and you do not need to open an issue first.

For a larger change, talking it through in an issue first is optional but
wise: it is the best way to find out whether the change fits the project's
[scope](MAINTENANCE.md#scope) before you spend time on it.

## Pull requests

1. Fork the repository and create a branch from `main`.
2. Make your change. Keep it focused: one logical change per pull request.
3. Update the documentation the change affects, and add a line to the
   `Unreleased` section of [CHANGELOG.md](CHANGELOG.md) if it is user-visible.
4. Give the pull request a title that follows
   [Conventional Commits](https://www.conventionalcommits.org/), for example
   `docs: clarify FR-003 acceptance criteria`. The title is checked
   automatically.
5. Fill in the pull request template, including the AI assistance section.
   Reference the requirement ID (`FR-…`, `NFR-…`) or issue it relates to.
6. Add yourself to [AUTHORS](AUTHORS) in your first pull request.

Every change to `main` goes through a pull request, including the
maintainer's. A maintainer will review yours when time allows. Expect
questions and requested changes; that is the process working, not a rejection.

### Automated checks

Each pull request runs these checks, and all of them must pass before it can
be merged:

| Check | What it verifies | Run it locally |
|-------|------------------|----------------|
| Markdown lint | Markdown files follow the rules in `.markdownlint-cli2.yaml`. | `npx markdownlint-cli2 "**/*.md"` |
| Internal links | Links between files in the repository resolve. | `lychee --offline --include-fragments './**/*.md'` |
| PRD requirement IDs | IDs in `docs/PRD.md` are well formed and unique. | `python3 scripts/check_prd_ids.py` |
| PR title | The title follows Conventional Commits. | — |

## AI-assisted contributions

leverage itself is built largely with AI coding agents, so AI-assisted
contributions are welcome. What matters is that a person stands behind the
work. The rules are the same for everyone, including the maintainer.

- **Disclose it.** Say in the pull request which tool you used and what you
  used it for (writing code, drafting text, review, finding the bug). Tick the
  matching box in the template. Keep any `Co-Authored-By` or similar trailer
  the tool adds to your commits.
- **Own it.** You are the author. Read everything you submit, verify it
  yourself, and be able to explain every change without the tool. "The model
  wrote that part" is not an answer to a review question.
- **Same standard.** A change is judged on what it does, not on how it was
  written. AI assistance neither lowers the bar nor counts against you.
- **Write to people in your own words.** You may draft issues, comments, and
  descriptions with a tool, but read them, check every claim, and edit them
  until they say what you mean. Do not paste unreviewed model output. Short
  and accurate beats long and polished.
- **No unattended agents.** Do not point an autonomous agent at this
  repository to open issues or pull requests without a person reviewing each
  one before it is submitted.
- **Security reports have their own rule.** A model-generated vulnerability
  report that you have not reproduced yourself is not a security report. See
  [SECURITY.md](SECURITY.md#ai-assisted-reports).

Undisclosed AI use, or output nobody has verified, may be closed without a
detailed review. Repeated cases may lead to being blocked from the repository.

Agents working in this repository should follow [AGENTS.md](AGENTS.md).

## Licensing of contributions

leverage is licensed under the [MIT License](LICENSE). By submitting a
contribution you agree that it is licensed under the same terms, and you
confirm that you have the right to submit it. That holds whether you wrote it
by hand or with a tool. Do not submit code or content you do not have the
right to license this way. If you include third-party material, say so in the
pull request and keep its copyright and license notices intact.
