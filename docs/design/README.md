# Design reference

This folder holds the working mockup of the leverage app, which is the design
reference for the owner-facing screens.

## The mockup

[`mockup.html`](mockup.html) is one self-contained page. Open it in a browser;
it loads nothing from the network.

It shows a Mac-style window with a glass finish: a left pane with the app
icon, the navigation and a project list, and the content beside it. It can be
clicked through like the app: add a task, answer what is waiting under Needs
you, add a credential, and change the handoff order.

The grey bar across the top is an inspector, not part of the design. It
switches between one screen and all artboards, light and dark, glass and
reduced transparency, and wide and narrow. It can also edit the mockup's
labels and the main design tokens, and collect those edits as text. It keeps
its settings and edits in this browser's local storage, so they are still
there after a reload; Discard all changes, in the Changes dialog, removes the
edits. Its Names switch can show an earlier wording (Accounts, To define,
Waiting on you) for comparison; that wording is not the design.

## What it covers

| Screen | In the mockup |
| --- | --- |
| Board | The six lanes, with cards and their states |
| Add task | Title, acceptance criteria and project only |
| Needs you | Approvals, a question and a credential request |
| Activity | A short feed |
| Agents | A plain list, without the roster's full fields |
| Credentials | A flat list of logins and the two-step Add credential sheet, for logins only. Not designed: grouping by provider, API tokens, available resets, Refresh and Verify all |
| Handoff | The handoff order, changed with up and down buttons (no dragging), and the fixed rules |
| System health | One line at the foot of the left pane |

The other screens the PRD lists for version 1 are not designed yet.

## Credentials in the app

The Credentials screen extends the mockup with sections for logins and
API tokens, provider headings, a sign-in status dot, account facts,
figure tiles, reset and reading-age lines, a row menu, and Refresh and
Verify all. The Add sheet adds the token provider picker, a secure
field and the token check. Handoff keeps the up and down buttons and
adds a drag placement line and position hint. Token rows explain that
the token is not used for work yet.

In Activity, Everything shows `You renamed <name>.`, `You removed an
account.` and `You moved <name> in the handoff order.` The app uses
"an account" when it cannot look up a current name.

## How to read it

- [docs/PRD.md](../PRD.md) defines what is built. Where the mockup and the PRD
  differ, the PRD is right until it is changed.
- The tasks, projects, credentials, times and names in the mockup are sample
  data. They are not requirements.
- The behavior in the mockup is a sketch. For example, adding a credential
  resumes a blocked task at once; the real rules are in the PRD.
- The labels are owner-facing wording. The first lane is labelled Ideas
  where the PRD says Imaginarium, and the Kanban and Agent roster screens are
  labelled Board and Agents. The PRD's terms are unchanged.
- The Mac app is to be native, written in Swift with SwiftUI. What carries
  into it is the design tokens at the top of the file (colors, glass,
  corners, type sizes) and the layout. The HTML, the CSS class names (`lv-`
  for the mockup, `ix-` for the inspector) and the JavaScript are for the
  mockup only.
- The app icon is drawn in the file as an SVG: a lever lifting a block.
