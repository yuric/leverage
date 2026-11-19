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
reduced transparency, and wide and narrow. It can also edit any label and any
design token, and collect those edits as text.

## What it covers

| Screen | In the mockup |
| --- | --- |
| Board | The six lanes, with cards and their states |
| Add task | Title, completion criteria and project only |
| Needs you | Approvals, a question and a credential request |
| Activity | A short feed |
| Agents | A plain list, without the roster's full fields |
| Credentials | The list and the two-step Add credential sheet |
| Handoff | The handoff order and the rules, read only |

The other screens the PRD lists for version 1 are not designed yet.

## How to read it

- [docs/PRD.md](../PRD.md) defines what is built. Where the mockup and the PRD
  differ, the PRD is right until it is changed.
- The tasks, projects, credentials, times and names in the mockup are sample
  data. They are not requirements.
- The behavior in the mockup is a sketch. For example, adding a credential
  resumes a blocked task at once; the real rules are in the PRD.
- The design tokens at the top of the file (colors, glass, corners, type
  sizes) and the class names that start with `lv-` are the parts meant to be
  carried into the Mac app.
- The app icon is drawn in the file as an SVG: a lever lifting a block.
