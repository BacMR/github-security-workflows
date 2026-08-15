#!/usr/bin/env bash
#
# Installs a GitHub Actions self-hosted runner for the Lebjawi-Tech org
# under /opt/security-scanner/runner and registers it as a systemd
# service.
#
# Requires: gh CLI authenticated with admin:org scope
#   (gh auth refresh -h github.com -s admin:org)

set -euo pipefail

ORG="${ORG:-Lebjawi-Tech}"
BASE="${SECSCAN_HOME:-/opt/security-scanner}/runner"
RUNNER_NAME="${RUNNER_NAME:-vps-secscan}"
RUNNER_USER="${RUNNER_USER:-$(id -un)}"

mkdir -p "$BASE"
cd "$BASE"

if [ ! -f ./config.sh ]; then
  VER=$(gh api repos/actions/runner/releases/latest --jq .tag_name | sed 's/^v//')
  echo "Downloading actions/runner v${VER}..."
  curl -fsSL -o runner.tgz \
    "https://github.com/actions/runner/releases/download/v${VER}/actions-runner-linux-x64-${VER}.tar.gz"
  tar xzf runner.tgz
  rm -f runner.tgz
fi

if [ ! -f .runner ]; then
  echo "Requesting org registration token..."
  TOKEN=$(gh api -X POST "/orgs/${ORG}/actions/runners/registration-token" --jq .token)

  ./config.sh \
    --url "https://github.com/${ORG}" \
    --token "$TOKEN" \
    --name "$RUNNER_NAME" \
    --labels secscan \
    --unattended
fi

sudo ./svc.sh install "$RUNNER_USER"
sudo ./svc.sh start
sudo ./svc.sh status
