# Claude Code agent observability on AWS

See what your Claude Code agents spend, by model, by subagent and by tool, with a local dashboard in seconds and a team dashboard on AWS.

Claude Code exports OpenTelemetry metrics and log events. This repository runs an OpenTelemetry Collector with Prometheus and Grafana in Docker Compose for the live view, then sends the same telemetry to AWS for the team view:

```
Claude Code ──OTLP──▶ OpenTelemetry Collector ──▶ Prometheus ──▶ Grafana            (local, Docker Compose)
                              │
                              ├── metrics, SigV4 remote write ──▶ Amazon Managed Service for Prometheus ──┐
                              │                                                                           ├──▶ Amazon Managed Grafana
                              └── log events ───────────────────▶ Amazon CloudWatch Logs ─────────────────┘
                                                                  (log group: claude-code-events)
```

Metrics answer "what is the agent spending right now?" Log events answer "how did cost and tool behavior change across the team over two weeks?"

**Article:** the full walkthrough, with the reasoning behind each choice, is in the companion article (link added when it is published).

## Status

The Compose file, both collector configurations, the Grafana provisioning files, the IAM policy and the dashboard JSON were checked for syntax and structure only. They have not been run against a live AWS account in this repository's first version. Two things are most likely to need a small adjustment on your first run:

- the Prometheus metric names, which depend on how the collector's exporter normalizes them;
- the CloudWatch Logs Insights field names (`attributes.event_name` and similar), which depend on the shape of the records that the exporter writes.

The article's verify steps show how to check each one.

## Prerequisites

- Docker with Docker Compose v2.24 or later
- Claude Code
- For the AWS stage: AWS CLI v2, an AWS account, and AWS IAM Identity Center enabled (the Grafana workspace signs users in through it)

## Quick start: local only

```bash
git clone https://github.com/jubins/claude-code-aws-observability.git
cd claude-code-aws-observability

cp .env.example .env
docker compose up -d

source claude-telemetry.env
claude
```

Send a prompt, wait about 30 seconds, then open Grafana at <http://localhost:3000> and look in the **Claude Code** folder. Prometheus is at <http://localhost:9090>.

Check that the metrics arrived:

```bash
curl -s 'http://localhost:9090/api/v1/label/__name__/values' | grep -o 'claude_code_[a-zA-Z_]*'
```

If a panel stays empty, compare the names that command prints with the ones in `grafana/dashboards/claude-code-agents.json`.

## Send telemetry to AWS

1. **Create a metrics workspace and the remote write URL.**

   ```bash
   export AWS_REGION=us-east-1
   export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

   export AMP_WORKSPACE_ID=$(aws amp create-workspace --alias claude-code --region $AWS_REGION --query workspaceId --output text)
   export AMP_REMOTE_WRITE_URL="https://aps-workspaces.${AWS_REGION}.amazonaws.com/workspaces/${AMP_WORKSPACE_ID}/api/v1/remote_write"
   ```

2. **Create the least-privilege policy and attach it to the identity your AWS profile uses.**

   ```bash
   sed -e "s/__REGION__/$AWS_REGION/g" -e "s/__ACCOUNT_ID__/$ACCOUNT_ID/g" -e "s/__AMP_WORKSPACE_ID__/$AMP_WORKSPACE_ID/g" iam/collector-policy.json > iam/collector-policy.rendered.json
   aws iam create-policy --policy-name ClaudeCodeTelemetryWriter --policy-document file://iam/collector-policy.rendered.json
   ```

   With IAM Identity Center, add the policy to your permission set, or create a role that your profile assumes.

3. **Point Compose at the AWS collector configuration.** Edit `.env`:

   ```bash
   AWS_REGION=us-east-1
   COLLECTOR_CONFIG=otel-collector-aws.yaml
   AMP_REMOTE_WRITE_URL=<the URL from step 1>
   LOG_STREAM_NAME=<your hostname>
   ```

4. **Export temporary credentials and restart the collector.** Run this again whenever the credentials expire.

   ```bash
   export AWS_PROFILE=<your-profile>
   aws sso login --profile $AWS_PROFILE      # only for IAM Identity Center profiles
   ./scripts/refresh-aws-creds.sh
   ```

5. **Verify.**

   ```bash
   docker compose logs otel-collector --tail 30
   aws logs tail claude-code-events --since 15m --region $AWS_REGION
   ```

6. **Create the Amazon Managed Grafana workspace in the console** (service-managed permissions are available only there). Choose **AWS IAM Identity Center** for authentication and select **Amazon Managed Service for Prometheus** and **Amazon CloudWatch** as data sources. Add both as data sources inside the workspace.

7. **Import the team dashboard.**

   ```bash
   ./scripts/render-team-dashboard.sh
   ```

   In Grafana choose **Dashboards**, **New**, **Import**, upload `amg/claude-code-agents-team.rendered.json`, then pick your two data sources in the variables at the top.

Test the four Logs Insights queries in the CloudWatch console before you rely on the log panels. They are listed in the article and embedded in `amg/claude-code-agents-team.json`.

