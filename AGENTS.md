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
  runners. Scanner jobs (Gitleaks, Trivy, Semgrep) never fail on findings; only
  `security-gate` can block, and only when `enforce_new_findings: true`.
- `scheduled-org-scan.yml` — daily 05:00 UTC full scan of every non-archived org repo
  on the VPS self-hosted runner (`/opt/security-scanner`, label `secscan`); reports go
  to the `secscan` Postgres DB. Never gates. Only this workflow may use the
  self-hosted runner; never point PR workflows at it.
- `pr-security.yml` — this repo's own gate (local reference, see above).
- `dependabot-auto-merge.yml` — auto-merge tier for Dependabot PRs.

## Action pinning

Marketplace actions track their newest major tag (`actions/checkout@v7`, …) and
Dependabot (monthly, grouped patch/minor, 7-day cooldown) keeps them current.
Third-party actions outside the GitHub/aquasecurity first-party set that run with
privileged tokens (e.g. `dependabot/fetch-metadata`) are pinned to a full commit SHA
with a `# vX.Y.Z` comment. Do not add an unpinned third-party action; pin new ones to a
SHA.

## Testing a scanner change

1. Open the PR: the PR's own `pr-security` run uses your modified
   `security-scan.yml`, so it is the integration test. Read the PR comment table and the
   three scanner jobs, not just the green check.
2. To prove a scanner still detects, push a throwaway commit on the branch with a
   known-bad sample (fake secret, vulnerable manifest, Semgrep-matching code), confirm
   the gate fails with `enforce_new_findings: true`, then drop the commit.
3. Remember the known gap in `README.md`: a crashed scanner is read as zero findings,
   so confirm each scanner job actually produced its report.
4. Toolchain/DB changes: `deploy/install-tools.sh` (idempotent) on the VPS; schema in
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
