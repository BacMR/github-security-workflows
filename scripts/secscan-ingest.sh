#!/usr/bin/env bash
#
# secscan-ingest <scan_run_id> <owner/repo> <gitleaks|trivy|semgrep> <report.json>
#
# Inserts a scanner report into the secscan Postgres database.
# Deployed to /opt/security-scanner/bin/secscan-ingest by deploy/install-tools.sh.

set -euo pipefail

SECSCAN_HOME="${SECSCAN_HOME:-/opt/security-scanner}"

if [ $# -ne 4 ]; then
  echo "usage: secscan-ingest <scan_run_id> <owner/repo> <scanner> <report.json>" >&2
  exit 2
fi

RUN_ID="$1"
REPO="$2"
SCANNER="$3"
export REPORT="$4"

set -a
# shellcheck disable=SC1091
source "$SECSCAN_HOME/etc/db.env"
set +a

# Guarantee valid JSON so the jsonb cast never fails the ingest.
if [ ! -s "$REPORT" ] || ! jq -e . "$REPORT" >/dev/null 2>&1; then
  echo '{"secscan_error": "missing or invalid report json"}' > "$REPORT"
fi

"$SECSCAN_HOME/bin/psql" -q -v ON_ERROR_STOP=1 \
  -v run_id="$RUN_ID" -v repo="$REPO" -v scanner="$SCANNER" <<'SQL'
\set report `cat "$REPORT"`
SELECT ingest_report(:run_id::bigint, :'repo', :'scanner', :'report'::jsonb) AS repo_scan_id;
SQL
