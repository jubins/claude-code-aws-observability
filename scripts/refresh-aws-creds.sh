#!/usr/bin/env bash
# Export temporary credentials for the collector and restart it.
# Run again whenever they expire. Requires AWS CLI v2 and a profile that can write telemetry.
set -euo pipefail

: "${AWS_PROFILE:?Set AWS_PROFILE to the profile that holds the collector policy}"

# SSO profiles need a fresh login first: aws sso login --profile "$AWS_PROFILE"
aws configure export-credentials --profile "$AWS_PROFILE" --format env-no-export > .env.aws
chmod 600 .env.aws

docker compose up -d --force-recreate otel-collector
echo "Collector restarted with credentials from profile: $AWS_PROFILE"
