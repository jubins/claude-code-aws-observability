#!/usr/bin/env bash
# Fill the region and account placeholders in the team dashboard so it can be imported into Amazon Managed Grafana.
set -euo pipefail

REGION="${AWS_REGION:?Set AWS_REGION}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

sed -e "s/__REGION__/${REGION}/g" -e "s/__ACCOUNT_ID__/${ACCOUNT_ID}/g" \
  amg/claude-code-agents-team.json > amg/claude-code-agents-team.rendered.json

echo "Wrote amg/claude-code-agents-team.rendered.json"
