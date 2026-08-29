# mootmaker-bootstrap-aws-accounts

CloudFormation that locks down the AWS accounts everything else deploys into: service control
policies, IAM Identity Center for keyless access, billing alerts, and access-key rotation.

**Start by reading [README.md](README.md).**

## Working here

- **CloudFormation, not Terraform** — unlike every other repository here. These are account-level
  guardrails that must exist before Terraform has anywhere safe to run.
- **The stack name matches the YAML filename.** That is the convention for finding which stack owns
  a given permission.
- **This is where "no long-lived credentials" is enforced.** SSO for people, OIDC for automation.
  Weakening a guardrail to make something work is almost always the wrong fix.
- **Getting this wrong can lock you out of your own account.** Read what a policy does before
  applying it, and know how you would recover.

---

## Project-wide rules

This repository is part of the **mootmaker** project. The workflow rules that apply everywhere live
in the hub repository, which you should find checked out as a sibling directory:

    ../mootmaker/docs/process/README.md

On GitHub: <https://github.com/geoffweatherall/mootmaker/blob/main/docs/process/README.md>

**Read it before doing any non-trivial work here.** The short version:

- Work of any real size starts with a **design document** (`../mootmaker/designs/`), not with code.
- Bugs and small changes start with a **GitHub issue in this repository**, so `Closes #N` works.
- All work happens on a **branch** and lands via a **pull request**. There is no approval step —
  reading the diff is the review, merging is the approval.
- **A green acceptance run against a real deployed environment** is the definition of working — not
  a passing unit suite, and not a successful deploy.
- **Environments are `production` or ephemeral.** Tear down any ephemeral environment you create;
  that is part of finishing, not a tidy-up afterwards.
- **If your change makes a document wrong, fixing it is part of the change.**
- **Verify against reality, not your own output.** A script exiting zero is not evidence that the
  thing it was meant to do happened.
- **Say what actually happened.** Failing tests get reported with their output; skipped steps get
  named.

Also useful: [`../mootmaker/docs/roles/`](https://github.com/geoffweatherall/mootmaker/blob/main/docs/roles/)
for which kind of work you are doing, and
[`../mootmaker/tools/workstation/check.sh`](https://github.com/geoffweatherall/mootmaker/blob/main/tools/workstation/check.sh)
if something is not installed.

`CLAUDE.md` in this repository is a symlink to this file.
