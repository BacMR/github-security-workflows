#!/usr/bin/env bash
#
# Installs/updates the scanner toolchain under /opt/security-scanner.
# Idempotent — safe to re-run to upgrade tools.
#
# Prereqs: /opt/security-scanner exists and is writable by the current
# user; python3, curl, jq available on the host.

set -euo pipefail

BASE="${SECSCAN_HOME:-/opt/security-scanner}"
GITLEAKS_VERSION="${GITLEAKS_VERSION:-8.30.1}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

mkdir -p "$BASE"/{bin,etc,cache/repos,cache/trivy,tmp}

# ------------------------------------------------------------
# Gitleaks (pinned)
# ------------------------------------------------------------
if [ ! -x "$BASE/bin/gitleaks" ] || ! "$BASE/bin/gitleaks" version 2>/dev/null | grep -q "$GITLEAKS_VERSION"; then
  echo "Installing gitleaks ${GITLEAKS_VERSION}..."
  curl -fsSL -o "$BASE/tmp/gitleaks.tgz" \
    "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz"
  tar -xzf "$BASE/tmp/gitleaks.tgz" -C "$BASE/tmp" gitleaks
  mv "$BASE/tmp/gitleaks" "$BASE/bin/gitleaks"
  rm -f "$BASE/tmp/gitleaks.tgz"
fi
"$BASE/bin/gitleaks" version

# ------------------------------------------------------------
# Trivy (latest, via official install script)
# ------------------------------------------------------------
echo "Installing trivy..."
curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh \
  | sh -s -- -b "$BASE/bin"
"$BASE/bin/trivy" --version

# ------------------------------------------------------------
# Semgrep (dedicated venv)
# ------------------------------------------------------------
echo "Installing semgrep..."
[ -d "$BASE/venv" ] || python3 -m venv "$BASE/venv"
"$BASE/venv/bin/pip" install --quiet --upgrade pip semgrep
ln -sf "$BASE/venv/bin/semgrep" "$BASE/bin/semgrep"
"$BASE/bin/semgrep" --version

# ------------------------------------------------------------
# psql symlink (aaPanel PostgreSQL) + ingest script
# ------------------------------------------------------------
ln -sf /www/server/pgsql/bin/psql "$BASE/bin/psql"
install -m 0755 "$REPO_ROOT/scripts/secscan-ingest.sh" "$BASE/bin/secscan-ingest"

# ------------------------------------------------------------
# DB credentials + schema
# ------------------------------------------------------------
if [ ! -f "$BASE/etc/db.env" ]; then
  if [ -f "$HOME/.config/secscan/db.env" ]; then
    install -m 0600 "$HOME/.config/secscan/db.env" "$BASE/etc/db.env"
  else
    echo "WARNING: $BASE/etc/db.env missing — create it with PGHOST/PGPORT/PGDATABASE/PGUSER/PGPASSWORD" >&2
  fi
fi

if [ -f "$BASE/etc/db.env" ]; then
  echo "Applying database schema..."
  set -a; source "$BASE/etc/db.env"; set +a
  "$BASE/bin/psql" -q -v ON_ERROR_STOP=1 -f "$REPO_ROOT/db/schema.sql"
fi

# ------------------------------------------------------------
# Warm the Trivy vulnerability DB so daily runs skip the download
# ------------------------------------------------------------
echo "Warming Trivy vulnerability database..."
TRIVY_CACHE_DIR="$BASE/cache/trivy" "$BASE/bin/trivy" fs \
  --scanners vuln --quiet --format json --output /dev/null "$BASE/tmp" || true

echo ""
echo "Toolchain ready under $BASE/bin:"
ls -l "$BASE/bin"
