# mootmaker-bootstrap-aws-accounts

CloudFormation that locks down the AWS accounts everything else deploys into: service control
policies, IAM Identity Center for keyless access, billing alerts, and access-key rotation.

**Read [README.md](README.md) first**, then the README in the account directory you are working in.
Keep them true in the same pull request as any change that affects them.

## Working here

- **CloudFormation, not Terraform** — unlike every other repository here. These are account-level
  guardrails that must exist before Terraform has anywhere safe to run.
- **The stack name matches the YAML filename.** That is the convention for finding which stack owns
  a given permission.
- **This is where "no long-lived credentials" is enforced.** SSO for people, OIDC for automation.
  Weakening a guardrail to make something work is almost always the wrong fix.
- **Getting this wrong can lock you out of your own account.** Read what a policy does before
  applying it, and know how you would recover.
- **Stacks are applied with `./deploy-stack.sh`** (see README.md). Run without a terminal, it
  previews a change set and deletes it - agents can use it to show what a change would do.
- **Agents never run `management-account/with-management-credentials.sh`**, never call
  `aws sso get-role-credentials`, and never change `management-access.yaml`'s stack. Prepare the
  exact command for Geoff to run instead. Management write access is deliberately on a separate
  Identity Center user that the everyday session cannot reach.

- **The service allow-list is in two templates** (`scp-guardrails.yaml` and `identity-center.yaml`), and
  the region allow-list limits everything to us-east-1. A new AWS service needs both lists, and the
  GitHub Actions deploy role's `mootmaker-deploy-*` policies, before any component can use it.
- **A workload stack change is previewed with `./deploy-stack.sh <template>`** and applied by a person
  at a terminal.

---

## Project-wide rules

This repository is part of **Mootmaker**. The hub repository, checked out as a sibling at
`../mootmaker`, holds what applies everywhere:

- How work is done: [`../mootmaker/docs/process/README.md`](https://github.com/geoffweatherall/mootmaker/blob/main/docs/process/README.md).
  Read it before any non-trivial work.
- How the system fits together: [`../mootmaker/docs/overview/`](https://github.com/geoffweatherall/mootmaker/tree/main/docs/overview).
- What to do when something is wrong: [`../mootmaker/docs/runbooks/`](https://github.com/geoffweatherall/mootmaker/blob/main/docs/runbooks/README.md).

The short version:

- Work of any real size starts with a **design** (`../mootmaker/designs/`); a bug or small change starts
  with a **GitHub issue in this repository**, so `Closes #N` works.
- Everything lands on a **branch** through a **pull request**. Reading the diff is the review; merging is
  the approval.
- **A green acceptance run against a real deployed environment** is the definition of working.
- **`test` and `production` change only through a release** (`release.yml` in mootmaker-release). Use an
  ephemeral environment for your own work, and tear it down when you finish.
- **Say what something costs in AWS before creating it.** Under NZ$1 one-off, go ahead and state it;
  more, or anything recurring, ask first.
- **Keep documentation and comments true and current.** If a change makes a document wrong, fixing it is
  part of the change. Describe what is, not how it got here; a comment says what and why.
- **Verify against reality, not your own output**, and **say what actually happened**, including
  failures and skipped steps.

Something not installed? [`../mootmaker/tools/workstation/check.sh`](https://github.com/geoffweatherall/mootmaker/blob/main/tools/workstation/check.sh).

`CLAUDE.md` in this repository is a symlink to this file.
