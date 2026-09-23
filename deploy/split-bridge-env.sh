#!/usr/bin/env bash
set -euo pipefail

# deploy/split-bridge-env.sh — move the Slack bridge's tokens out of the
# root .env into /etc/shellm/slack.env, which only systemd reads.
#
# Usage: split-bridge-env.sh APP_DIR [BRIDGE_ENV]
#                                   (idempotent; run as root by update.sh
#                                    and the box user_data. BRIDGE_ENV
#                                    defaults to /etc/shellm/slack.env and
#                                    exists for the tests.)
#
# Why. The root .env is sourced into every wake (deploy/thinkers-service.sh),
# so the mind has held the Slack bot and app tokens since day one; on
# 2026-09-14 it copied the whole file into a second identity it created.
# The bridge is the only process that needs those tokens. After this
# split:
#
#   APP_DIR/.env            everything the mind and the dash need: LLM keys,
#                           model names, channel ids, thinker knobs,
#                           HEADLONG_ALERT_TOKEN (see below)
#   /etc/shellm/slack.env   SLACK_BOT_TOKEN and SLACK_APP_TOKEN, root:root
#                           mode 600, loaded by headlong-slack-bridge.service
#                           only. The bridge runs as shellm-slack, not
#                           shellm, so the agent cannot read the tokens out
#                           of the bridge's /proc/<pid>/environ either.
#
# This is the shape Telegram already has (/etc/shellm/telegram.env, a
# separate unit user). An earlier version of this script wrote
# APP_DIR/.env.bridge instead: shellm-owned, and loaded into a bridge that
# ran as shellm. If that file exists its tokens are folded into BRIDGE_ENV
# and it is removed.
#
# The alert scripts (thinkers-death/failure/silence-alert.sh) run inside
# the thinkers unit, so they cannot read the bridge tokens either. They post
# with HEADLONG_ALERT_TOKEN from .env. On first split that is seeded as a
# COPY of the bot token so alerts keep working, with a comment saying so:
# the split is only complete once you replace it with a token from a
# dedicated alert-only Slack app (chat:write to the alert channel). Until
# then a mind that reads .env still holds a token that can post as the
# bot; it just cannot open the Socket Mode connection (that needs the app
# token, which is gone from .env).
#
# The SSM parameter a rebuilt box bootstraps from still holds the full
# file; the box user_data runs this split right after writing .env, so a
# rebuild lands in the same place.

APP_DIR="${1:?usage: split-bridge-env.sh APP_DIR [BRIDGE_ENV]}"
ENV="$APP_DIR/.env"
BRIDGE="${2:-/etc/shellm/slack.env}"
LEGACY="$APP_DIR/.env.bridge"
KEYS="SLACK_BOT_TOKEN SLACK_APP_TOKEN SLACK_CLI_XOXB SLACK_CLI_XAPP"

# Lines that set a bridge key: uncommented KEY=... for any of KEYS.
pattern=""
for k in $KEYS; do pattern="${pattern}${pattern:+|}${k}"; done
bridge_lines() { grep -E "^[[:space:]]*(${pattern})=" "$1" || true; }

# merge_into_bridge LINES — write LINES into BRIDGE, replacing only the keys
# they set, so a re-push with one rotated token propagates it and leaves the
# other tokens as they were.
merge_into_bridge() {
    local lines="$1" keys kp="" k tmpb
    keys=$(printf '%s\n' "$lines" | sed -n 's/^[[:space:]]*\([A-Z_]*\)=.*/\1/p' | sort -u)
    for k in $keys; do kp="${kp}${kp:+|}${k}"; done
    mkdir -p "$(dirname "$BRIDGE")"
    tmpb=$(mktemp "$BRIDGE.XXXXXX")
    if [[ -f "$BRIDGE" ]]; then
        grep -Ev "^[[:space:]]*(${kp})=" "$BRIDGE" > "$tmpb" || true
    else
        printf '# Slack bridge tokens. Loaded by headlong-slack-bridge.service only,\n# which runs as shellm-slack. Written by deploy/split-bridge-env.sh.\n' > "$tmpb"
    fi
    printf '%s\n' "$lines" >> "$tmpb"
    chmod 600 "$tmpb"
    chown root:root "$tmpb" 2>/dev/null || true
    mv "$tmpb" "$BRIDGE"
}

# A bridge file from the earlier layout: fold it in, then remove it.
if [[ -f "$LEGACY" ]]; then
    legacy=$(bridge_lines "$LEGACY")
    [[ -n "$legacy" ]] && merge_into_bridge "$legacy"
    rm -f "$LEGACY"
    echo "split-bridge-env: moved $LEGACY into $BRIDGE"
fi

[[ -f "$ENV" ]] || { echo "split-bridge-env: no $ENV; nothing to do"; exit 0; }

moving=$(bridge_lines "$ENV")
if [[ -z "$moving" ]]; then
    echo "split-bridge-env: no bridge tokens in $ENV; nothing to move"
    exit 0
fi

owner=$(stat -c '%U:%G' "$ENV" 2>/dev/null || stat -f '%Su:%Sg' "$ENV")
stamp=$(date -u +%Y%m%dT%H%M%SZ)
cp -p "$ENV" "$ENV.bak-split-$stamp"

merge_into_bridge "$moving"

# .env: drop the moved lines, seed the alert token if absent.
tmpe=$(mktemp "$APP_DIR/.env.XXXXXX")
grep -Ev "^[[:space:]]*(${pattern})=" "$ENV" > "$tmpe" || true
if ! grep -qE '^[[:space:]]*HEADLONG_ALERT_TOKEN=' "$tmpe"; then
    bot=$(printf '%s\n' "$moving" | sed -n 's/^[[:space:]]*SLACK_BOT_TOKEN=//p' | tail -n 1)
    if [[ -n "$bot" ]]; then
        printf '\n# Slack tokens moved to /etc/shellm/slack.env by deploy/split-bridge-env.sh (%s).\n' "$stamp" >> "$tmpe"
        printf '# HEADLONG_ALERT_TOKEN is what the box alert scripts post with. Seeded as a\n# copy of the bot token; replace it with a dedicated alert-only app token to\n# finish the split (see deploy/split-bridge-env.sh).\n' >> "$tmpe"
        printf 'HEADLONG_ALERT_TOKEN=%s\n' "$bot" >> "$tmpe"
    fi
else
    printf '\n# Slack tokens moved to /etc/shellm/slack.env by deploy/split-bridge-env.sh (%s).\n' "$stamp" >> "$tmpe"
fi
chmod 600 "$tmpe"
chown "$owner" "$tmpe" 2>/dev/null || true
mv "$tmpe" "$ENV"

n=$(printf '%s\n' "$moving" | wc -l | tr -d ' ')
echo "split-bridge-env: moved $n bridge token line(s) to $BRIDGE (backup $ENV.bak-split-$stamp)"
