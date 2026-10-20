#!/bin/bash
# Regenerate the README demo images: renders cc-hud.sh on made-up sessions in
# a throwaway $HOME (fake curl, nothing touches your real ~/.claude), then
# converts the ANSI output to SVG.
#
#   bash demo/render.sh            writes demo/*.svg
#   bash demo/render.sh --print    prints the coloured output to the terminal instead

set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOW=$(date +%s); MS=$((NOW * 1000))
UTF8=$(locale -a 2>/dev/null | grep -iE '^(C|en_US)\.UTF-?8$' | head -1)

scenario() {  # scenario <plan> <stdin jq filter> <usage.json> [setup fn]
  local T; T=$(mktemp -d)
  mkdir -p "$T/.claude" "$T/Work/acme/api"
  git -C "$T/Work/acme/api" init -q && git -C "$T/Work/acme/api" checkout -q -b feat/rate-limits
  printf '{"claudeAiOauth":{"accessToken":"demo","subscriptionType":"%s"}}' "$1" > "$T/.claude/.credentials.json"
  printf '%s' "$3" > "$T/usage.json"
  # A session with a few turns: tokens for line 2, a prompt history for the delta.
  for i in 1 2 3; do
    echo '{"type":"user","promptSource":"typed"}'
    echo "{\"type\":\"assistant\",\"timestamp\":\"2026-10-01T10:00:00Z\",\"message\":{\"id\":\"m$i\",\"model\":\"claude-opus-5-5\",\"usage\":{\"input_tokens\":4,\"output_tokens\":2100,\"cache_read_input_tokens\":410000,\"cache_creation_input_tokens\":21000}}}"
  done > "$T/t.jsonl"
  [[ -n "${4:-}" ]] && "$4" "$T"
  local json
  json=$(jq -nc --arg h "$T" --arg tr "$T/t.jsonl" --argjson now "$NOW" "{
    session_id: \"demo\", transcript_path: \$tr,
    workspace: {current_dir: (\$h + \"/Work/acme/api\")},
    model: {id: \"claude-opus-5-5\", display_name: \"Opus 5.5\"}, effort: {level: \"high\"},
    output_style: {name: \"default\"},
    context_window: {context_window_size: 200000, used_percentage: 38, total_input_tokens: 76000},
    prompt_cache: {ttl: \"5m\", expires_at: (\$now + 212), warm: true, caching_observed: true}
  } | $2")
  # Two earlier prompts at ~\$0.40 each, so this one's \$1.10 shows as a spike.
  mkdir -p "$T/.claude/.prompt-costs"
  printf '0.41\n0.38\n' > "$T/.claude/.prompt-costs/demo.hist"
  echo "3 0.79 0.79" > "$T/.claude/.prompt-costs/demo"
  # Today: $3.20 from earlier sessions, plus whatever this one adds.
  mkdir -p "$T/.claude/.session-costs/.by-day/.cursor" "$T/.claude/.session-costs/.by-day/$(date +%F)"
  echo 0.79 > "$T/.claude/.session-costs/.by-day/.cursor/demo"
  echo 3.20 > "$T/.claude/.session-costs/.by-day/$(date +%F)/earlier.txt"
  run() { env -i HOME="$T" PATH="$ROOT/tests/bin:$PATH" LANG="${UTF8:-C.UTF-8}" TERM=xterm-256color \
            COLORTERM=truecolor STATUSLINE_THEME=dark COLUMNS=150 FAKE_USAGE="$T/usage.json" \
            bash "$ROOT/cc-hud.sh" 9>&1 <<< "$json"; }
  run > /dev/null; run       # first render fetches usage in the background; second shows it
  rm -rf "$T"
}

pro_history() {  # a 5h window that opened 3h ago and has been burning fast for the last hour
  local r=$((NOW + 7200))
  printf '%s\n' "$((NOW-3600)) 31 $r" "$((NOW-2700)) 37 $r" "$((NOW-1800)) 44 $r" "$((NOW-900)) 52 $r" \
    > "$1/.claude/.usage-5h-history"
  mkdir -p "$1/.claude-cache-warm/sessions"
  echo "{\"startedAt\":$((MS-3600000))}" > "$1/.claude-cache-warm/sessions/demo.json"
  echo "{\"waker\":{\"status\":\"sleeping\",\"lastStatus\":\"warming\",\"nextPingAt\":$((MS+174000)),\"heartbeatAt\":$MS},\"pingTimes\":[]}" \
    > "$1/.claude-cache-warm/sessions/demo.state.json"
}

pro=$(scenario max ".cost.total_cost_usd = 1.89
  | .rate_limits = {five_hour: {used_percentage: 58, resets_at: ($NOW + 7200)},
                    seven_day: {used_percentage: 23, resets_at: ($NOW + 3*86400 + 5400)}}" \
  '{"extra_usage":{"is_enabled":false}}' pro_history)

ent_setup() {
  mkdir -p "$1/.claude-cache-warm"   # no plugin: segment stays hidden
}
enterprise=$(scenario enterprise '.cost.total_cost_usd = 1.89
  | .prompt_cache += {misses: 1, miss_recache_tokens: 96000, last_miss_cause: {causes: ["tools_changed"]}}' \
  '{"extra_usage":{"is_enabled":true,"used_credits":18240,"monthly_limit":50000,"decimal_places":2,"utilization":36.5}}' ent_setup)

if [[ "${1:-}" == "--print" ]]; then
  printf '%s\n\n%s\n' "$pro" "$enterprise"; exit 0
fi
python3 "$ROOT/demo/ansi2svg.py" --title "Claude Code · Pro / Max plan" <<< "$pro" > "$ROOT/demo/pro-max.svg"
python3 "$ROOT/demo/ansi2svg.py" --title "Claude Code · Enterprise / usage credits" <<< "$enterprise" > "$ROOT/demo/enterprise.svg"
echo "wrote demo/pro-max.svg demo/enterprise.svg"
