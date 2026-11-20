# AGENTS.md — BacMR Security Workflows

Repo: `BacMR/github-security-workflows`. Read `README.md` first (how the gate
decides, suppression policy, VPS layout, database). This file is the single agent
guide for the repo; it adds the working conventions. There is no `CLAUDE.md`.

## Ground rules

- **Default branch is `main`, not `dev`** (this repo is not deployed). Every repo's
  `pr-security.yml` calls `security-scan.yml@main`, so `main` is the live gate for the
  whole org: never rename or retarget it, and treat every merge as an org-wide release.
- Feature branches (`feat/…`, `fix/…`, `chore/…`) off `main`; PR back into `main`.
  Never push to `main` directly (org ruleset). Conventional Commits; commits end with
  the `Co-Authored-By` trailer.
- The PR must pass `security / Security Gate`. This repo gates itself with the
  **local** `uses: ./.github/workflows/security-scan.yml`, so a change to the scanner
  is validated by the version in the PR. Do not switch that to `@main`.
- No app secrets here. DB credentials live only on the VPS
  (`/opt/security-scanner/etc/db.env`), never in the repo or GitHub secrets.

## Workflows

- `security-scan.yml` — reusable (`workflow_call`) PR Security Gate on GitHub-hosted
  runners. One `scan` job runs Gitleaks, Semgrep and Trivy as steps that never fail on
  findings; only `security-gate` (on `ubuntu-slim`) can block. Required check name:
  `security / Security Gate` — never rename the `Security Gate` job.
- `security-self-test.yml` — proves the gate fails closed (findings, scanner errors,
  skipped steps) against runtime-generated fixtures; dispatch it after a gate change.
- `scheduled-org-scan.yml` — daily 05:00 UTC full scan of every non-archived org repo
  on the VPS self-hosted runner (`/opt/security-scanner`, label `secscan`); reports go
  to the `secscan` Postgres DB. Never gates. Only this workflow may use the
  self-hosted runner; never point PR workflows at it.
- `pr-security.yml` — this repo's own gate (local reference, see above).
- `dependabot-auto-merge.yml` — auto-merge tier for Dependabot PRs.

## Action pinning

`security-scan.yml` and `security-self-test.yml` pin every action to a full commit SHA
with a `# vX.Y.Z` comment, and so do third-party actions that run with privileged tokens
(e.g. `dependabot/fetch-metadata`). Dependabot (monthly, grouped patch/minor, 7-day
cooldown) bumps SHA and comment together. Do not add an unpinned action; pin new ones to
a SHA.

## Testing a scanner change

1. Open the PR: the PR's own `pr-security` run uses your modified
   `security-scan.yml`, so it is the integration test. Read the PR comment table and the
   scan job's three "Record Status" steps, not just the green check.
2. Run **Security Self-Test** on the branch: `gh workflow run security-self-test.yml
   --ref <branch>` (every case; `-f case=<case>` for one). `verify` must be green, meaning
   clean passed and every finding/error/skipped case turned the gate red. Link the run in
   the PR.
   Never set `simulate_crash` or `self_test` in a consumer repo.
3. Toolchain/DB changes: `deploy/install-tools.sh` (idempotent) on the VPS; schema in
   `db/schema.sql`; ingestion in `scripts/secscan-ingest.sh`. Check the next daily run
   in `scan_runs` afterwards.

## Suppression policy

See "Dealing with a finding" in `README.md`: fix first; otherwise inline suppression
with the full rule id and a one-line justification (`# nosemgrep: <full.rule.id>`,
`gitleaks:allow` / `.gitleaks.toml`, dated `.trivyignore`). A suppression without a
justification is a review finding.

## Docs

Keep `README.md` current when behaviour changes, and the VPS page
(https://vps-setup.bacmr.com) for runner/DB/tooling changes.
