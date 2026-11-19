---
name: check-rules
description: Check a pull request against the architecture rules in docs/ARCHITECTURE.md and write the "Architecture rules" section of its description. Use before opening or updating any pull request in this repository.
---

# Check a pull request against the architecture rules

The rules are in the [Rules](../../../docs/ARCHITECTURE.md#rules) section of
the architecture document, and
[How the rules are applied](../../../docs/ARCHITECTURE.md#how-the-rules-are-applied)
defines the three answers. This skill is only the order of work. Read both
there, every time, because they change.

## Steps

1. **Read the rules and the answer forms.** Note every rule marked Active,
   with its "Checked automatically" and "Left to review" lines.

2. **Get the evidence.** Look at what the pull request changes, not at what
   you remember changing:

   ```bash
   git fetch origin main
   git diff --stat origin/main...HEAD
   git diff origin/main...HEAD
   ```

3. **Answer each active rule from the diff.** Find the lines in the diff that
   the rule is about before you choose an answer. If the change breaks a
   rule, stop and ask the person you work for.

4. **Write the description** to `tmp/pr-body.md`, which git and the Markdown
   lint both ignore. Start from
   [the template](../../../.github/PULL_REQUEST_TEMPLATE.md) so that every
   section is there.

5. **Run the check** and fix what it reports, in the change or in the answer,
   whichever is wrong:

   ```bash
   python3 scripts/check_rules.py --base origin/main --body-file tmp/pr-body.md
   ```

6. **Report to the person you work for** before anything is opened: every
   answer that is not `Complies`, every warning the check printed, and what
   each rule leaves to review.

7. **Open or update the pull request** once they have asked you to:

   ```bash
   gh pr create --title "<type>: <summary>" --body-file tmp/pr-body.md
   gh pr edit <number> --body-file tmp/pr-body.md
   ```

## Never

- Answer `Complies` for a rule you did not check against the diff.
- Change the rules, the template, or `scripts/check_rules.py` to get a pass,
  unless changing them is the task you were given.
