# BacMR Security Workflows

Org-wide security scanning for BacMR: Gitleaks (secrets), Trivy
(dependency/OS vulnerabilities, CRITICAL+HIGH), and Semgrep (SAST).

Two execution paths:

| Path | Where it runs | Purpose |
|---|---|---|
| `scheduled-org-scan.yml` | Self-hosted runner on the VPS (`/opt/security-scanner`) | Daily 05:00 UTC scan of every non-archived org repo; reports stored in the `secscan` Postgres database |
| `security-scan.yml` | GitHub-hosted runners | Reusable PR gate — repos call it via `workflow_call` (see `examples/pr-security.yml`) |

PR scans deliberately stay on GitHub-hosted runners so untrusted PR code
never executes on the VPS.

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

Pre-installed tools + cached clones + cached Trivy DB are what make the
daily run fast: no per-run downloads, and `git fetch` instead of full
clones.

## Database

Dedicated PostgreSQL database `secscan` (role `secscan`) on the VPS's
self-hosted Postgres 16 (`/www/server/pgsql`, port 5432).

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

DB credentials live in `/opt/security-scanner/etc/db.env` (and a backup
copy in `~/.config/secscan/db.env`). Rotate by updating the Postgres
role password and both files.

## Conventions

- **Latest Node only**: all marketplace actions are pinned to their
  newest majors (Node 24 runtime) — checkout@v7, upload-artifact@v7,
  download-artifact@v8, setup-python@v7, github-script@v9. Dependabot
  keeps them current weekly.
- Scanner jobs never fail on findings; only the `security-gate` job
  (PR mode + `enforce_new_findings: true`) can block a merge.
- Daily full scans report backlog; they never gate.

## Security notes

- The org runner executes only this repo's scheduled workflow. Don't
  point PR workflows of other repos at the self-hosted runner.
- Postgres listens on 0.0.0.0:5432 — keep 5432 firewalled from the
  internet; the scanner only needs 127.0.0.1.
- Gitleaks reports are written with `--redact`, so secret values are
  masked in the database.
