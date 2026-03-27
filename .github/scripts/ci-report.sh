#!/usr/bin/env bash
#
# Vendored CI Status Reporter for Slack.
# Keep workflow notifications self-contained in this repo instead of fetching
# the script from a private monorepo at runtime.
#
# Usage:
#   bash .github/scripts/ci-report.sh [status] [workflow_name] [run_id] [webhook_url_or_bot_token]
#

set -euo pipefail

STATUS=${1:-"success"}
WORKFLOW_NAME=${2:-"CI Pipeline"}
RUN_ID=${3:-"0"}
AUTH_VAR=${4:-""}

CHANNEL_ID="C0AG3FPQ7QX" # #ci_deploy-reports
REPO="${GITHUB_REPOSITORY:-"illforte/n8n-fork"}"
RUN_URL="${GITHUB_SERVER_URL:-"https://github.com"}/${REPO}/actions/runs/${RUN_ID}"

if [[ "$STATUS" == "success" ]]; then
  ICON=":white_check_mark:"
  COLOR="#36a64f"
elif [[ "$STATUS" == "cancelled" || "$STATUS" == "skipped" ]]; then
  ICON=":warning:"
  COLOR="#ffcc00"
else
  ICON=":x:"
  COLOR="#ff0000"
fi

COMMIT_SHA=${GITHUB_SHA:-$(git rev-parse HEAD 2>/dev/null || echo "unknown")}
SHORT_SHA=${COMMIT_SHA:0:7}
COMMIT_URL="${GITHUB_SERVER_URL:-"https://github.com"}/${REPO}/commit/${COMMIT_SHA}"

COMMIT_MSG=$(git log -1 --pretty=format:"%s" 2>/dev/null | sed 's/"/\\"/g' || echo "No commit message")
COMMIT_AUTHOR=$(git log -1 --pretty=format:"%an" 2>/dev/null || echo "${GITHUB_ACTOR:-"unknown"}")

PAYLOAD=$(cat <<JSON_EOF
{
  "channel": "$CHANNEL_ID",
  "text": "$WORKFLOW_NAME: $STATUS on $REPO",
  "attachments": [
    {
      "color": "$COLOR",
      "blocks": [
        {
          "type": "section",
          "text": {
            "type": "mrkdwn",
            "text": "$ICON *$WORKFLOW_NAME $STATUS*\n*Repo:* $REPO\n*Commit:* <$COMMIT_URL|$SHORT_SHA> by $COMMIT_AUTHOR\n*Message:* $COMMIT_MSG"
          }
        },
        {
          "type": "actions",
          "elements": [
            {
              "type": "button",
              "text": {
                "type": "plain_text",
                "text": "View Run",
                "emoji": true
              },
              "url": "$RUN_URL"
            }
          ]
        }
      ]
    }
  ]
}
JSON_EOF
)

if [[ -n "$AUTH_VAR" && "$AUTH_VAR" == https://hooks.slack.com/* ]]; then
  RESPONSE=$(curl -fsS -X POST -H "Content-type: application/json; charset=utf-8" --data "$PAYLOAD" "$AUTH_VAR")
  if [[ "$RESPONSE" != "ok" ]]; then
    echo "Error: Slack webhook rejected CI report: $RESPONSE"
    exit 1
  fi
elif [[ -n "$AUTH_VAR" && "$AUTH_VAR" == xoxb-* ]]; then
  RESPONSE=$(curl -fsS -X POST -H "Content-type: application/json; charset=utf-8" -H "Authorization: Bearer $AUTH_VAR" --data "$PAYLOAD" "https://slack.com/api/chat.postMessage")
  if ! grep -q '"ok":true' <<<"$RESPONSE"; then
    echo "Error: Slack API rejected CI report: $RESPONSE"
    exit 1
  fi
else
  echo "Error: Expected a Slack webhook URL or bot token"
  exit 1
fi

echo "CI report sent to Slack channel $CHANNEL_ID"
