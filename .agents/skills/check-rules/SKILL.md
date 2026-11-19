---
name: check-rules
description: Check a pull request against the architecture rules in docs/ARCHITECTURE.md and write the "Architecture rules" section of its description. Use before opening or updating any pull request in this repository.
---

# Check a pull request against the architecture rules

The rules are in the [Rules](../../../docs/ARCHITECTURE.md#rules) section of
the architecture document. This skill is the procedure for answering them. It
does not restate them: read them there, every time, because they change.

## Steps

1. **Read the rules.** Open the Rules section and note every rule marked
   Active, with its "Checked automatically" and "Left to review" lines.

2. **Get the evidence.** Look at what the pull request changes, not at what
   you remember changing:

   ```bash
   git fetch origin main
   git diff --stat origin/main...HEAD
   git diff origin/main...HEAD
   ```

3. **Answer each active rule from the diff.** For each one, find the lines in
   the diff that the rule is about, then choose:

   - `Complies` when the rule applies and the diff follows it. Say what you
     checked, in a few words, after the answer.
   - `N/A` with a reason when nothing in the diff is covered by the rule.
   - `Deviates` only when the maintainer has agreed to break the rule and an
     ADR records why. Otherwise stop and ask before going further.

4. **Write the section** into the file that holds the pull request
   description, one line per active rule, in the form the Rules section shows
   under "How the rules are applied". Start from
   [the template](../../../.github/PULL_REQUEST_TEMPLATE.md) so the other
   sections are there too.

5. **Run the check** and fix what it reports, in the change or in the answer,
   whichever is wrong:

   ```bash
   python3 scripts/check_rules.py --base origin/main --body-file <file>
   ```

6. **Open or update the pull request** with that file
   (`gh pr create --body-file <file>` or `gh pr edit --body-file <file>`).

7. **Tell the person you are working for** which rules you answered `N/A` or
   `Deviates`, and what each rule leaves to review. The check proves the
   answers are present, not that they are true.

## Never

- Answer `Complies` for a rule you did not check against the diff.
- Change the rules, the template, or `scripts/check_rules.py` to get a pass,
  unless changing them is the task you were given.
