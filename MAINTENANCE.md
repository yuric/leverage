# Maintenance policy

What you can expect from the people who maintain Leverage, and what they
expect from you. It is short on purpose. If it and another document disagree,
this one describes the intent; please open an issue so the other can be fixed.

## Who maintains Leverage

Leverage has one maintainer, Yuri ([@yuric](https://github.com/yuric)). There
is no team, no company support desk, and no on-call rotation.

## What to expect

- **Responses are best effort.** There is no guaranteed response time for
  issues, pull requests, or questions. Some will be answered the same day and
  some will wait a long while. Silence means "not read yet", not "rejected".
- **No support is owed.** Leverage is provided under the
  [MIT License](LICENSE), "as is", without warranty. Help is given when time
  allows, not as an obligation.
- **Security reports are the exception.** They have response targets, set out
  in [SECURITY.md](SECURITY.md).
- **Clear and small gets handled first.** A report that can be reproduced, or
  a change that does one thing and says which requirement it serves, is much
  more likely to be looked at soon than a large or vague one.

## Scope

[docs/PRD.md](docs/PRD.md) defines what Leverage is, including a list of
non-goals. The default answer to anything outside it is no. That is how a
one-person project stays maintainable, and it is not a judgment of the idea or
of you.

Expect these to be declined:

- features that are not traceable to a requirement in the PRD (propose the
  requirement first; that discussion is welcome);
- anything the PRD lists as a non-goal;
- large refactors or rewrites nobody asked for;
- new dependencies or services without a clear need and an MIT-compatible
  license;
- changes whose author cannot explain them (see
  [AI-assisted contributions](CONTRIBUTING.md#ai-assisted-contributions)).

Accepting a change means maintaining it from then on, so "it works" is not
enough on its own for a change to be merged.

## Contributions

Pull requests are welcome at any time, and you do not need to open an issue
first. Talking through a larger change in an issue beforehand is still the
best way to avoid work that ends up declined. See
[CONTRIBUTING.md](CONTRIBUTING.md).

## How the project is built

Leverage is developed largely with AI coding agents, directed and reviewed by
the maintainer. Agent-authored commits carry a `Co-Authored-By` trailer. Every
change to `main`, including the maintainer's own, goes through a pull request
and the automated checks; direct pushes are blocked. Agents follow
[AGENTS.md](AGENTS.md).

## Changes to this policy

This policy will change as the project does: when there are releases, and
when there is more than one maintainer. Changes are made by
pull request like everything else.
