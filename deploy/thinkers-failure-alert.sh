#!/usr/bin/env bash
set -euo pipefail

# deploy/thinkers-failure-alert.sh — OnFailure= hook for
# headlong-thinkers@<identity>.service (fired via headlong-thinkers-alert@).
# With Restart=on-failure on the unit, OnFailure fires only when the start
# limit is exhausted, so this alert means "died repeatedly, auto-restart
# gave up, the mind is STAYING DOWN". Per-death and recovery notices are
# deploy/thinkers-death-alert.sh's job.
#
# Usage: thinkers-failure-alert.sh APP_DIR IDENTITY
#
# Config (APP_DIR/.env): SLACK_BOT_TOKEN (already present for the bridge)
# and HEADLONG_ALERT_CHANNEL (legacy SHELLM_ALERT_CHANNEL) — the channel ID to post to (e.g. #shellm-bot's
# ID; the bot must be a member). Missing config degrades to a line in
# /var/tmp/headlong-thinkers-alert.log, never a unit failure: the alert path
# must not add its own failure mode on top of a dead mind.

APP_DIR="${1:?usage: thinkers-failure-alert.sh APP_DIR IDENTITY}"
IDENT="${2:?identity name required}"

FALLBACK_LOG="/var/tmp/headlong-thinkers-alert.log"

# Belt-and-suspenders: the unit's EnvironmentFile= already loads this (as
# root); sourcing here covers manual runs. Never fatal — the alert must not
# add its own failure mode.
if [[ -r "$APP_DIR/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$APP_DIR/.env" 2>/dev/null || true
    set +a
fi

# Framework var: HEADLONG_ first, legacy SHELLM_ fallback (the box .env still
# carries the old name until it is rewritten).
ALERT_CHANNEL="${HEADLONG_ALERT_CHANNEL:-${SHELLM_ALERT_CHANNEL:-}}"
# Posting token: HEADLONG_ALERT_TOKEN (seeded by deploy/split-bridge-env.sh;
# ideally a dedicated alert-only app). The bridge's own token is in
# /etc/shellm/slack.env, which only root can read.
ALERT_TOKEN="${HEADLONG_ALERT_TOKEN:-${SLACK_BOT_TOKEN:-}}"

unit="headlong-thinkers@${IDENT}.service"
info=$(systemctl show "$unit" \
    -p Result,ExecMainStatus,ExecMainExitTimestampMonotonic,ExecMainExitTimestamp 2>/dev/null || true)
log_tail=$(tail -n 8 "$APP_DIR/.identities/$IDENT/run/logs/dispatcher.log" 2>/dev/null || true)

text=":rotating_light: *${unit} failed and auto-restart GAVE UP* — the ${IDENT} dispatcher died repeatedly (start limit: 3 unclean deaths in 15 min) and is STAYING DOWN.
\`\`\`
${info}
--- dispatcher.log tail ---
${log_tail}
\`\`\`
Investigate first, then restart: \`sudo headlong-thinkersctl start ${IDENT}\` on the box."

if [[ -z "$ALERT_TOKEN" || -z "$ALERT_CHANNEL" ]]; then
    printf '%s [thinkers-alert] %s failed; Slack not configured (need HEADLONG_ALERT_TOKEN + HEADLONG_ALERT_CHANNEL in %s/.env)\n' \
        "$(date -u +%FT%TZ)" "$unit" "$APP_DIR" >> "$FALLBACK_LOG"
    exit 0
fi

payload=$(jq -nc --arg ch "$ALERT_CHANNEL" --arg text "$text" \
    '{channel: $ch, text: $text}')
resp=$(curl -sS -m 15 -X POST https://slack.com/api/chat.postMessage \
    -H "Authorization: Bearer $ALERT_TOKEN" \
    -H "Content-Type: application/json; charset=utf-8" \
    --data "$payload" 2>&1 || true)
if ! printf '%s' "$resp" | jq -e '.ok == true' >/dev/null 2>&1; then
    printf '%s [thinkers-alert] Slack post for %s failed: %s\n' \
        "$(date -u +%FT%TZ)" "$unit" "$resp" >> "$FALLBACK_LOG"
fi
