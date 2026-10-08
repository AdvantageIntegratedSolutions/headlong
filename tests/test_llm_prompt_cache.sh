#!/usr/bin/env bash
# test_llm_prompt_cache.sh — Anthropic prompt caching in bin/llm
#
# Usage: tests/test_llm_prompt_cache.sh
#
# curl is stubbed: it keeps the request body and answers with an Anthropic
# response whose usage carries cache reads and writes. Checks that requests
# ask for automatic caching (and LLM_PROMPT_CACHE=0 or another provider does
# not), and that the usage record counts the whole prompt, the part read
# from the cache and the part written to it, streaming and not.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

# --- curl stub ---------------------------------------------------------------
# $USAGE_JSON is the usage object the stub reports.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/curl" <<'EOF'
#!/usr/bin/env bash
out_file="" prev=""
for a in "$@"; do
    [[ "$prev" == "-o" ]] && out_file="$a"
    [[ "$prev" == "-d" ]] && cp "${a#@}" "$PAYLOAD"
    prev="$a"
done
if [[ -n "$out_file" ]]; then
    printf '{"content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","usage":%s}' "$USAGE_JSON" > "$out_file"
    printf '200'
else
    printf 'event: message_start\ndata: {"type":"message_start","message":{"usage":%s}}\n\n' "$USAGE_JSON"
    printf 'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}\n\n'
    printf 'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}\n\n'
    printf 'data: {"type":"content_block_stop","index":0}\n\n'
    printf 'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}\n\n'
    printf 'data: {"type":"message_stop"}\n\n'
fi
EOF
chmod +x "$WORK/bin/curl"
export PATH="$WORK/bin:$PATH"
export ANTHROPIC_API_KEY="test-key" OPENCODE_API_KEY="test-key"
export HEADLONG_HOME="$WORK/home" LLM_USAGE_LEDGER=/dev/null LLM_RETRIES=0
mkdir -p "$HEADLONG_HOME"
export PAYLOAD="$WORK/payload.json" LLM_USAGE_FILE="$WORK/usage.json"

LLM="$REPO/bin/llm"
run_llm() { rm -f "$PAYLOAD" "$LLM_USAGE_FILE"; "$LLM" "$@" "say ok" >/dev/null 2>"$WORK/stderr"; }
usage() { jq -c '{in_tok, out_tok, cache_tok, cache_write_tok}' "$LLM_USAGE_FILE" 2>/dev/null; }

# --- the request ---------------------------------------------------------------
export USAGE_JSON='{"input_tokens":10,"output_tokens":1}'
run_llm -m claude-sonnet-5-5
[[ "$(jq -r '.cache_control.type' "$PAYLOAD" 2>/dev/null)" == ephemeral ]] \
    && ok "anthropic request asks for automatic caching" || bad "anthropic request asks for automatic caching" "$(cat "$PAYLOAD" 2>/dev/null)"

LLM_PROMPT_CACHE=0 run_llm -m claude-sonnet-5-5
[[ "$(jq -r 'has("cache_control")' "$PAYLOAD" 2>/dev/null)" == false ]] \
    && ok "LLM_PROMPT_CACHE=0 leaves it out" || bad "LLM_PROMPT_CACHE=0 leaves it out"

run_llm -m opencode/claude-sonnet-5-5
[[ "$(jq -r 'has("cache_control")' "$PAYLOAD" 2>/dev/null)" == false ]] \
    && ok "opencode (Zen), which shares the builder, does not get it" || bad "opencode (Zen) does not get it" "$(cat "$PAYLOAD" 2>/dev/null)"

# --- the usage record ----------------------------------------------------------
# A later call in a run: 1000 new, 200 written, 3000 read -> whole prompt 4200.
want='{"in_tok":4200,"out_tok":5,"cache_tok":3000,"cache_write_tok":200}'
export USAGE_JSON='{"input_tokens":1000,"cache_creation_input_tokens":200,"cache_read_input_tokens":3000,"output_tokens":5}'
run_llm -m claude-sonnet-5-5
[[ "$(usage)" == "$want" ]] && ok "streaming: whole prompt, reads and writes" || bad "streaming: whole prompt, reads and writes" "$(usage)"

run_llm -m claude-sonnet-5-5 --no-stream
[[ "$(usage)" == "$want" ]] && ok "non-streaming: whole prompt, reads and writes" || bad "non-streaming: whole prompt, reads and writes" "$(usage)"

# A first call: nothing to read yet. The empty read field must not shift the
# write count into its slot.
want='{"in_tok":4200,"out_tok":5,"cache_tok":null,"cache_write_tok":3200}'
export USAGE_JSON='{"input_tokens":1000,"cache_creation_input_tokens":3200,"output_tokens":5}'
run_llm -m claude-sonnet-5-5
[[ "$(usage)" == "$want" ]] && ok "streaming first call: write not mistaken for a read" || bad "streaming first call" "$(usage)"
run_llm -m claude-sonnet-5-5 --no-stream
[[ "$(usage)" == "$want" ]] && ok "non-streaming first call: write not mistaken for a read" || bad "non-streaming first call" "$(usage)"

# No caching at all: unchanged from before.
want='{"in_tok":10,"out_tok":5,"cache_tok":null,"cache_write_tok":null}'
export USAGE_JSON='{"input_tokens":10,"output_tokens":1}'
run_llm -m claude-sonnet-5-5
[[ "$(usage)" == "$want" ]] && ok "no cache fields: record as before" || bad "no cache fields: record as before" "$(usage)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
