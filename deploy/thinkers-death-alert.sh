#!/usr/bin/env bash
set -euo pipefail

# deploy/thinkers-death-alert.sh — per-death and back-up Slack notices for
# headlong-thinkers@<identity>.service. Companion to
# deploy/thinkers-failure-alert.sh (which, with Restart=on-failure on the
# unit, only fires when auto-restart gives up); this one fires on EVERY
# unclean death and on the recovery:
#
#   ExecStopPost  → thinkers-death-alert.sh APP_DIR IDENT died
#   ExecStartPost → thinkers-death-alert.sh APP_DIR IDENT started
#
# died: systemd sets $SERVICE_RESULT/$EXIT_CODE/$EXIT_STATUS for
# ExecStopPost. Clean stops (SERVICE_RESULT=success) post nothing. Unclean
# deaths post the cause — including which signal the dispatcher trapped
# (run/last_signal, written by _dispatcher_on_signal in bin/thinkers) — and
# drop run/down_since so the next successful start can announce recovery
# with the measured downtime.
#
# started: if run/down_since exists, post the all-clear and remove it;
# otherwise stay silent (normal starts are not news).
#
# Same failure-open contract as thinkers-failure-alert.sh: missing config
# degrades to a line in /var/tmp/headlong-thinkers-alert.log, never a unit
# failure — the alert path must not add its own failure mode on top of a
# dead mind.

APP_DIR="${1:?usage: thinkers-death-alert.sh APP_DIR IDENTITY died|started}"
IDENT="${2:?identity name required}"
MODE="${3:?mode required (died|started)}"

FALLBACK_LOG="/var/tmp/headlong-thinkers-alert.log"
RUN_DIR="$APP_DIR/.identities/$IDENT/run"
unit="headlong-thinkers@${IDENT}.service"

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

post_slack() {
    local text="$1"
    if [[ -z "$ALERT_TOKEN" || -z "$ALERT_CHANNEL" ]]; then
        printf '%s [thinkers-death-alert] %s (%s); Slack not configured (need HEADLONG_ALERT_TOKEN + HEADLONG_ALERT_CHANNEL in %s/.env)\n' \
            "$(date -u +%FT%TZ)" "$unit" "$MODE" "$APP_DIR" >> "$FALLBACK_LOG"
        return 0
    fi
    local payload resp
    payload=$(jq -nc --arg ch "$ALERT_CHANNEL" --arg text "$text" \
        '{channel: $ch, text: $text}')
    resp=$(curl -sS -m 15 -X POST https://slack.com/api/chat.postMessage \
        -H "Authorization: Bearer $ALERT_TOKEN" \
        -H "Content-Type: application/json; charset=utf-8" \
        --data "$payload" 2>&1 || true)
    if ! printf '%s' "$resp" | jq -e '.ok == true' >/dev/null 2>&1; then
        printf '%s [thinkers-death-alert] Slack post for %s (%s) failed: %s\n' \
            "$(date -u +%FT%TZ)" "$unit" "$MODE" "$resp" >> "$FALLBACK_LOG"
    fi
}

case "$MODE" in
    died)
        # systemd's verdict on how the service ended. Manual runs won't have
        # it set — treat unknown as unclean so a real death never goes
        # unreported.
        result="${SERVICE_RESULT:-unknown}"
        if [[ "$result" == "success" ]]; then
            exit 0
        fi

        # Which signal the dispatcher trapped, if its handler got to write
        # the marker. Only trust a marker from THIS death, not one left by
        # an earlier incident.
        sig=""
        if [[ -f "$RUN_DIR/last_signal" ]]; then
            now=$(date +%s)
            mt=$(stat -c %Y "$RUN_DIR/last_signal" 2>/dev/null || echo 0)
            if (( now - mt < 300 )); then
                sig=$(cat "$RUN_DIR/last_signal" 2>/dev/null || true)
            fi
        fi
        log_tail=$(tail -n 6 "$RUN_DIR/logs/dispatcher.log" 2>/dev/null || true)

        date +%s > "$RUN_DIR/down_since" 2>/dev/null || true

        text=":skull_and_crossbones: *${unit} died* — result=${result}, exit=${EXIT_CODE:-?}/${EXIT_STATUS:-?}${sig:+, dispatcher trapped ${sig}}. Auto-restart in ~60s (gives up after 3 unclean deaths in 15 min).
\`\`\`
${log_tail}
\`\`\`"
        post_slack "$text"
        ;;
    started)
        if [[ ! -f "$RUN_DIR/down_since" ]]; then
            exit 0
        fi
        down_since=$(cat "$RUN_DIR/down_since" 2>/dev/null || true)
        rm -f "$RUN_DIR/down_since"
        downtime="unknown"
        if [[ "$down_since" =~ ^[0-9]+$ ]]; then
            secs=$(( $(date +%s) - down_since ))
            downtime="$(( secs / 60 ))m$(( secs % 60 ))s"
        fi
        post_slack ":white_check_mark: *${unit} back up* — down ${downtime}. The wake note covers the gap; queued messages deliver now."
        ;;
    *)
        echo "error: unknown mode: $MODE (want died|started)" >&2
        exit 2
        ;;
esac
