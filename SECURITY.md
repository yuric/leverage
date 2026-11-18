# Security Policy

## Supported versions

leverage has not made a release yet. Once it does, this section will list
which versions receive security fixes. Until then, fixes land on `main`.

## Reporting a vulnerability

**Please do not report security vulnerabilities in public issues, pull
requests, or discussions.**

Report them privately through GitHub:

1. Go to the repository's
   [Security tab](https://github.com/yuric/leverage/security).
2. Choose **Report a vulnerability**
   ([direct link](https://github.com/yuric/leverage/security/advisories/new)).
3. Describe the issue.

A useful report includes:

- what is affected (file, component, version or commit);
- how to reproduce it, ideally with a minimal proof of concept;
- the impact you believe it has;
- any fix or mitigation you have in mind.

## AI-assisted reports

Reports found or drafted with the help of AI tools are welcome, on one
condition: you have verified the finding yourself. Before you report:

- reproduce the problem, and include the steps that worked for you;
- confirm that the code or configuration you describe exists in this
  repository, at the commit you name;
- say which tool you used.

A model-generated report that nobody has reproduced is not a security report
and will be closed. See also
[AI-assisted contributions](CONTRIBUTING.md#ai-assisted-contributions).

## What to expect

leverage has one maintainer (see the
[maintenance policy](MAINTENANCE.md)), so these are targets rather than
guarantees:

- acknowledgement of your report within 7 days;
- an assessment, and a plan if the report is confirmed, within 30 days;
- credit in the published advisory, unless you prefer to stay anonymous.

Please give us a reasonable chance to release a fix before you disclose the
issue publicly. We will coordinate the disclosure date with you.

## Scope

In scope: the code and configuration in this repository.

Out of scope: vulnerabilities in third-party dependencies (report those
upstream, though we want to know if leverage is affected), and problems that
require an already-compromised machine or account.