## Repository layout

| Path | Purpose |
|---|---|
| `claude-telemetry.env` | Claude Code telemetry variables. Source it in the shell that starts Claude Code. |
| `docker-compose.yaml` | Collector, Prometheus and Grafana. Ports are bound to `127.0.0.1`. |
| `otel-collector-local.yaml` | Stage 1 collector: metrics to Prometheus, log events printed to the collector log. |
| `otel-collector-aws.yaml` | Stage 2 collector: adds SigV4 remote write to Amazon Managed Service for Prometheus and the CloudWatch Logs exporter. |
| `prometheus.yml` | One scrape target, the collector. |
| `.env.example` | Compose variables. Copy to `.env`. |
| `grafana/provisioning/` | Provisions the Prometheus data source and the dashboard folder. |
| `grafana/dashboards/claude-code-agents.json` | Local dashboard, 8 panels. |
| `amg/claude-code-agents-team.json` | Team dashboard for Amazon Managed Grafana, 9 panels, with Region and account placeholders. |
| `iam/collector-policy.json` | Least-privilege policy for the collector, with placeholders. |
| `scripts/refresh-aws-creds.sh` | Exports temporary credentials to `.env.aws` and restarts the collector. |
| `scripts/render-team-dashboard.sh` | Fills the Region and account placeholders in the team dashboard. |

## Configuration

| Variable | Where | Meaning |
|---|---|---|
| `AWS_REGION` | `.env` | Region of the workspace and the log group. Default `us-east-1`. |
| `COLLECTOR_CONFIG` | `.env` | `otel-collector-local.yaml` (default) or `otel-collector-aws.yaml`. |
| `AMP_REMOTE_WRITE_URL` | `.env` | Remote write URL of the Amazon Managed Service for Prometheus workspace. |
| `LOG_STREAM_NAME` | `.env` | CloudWatch log stream name. Use one per machine. |
| `OTELCOL_IMAGE` | `.env` | Collector image. Pin a tested tag or digest instead of `latest`. |
| `OTEL_METRICS_INCLUDE_SESSION_ID` | `claude-telemetry.env` | Set to `false` so that the session identifier does not multiply metric series. Session detail stays in the log events. |

## Security notes

- Credentials: the collector uses temporary credentials that `scripts/refresh-aws-creds.sh` writes to `.env.aws`. That file is git-ignored. For a shared collector, run it on Amazon ECS or Amazon EC2 with an IAM role instead.
- Prompts, responses and tool parameters stay redacted by default in Claude Code. Do not enable the opt-in variables unless you accept that the content reaches CloudWatch Logs.
- Local Grafana runs with anonymous admin access. That is safe only because every published port is bound to `127.0.0.1`. Do not change those bindings.
- The IAM policy allows `aps:RemoteWrite` on one workspace and writes to one log group, nothing else.

## Cost

Ingestion is cheap. In the article's estimate for a 50-developer team, metrics and logs ingestion come to about $6 a month. Amazon Managed Grafana seats ($9 per active editor, $5 per active viewer) and CloudWatch Logs Insights scans cost more. A dashboard load scans the log window once for each log panel, so the team dashboard ships with auto-refresh off. Treat the estimate as a starting point, not a measurement, and confirm rates on the AWS pricing pages.

## Troubleshooting

| Symptom | First thing to check |
|---|---|
| The collector restarts after you switch to the AWS configuration | `AMP_REMOTE_WRITE_URL` is set in `.env` |
| Remote write returns 403 | The policy names the right workspace ID and Region, and your profile has the policy |
| `ExpiredToken` errors | Run `scripts/refresh-aws-creds.sh` again |
| Logs Insights returns no rows | Run `fields @message \| limit 5` and compare the field names with the queries |
| Prometheus panels are empty in Amazon Managed Grafana | The metric names in the workspace, and the data source variable at the top of the dashboard |

## Clean up

These commands are destructive. Review them first.

```bash
docker compose down -v
rm -f .env.aws iam/collector-policy.rendered.json amg/claude-code-agents-team.rendered.json

export AMG_WORKSPACE_ID=$(aws grafana list-workspaces --region $AWS_REGION --query "workspaces[?name=='claude-code-observability'].id" --output text)
aws grafana delete-workspace --workspace-id $AMG_WORKSPACE_ID --region $AWS_REGION
aws amp delete-workspace --workspace-id $AMP_WORKSPACE_ID --region $AWS_REGION
aws logs delete-log-group --log-group-name claude-code-events --region $AWS_REGION

aws iam detach-role-policy --role-name <your-role> --policy-arn arn:aws:iam::$ACCOUNT_ID:policy/ClaudeCodeTelemetryWriter
aws iam delete-policy --policy-arn arn:aws:iam::$ACCOUNT_ID:policy/ClaudeCodeTelemetryWriter
```

Then check IAM for roles named `AmazonGrafanaServiceRole*`, CloudFormation for stack sets that service-managed permissions created, IAM Identity Center for assignments you added, and the Billing dashboard.
