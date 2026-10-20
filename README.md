# BacMR Security Workflows

Org-wide security scanning for BacMR: **Gitleaks** (secrets), **Trivy**
(dependency and OS vulnerabilities, CRITICAL+HIGH) and **Semgrep** (SAST).
Every repository in the org calls the reusable workflow here on each pull
request, and a daily scan of every non-archived repo runs on the VPS.

Two execution paths:

| Path | Where it runs | Purpose |
|---|---|---|
| `security-scan.yml` (`workflow_call`) | GitHub-hosted runners | Reusable **PR Security Gate** — repos call it from their own `pr-security.yml` |
| `scheduled-org-scan.yml` | Self-hosted runner on the VPS (`/opt/security-scanner`, label `secscan`) | Daily 05:00 UTC scan of every non-archived org repo; reports stored in the `secscan` Postgres database |

PR scans deliberately stay on GitHub-hosted runners so untrusted PR code
never executes on the VPS.

## Adopting the gate in a repo

Copy `examples/pr-security.yml` to `.github/workflows/pr-security.yml`
(or pick "BacMR PR Security Gate" from the Actions workflow templates):

```yaml
name: PR Security
on: [pull_request]
permissions:
  contents: read
  pull-requests: write
  issues: write
jobs:
  security:
    uses: BacMR/github-security-workflows/.github/workflows/security-scan.yml@main
    with:
      scan_mode: pr
      enforce_new_findings: true
```

The rendered check is named **`security / Security Gate`**. The org ruleset
`protect-dev-and-main` requires that check on `dev` and `main` in every repo,
so a repo without this workflow cannot merge any PR.

The aggregate **`gate`** job (in `pr-security.yml`) is the check the org ruleset requires
in every repo; it succeeds only when every job it `needs` succeeded. Add new PR jobs to its
`needs` list.

Inputs of the reusable workflow:

| Input | Default | Meaning |
|---|---|---|
| `scan_mode` | `pr` | `pr` compares the PR against its base; `full` scans the whole tree (used by the daily scan) |
| `enforce_new_findings` | `false` | when `true`, the gate job fails if the PR introduced new findings |

## How the gate decides

1. Each scanner runs in its own job and **never fails on findings**; the three
   jobs always complete so the gate can read all three results.
2. In `pr` mode each scanner is run with the PR's base commit as the baseline
   (Semgrep `--baseline-commit`, Gitleaks on the commit range, Trivy on the
   changed manifests), so only findings **introduced by the PR** count.
3. The `security-gate` job sums `GITLEAKS_NEW + TRIVY_NEW + SEMGREP_NEW`,
   posts a results table as a PR comment, and with `enforce_new_findings: true`
   exits non-zero when the total is above zero. Pre-existing findings in the
   base branch are reported but never block.
4. Daily full scans report backlog to the database; they never gate.

## Dealing with a finding

Fix it. When a finding is a true false positive, suppress it **inline, with the
full rule id and a one-line justification**, so the next reader sees why:

- **Semgrep:** a `# nosemgrep: <full.rule.id>` comment on the flagged line.
  The short id does not suppress; use the full id as printed in the results
  (for example `python.lang.security.audit.httpsconnection-detected.httpsconnection-detected`).
- **Gitleaks:** a `gitleaks:allow` comment on the line, or an entry in the
  repo's `.gitleaks.toml` allowlist with a reason.
- **Trivy:** a `.trivyignore` entry with the CVE id and the reason, dated;
  prefer upgrading the dependency.

Suppressions are reviewed like code; a suppression without a justification is
a review finding.

## Known gap: a crashed scanner looks like a clean scan

The gate reads each scanner's result file and treats a missing file as zero
findings (`[ -f semgrep-new-findings.json ] || echo '{"results":[]}'`). If a
scanner job crashes before writing its report, the gate still passes. This is
tracked on the Production Road Map; the fix is to make each scanner job's
success a required input of the gate.

## VPS layout (`/opt/security-scanner`)

```
bin/        gitleaks, trivy, semgrep, psql (symlink), secscan-ingest
venv/       Python venv for semgrep
etc/db.env  Postgres credentials (mode 600)
cache/
  repos/    cached full-history clones (owner/repo), fetched incrementally
  trivy/    Trivy vulnerability DB cache
runner/     GitHub Actions self-hosted runner (systemd service, label: secscan)
```

Pre-installed tools, cached clones and the cached Trivy DB make the daily run
fast: no per-run downloads, and `git fetch` instead of full clones.

## Database

Dedicated PostgreSQL database `secscan` (role `secscan`) on the VPS's
self-hosted Postgres 16 (`/www/server/pgsql`, port 5432). Schema in
`db/schema.sql`.

- `scan_runs` — one row per daily run
- `repo_scans` — one row per repo+scanner, raw JSON report in `report` (jsonb)
- `findings` — normalized rows (rule, severity, file, line, fingerprint)
- `ingest_report()` — SQL function that stores a report and explodes findings

Useful queries:

```sql
-- Latest run totals per repo
SELECT repository, scanner, findings_count
FROM repo_scans
WHERE scan_run_id = (SELECT max(id) FROM scan_runs)
ORDER BY findings_count DESC;

-- All secrets ever found
SELECT repository, rule_id, file_path, created_at
FROM findings WHERE scanner = 'gitleaks';
```

## Deploy / operations

```bash
# Install or upgrade the toolchain, apply DB schema, warm Trivy DB
./deploy/install-tools.sh

# Install + register the self-hosted runner (needs gh with admin:org)
./deploy/install-runner.sh
```

DB credentials live in `/opt/security-scanner/etc/db.env` (and a backup copy
in `~/.config/secscan/db.env`). Rotate by updating the Postgres role password
and both files.

## Conventions

- Default branch `main` (this repo is not deployed; it is consumed at `@main`).
  This repo gates its own PRs with the **local** `./.github/workflows/security-scan.yml`
  so a change to the scanner is validated by the version in the PR, not the
  one already merged.
- **Latest Node only**: marketplace actions are pinned to their newest majors
  (checkout@v7, upload-artifact@v7, download-artifact@v8, setup-python@v7,
  github-script@v9); Dependabot keeps them current weekly.
- Scanner jobs never fail on findings; only the `security-gate` job can block.
- Daily full scans report backlog; they never gate.
- `CODEOWNERS` routes reviews; it is not a merge gate while there is a single
  owner (see the comment in the file).

## Security notes

- The org runner executes only this repo's scheduled workflow. Don't point PR
  workflows of other repos at the self-hosted runner.
- Postgres listens on 0.0.0.0:5432 — keep 5432 firewalled from the internet;
  the scanner only needs 127.0.0.1.
- Gitleaks reports are written with `--redact`, so secret values are masked in
  the database.
