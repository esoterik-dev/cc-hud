#!/bin/bash
# cc-hud test suite. Runs the real script the way Claude Code does (JSON on
# stdin, output on stdout) with only the outside world faked: a temporary
# $HOME, and curl / security on PATH. No dependencies beyond the script's own
# (bash, jq) plus python3 for measuring display width.
#
#   bash tests/run.sh            all tests
#   bash tests/run.sh cache      only tests whose name contains "cache"

set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/cc-hud.sh"
FAKES="$ROOT/tests/bin"
pass=0; fail=0; failed=()

# --- Sandbox ---------------------------------------------------------------
new_home() {
  T=$(mktemp -d "${TMPDIR:-/tmp}/cc-hud-test.XXXXXX")
  mkdir -p "$T/.claude" "$T/proj/app"
  git -C "$T/proj/app" init -q -b main 2>/dev/null || git -C "$T/proj/app" init -q
  git -C "$T/proj/app" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  git -C "$T/proj/app" branch -q -M main
  TRANSCRIPT="$T/transcript.jsonl"; : > "$TRANSCRIPT"
  USAGE="$T/usage.json"; echo '{}' > "$USAGE"
}
plan() {  # plan pro|max|enterprise|none: the subscription the credentials file names
  [[ "$1" == none ]] && return
  printf '{"claudeAiOauth":{"accessToken":"test-token-123","subscriptionType":"%s"}}\n' "$1" \
    > "$T/.claude/.credentials.json"
}
NOW=$(date +%s)   # reset before each test: countdown checks assume little time has passed
# Claude Code runs the command in the user's (UTF-8) locale; env -i would drop it.
UTF8=$(locale -a 2>/dev/null | grep -iE '^(C|en_US)\.UTF-?8$' | head -1)
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }

# Base stdin; each test layers its own fields on with a jq filter.
base_json() {
  jq -n --arg home "$T" --arg tr "$TRANSCRIPT" '{
    session_id: "sess-1", transcript_path: $tr,
    workspace: {current_dir: ($home + "/proj/app")},
    model: {id: "claude-opus-5-5", display_name: "Opus 5.5"},
    output_style: {name: "default"},
    cost: {total_cost_usd: 1.234},
    context_window: {context_window_size: 200000, used_percentage: 42, total_input_tokens: 84000}
  }'
}

# render [jq-filter] — runs the script once. fd 9 is held open by the script's
# background fetch, so the capture waits for it: no sleeps, no races.
render() {
  local filter=${1:-.}
  OUT=$(base_json | jq -c "$filter" | env -i HOME="$T" PATH="$FAKES:$PATH" \
        LANG="${UTF8:-C.UTF-8}" TERM=xterm FAKE_USAGE="$USAGE" ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} \
        ${WRAP[@]+"${WRAP[@]}"} bash "$SCRIPT" 9>&1)
  STATUS=$?
  PLAIN=$(printf '%s' "$OUT" | sed $'s/\x1b\\[[0-9;]*m//g')
}
with() {  # with VAR=val... -- render ...: environment for that one render
  EXTRA_ENV=(); while [[ "$1" != "--" ]]; do EXTRA_ENV+=("$1"); shift; done; shift
  "$@"; EXTRA_ENV=()
}
# Plain renders share one parent process, like one running Claude Code. A
# render through new_process gets a parent of its own, like a resumed session.
new_process() {
  WRAP=(python3 -c 'import subprocess, sys; sys.exit(subprocess.call(sys.argv[1:], pass_fds=(9,)))')
  "$@"; WRAP=()
}
render_raw() {  # render_raw <stdin text>
  OUT=$(printf '%s' "$1" | env -i HOME="$T" PATH="$FAKES:$PATH" bash "$SCRIPT" 9>&1 2>/dev/null)
  STATUS=$?
  PLAIN=$(printf '%s' "$OUT" | sed $'s/\x1b\\[[0-9;]*m//g')
}

# --- Assertions ------------------------------------------------------------
_ok=1
check()   { if ! "$@"; then _ok=0; printf '    ✗ %s\n' "$*"; fi; }
has()     { [[ "$PLAIN" == *"$1"* ]] || { printf '      expected: %s\n      in:\n%s\n' "$1" "$(sed 's/^/        /' <<< "$PLAIN")"; return 1; }; }
lacks()   { [[ "$PLAIN" != *"$1"* ]] || { printf '      unexpected: %s\n      in:\n%s\n' "$1" "$(sed 's/^/        /' <<< "$PLAIN")"; return 1; }; }
matches() { grep -Eq -- "$1" <<< "$PLAIN" || { printf '      no line matches /%s/ in:\n%s\n' "$1" "$(sed 's/^/        /' <<< "$PLAIN")"; return 1; }; }
exit0()   { [[ $STATUS -eq 0 ]] || { printf '      exit status %s\n' "$STATUS"; return 1; }; }
line()    { sed -n "${1}p" <<< "$PLAIN"; }

assistant() {  # assistant <msg-id> <in> <out> <cache-read> <cache-write>: one transcript entry
  jq -nc --arg id "$1" --argjson i "$2" --argjson o "$3" --argjson r "$4" --argjson w "$5" \
    '{type:"assistant", timestamp:"2026-10-01T10:00:00Z",
      message:{id:$id, model:"claude-opus-5-5", usage:{input_tokens:$i, output_tokens:$o,
      cache_read_input_tokens:$r, cache_creation_input_tokens:$w}}}' >> "$TRANSCRIPT"
}
prompt() { echo '{"type":"user","promptSource":"typed","message":{"content":"hi"}}' >> "$TRANSCRIPT"; }

# ===========================================================================
# Every render, whatever the input, exits 0 (Claude Code blanks the line otherwise)
# ===========================================================================
legend_within_5s() {  # legend_within_5s <flag>: macOS has no timeout(1)
  local out="$T/legend.out" pid i
  yes | bash "$SCRIPT" "$1" > "$out" & pid=$!
  for ((i = 0; i < 50; i++)); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  if kill -0 "$pid" 2>/dev/null; then kill "$pid"; STATUS=124; else wait "$pid"; STATUS=$?; fi
  OUT=$(<"$out"); PLAIN=$OUT
}
test_legend_exits_without_reading_stdin() {
  # --legend must not wait on stdin: an endless pipe would hang a reader.
  legend_within_5s --legend
  check exit0; check has "what each glyph means"; check has "Config"
  legend_within_5s -l
  check exit0
}
test_empty_and_garbage_input_still_exit_0() {
  render_raw '{}';          check exit0
  render_raw 'not json at all'; check exit0
  render_raw '';            check exit0
}

# ===========================================================================
# Line 1: dir | git | model | style | context
# ===========================================================================
test_line1_basics() {
  plan enterprise; render
  check exit0
  check has "📁 ~/proj/app"
  check has "🌿 main"
  check has "🤖 Opus 5.5"
  check has "🧠"
  check has "42%"
  check lacks "🎨"            # default output style is hidden
}
test_effort_and_output_style_shown() {
  plan enterprise; render '.effort = {level:"high"} | .output_style.name = "Explanatory"'
  check has "Opus 5.5 (high)"
  check has "🎨 Explanatory"
}
test_branch_hidden_outside_repo() {
  plan enterprise; mkdir -p "$T/plain"
  render ".workspace.current_dir = \"$T/plain\""
  check lacks "🌿"
}
test_long_path_collapses_middle() {
  plan enterprise; mkdir -p "$T/a/b/c/d"
  render ".workspace.current_dir = \"$T/a/b/c/d\""
  check has "~/…/c/d"
}
test_context_bar_colour_thresholds() {
  plan enterprise
  render '.context_window.used_percentage = 30';  check grep -q $'\e\\[32m█' <<< "$OUT"   # green < 50
  render '.context_window.used_percentage = 65';  check grep -q $'\e\\[33m█' <<< "$OUT"   # yellow < 80
  render '.context_window.used_percentage = 90';  check grep -Eq $'\e\\[[39]1m█' <<< "$OUT" # red above
}
test_context_falls_back_to_transcript() {
  # Older client / first frame: no context_window on stdin.
  plan enterprise; assistant m1 10 5 100000 0
  render 'del(.context_window)'
  check exit0; check has "50%"                 # 100000 of the 200k default
}

# ===========================================================================
# Line 2: session $ [+prompt] | day | month | tokens
# ===========================================================================
test_token_breakdown_dedupes_streamed_messages() {
  # A message is written several times while it streams; only the last counts.
  plan enterprise
  assistant m1 3 10 1000 500
  assistant m1 3 40 1000 500     # same id, final snapshot
  assistant m2 2 60 2000 0
  render
  check has "↓ 5"; check has "✎ 500"; check has "↑ 100"; check has "⚡3.0k"
}
test_truncated_transcript_keeps_last_good_totals() {
  plan enterprise; assistant m1 3 40 1000 500
  render; check has "↑ 40"
  printf '{"type":"assistant","message":{"id":"m2",' >> "$TRANSCRIPT"   # mid-write
  render; check exit0; check has "↑ 40"
}
test_session_cost_dollar_vs_plan_estimate() {
  plan enterprise; render; check has "💵 \$1.23"
  new_home; plan pro;  render; check has "💵 ≈\$1.23"
}
test_prompt_delta_and_spike_flag() {
  plan enterprise
  prompt; assistant m1 1 1 0 0
  render '.cost.total_cost_usd = 0.5'
  check has "📄 +\$0.50"                       # prompt 1: the whole session so far
  prompt
  render '.cost.total_cost_usd = 0.5'          # submitted, nothing spent yet
  check lacks "📄"                              # hidden at $0.00
  render '.cost.total_cost_usd = 2.5'
  check has "📄 +\$2.00 ↑300%"                  # 4x the previous prompt
}
test_prompt_delta_can_be_hidden() {
  plan enterprise; prompt
  with PROMPT_DELTA=0 -- render; check lacks "📄"
}
test_daily_spend_is_always_an_estimate() {
  plan enterprise; render; check has "🕰️ ~\$"
  with DAILY_COST=0 -- render; check lacks "🕰️"
}

# ===========================================================================
# Usage endpoint: month spend (credits) and plan-limit windows
# ===========================================================================
test_enterprise_month_spend_from_endpoint() {
  plan enterprise
  echo '{"extra_usage":{"is_enabled":true,"used_credits":12345,"monthly_limit":50000,"decimal_places":2,"utilization":24.69}}' > "$USAGE"
  render            # first render starts the background fetch
  render            # second render reads what it cached
  check has "📅 \$123.45/\$500"
  check has "💰"; check matches '25%/⏳[0-9]+%'
  check lacks "🔥"  # never a burn forecast on Enterprise
}
test_endpoint_gets_token_only_and_token_never_stored() {
  plan enterprise; echo '{}' > "$USAGE"; render
  check grep -q "https://api.anthropic.com/api/oauth/usage" "$T/curl.log"
  check grep -q "Authorization: Bearer test-token-123" "$T/curl.log"
  check bash -c "! grep -rl test-token-123 '$T/.claude' --exclude=.credentials.json"
}
test_endpoint_called_at_most_every_5_minutes() {
  plan enterprise; echo '{}' > "$USAGE"
  render; render; render
  check [ "$(wc -l < "$T/curl.log")" -eq 1 ]
}
test_endpoint_unreachable_falls_back_to_local_estimate() {
  plan enterprise
  with FAKE_CURL=fail -- render
  with FAKE_CURL=fail -- render
  check exit0
  check matches '📅 ~\$[0-9]+\.[0-9]{2}'
}
test_no_token_means_no_request() {
  plan none; render
  check exit0; check [ ! -e "$T/curl.log" ]
}
test_pro_plan_windows() {
  plan pro
  render ".rate_limits = {five_hour:{used_percentage:40, resets_at:$((NOW+7200))},
                          seven_day:{used_percentage:8,  resets_at:$((NOW+3*86400))}}"
  check exit0
  check matches '^📁.*⌚ 5h .*40%/⏳[0-9]+% 📟 [0-9]+h[0-9]+m 📥 '
  check matches '^📅 wk .*8%/⏳[0-9]+% ⏲️ [0-9]+d[0-9]+h 🔄 '
  check lacks "💰"            # no month-budget bar on a plan without credits
}
test_pro_plan_windows_from_endpoint_when_stdin_lacks_them() {
  plan pro
  printf '{"five_hour":{"utilization":55,"resets_at":"%s"},"seven_day":{"utilization":20,"resets_at":"%s"},"extra_usage":{"is_enabled":false}}' \
    "$(iso $((NOW+3600)))" "$(iso $((NOW+86400)))" > "$USAGE"
  render; render
  check matches '⌚ 5h .*55%'
  check matches '📅 wk .*20%'
}
test_burn_forecast_on_pro() {
  plan pro
  # 5h window opened 3h ago; usage climbed 20% → 70% over the last hour,
  # fast enough to run out well before the reset 2h from now.
  { echo "$((NOW-3600)) 20 $((NOW+7200))"; echo "$((NOW-1800)) 45 $((NOW+7200))"; } > "$T/.claude/.usage-5h-history"
  render ".rate_limits = {five_hour:{used_percentage:70, resets_at:$((NOW+7200))}}"
  check matches '^🔥 5h [0-9.]+%/h'
  check has "hits 100% ~"
  check matches '[0-9]+% chance to run out'
}
test_burn_limit_reached() {
  plan max
  render ".rate_limits = {five_hour:{used_percentage:100, resets_at:$((NOW+600))}}"
  check has "🔥 5h limit reached · back at"
}
test_no_burn_forecast_on_enterprise() {
  plan enterprise
  { echo "$((NOW-3600)) 20 $((NOW+7200))"; } > "$T/.claude/.usage-5h-history"
  render ".rate_limits = {five_hour:{used_percentage:40, resets_at:$((NOW+7200))}}"
  check lacks "🔥"
  check has "5h 40%"           # shown inline on line 2 instead
}

# ===========================================================================
# Line 3: cache TTL, verdict, cache-warm, misses
# ===========================================================================
test_cache_ttl_countdown() {
  plan enterprise
  render ".prompt_cache = {ttl:\"5m\", expires_at:$((NOW+200)), warm:true, caching_observed:true}"
  check matches '⏱️ 5m · 3m [0-9]+s left'
}
test_cache_cold() {
  plan enterprise
  render ".prompt_cache = {ttl:\"1h\", expires_at:$((NOW-5)), warm:false, caching_observed:true}"
  check has "⏱️ 1h ·  cold"
}
test_cache_ttl_before_first_prompt_and_hidden() {
  plan enterprise
  render '.prompt_cache = {ttl:"1h"}'; check has "1h · waiting for first prompt"
  with STATUSLINE_CACHE_TTL=0 -- render ".prompt_cache = {ttl:\"5m\", expires_at:$((NOW+200)), warm:true, caching_observed:true}"
  check lacks "⏱️"
}
test_verdict_resume_and_new_session() {
  plan enterprise
  local pc="{ttl:\"5m\", expires_at:$((NOW+200)), warm:true, caching_observed:true}"
  render ".prompt_cache = $pc | .context_window.total_input_tokens = 20000";  check has "▶ resume"
  render ".prompt_cache = $pc | .context_window.total_input_tokens = 900000"; check has "↻ new session"
  with STATUSLINE_VERDICT=0 -- render ".prompt_cache = $pc"; check lacks "▶"
}
test_cache_misses() {
  plan enterprise
  render '.prompt_cache = {caching_observed:true, misses:2, miss_recache_tokens:150000, last_miss_cause:{causes:["ttl_expired_5m"]}}'
  check has "✗ 2 misses · 150.0k rewritten (ttl)"
  render '.prompt_cache = {caching_observed:true, misses:0}'; check lacks "✗"
}

# After a resume Claude Code sends prompt_cache: null until the first new
# request, so the cache state comes from the transcript instead.
test_resumed_session_counts_down_from_the_transcript() {
  plan enterprise; reply 130
  render 'del(.prompt_cache)'
  check matches '⏱️ 5m · 2m [0-9]+s left'
  check has "▶ resume"
  check lacks "waiting for first prompt"
  rm -rf "$T/.claude/.token-cache"; : > "$TRANSCRIPT"; reply 400 1h   # another session file, same size
  render '.prompt_cache = null'
  check matches '⏱️ 1h · 5[0-9]m left'
}
test_resumed_session_shows_cold_from_the_transcript() {
  plan enterprise; reply 400
  render 'del(.prompt_cache)'
  check has "⏱️ 5m ·  cold"
  check has "↻ new session"             # 84k context on a cold cache
  rm -rf "$T/.claude/.token-cache"; : > "$TRANSCRIPT"; reply 130 1h
  with FORCE_PROMPT_CACHING_5M=1 -- render 'del(.prompt_cache)'; check matches '5m · 2m [0-9]+s left'
}
test_resume_estimate_yields_to_stdin_and_compaction() {
  plan enterprise; reply 400
  render ".prompt_cache = {ttl:\"5m\", expires_at:$((NOW+200)), warm:true, caching_observed:true}"
  check matches '⏱️ 5m · 3m [0-9]+s left'      # Claude Code's own state wins
  jq -nc --arg ts "$(iso $((NOW - 100)))" '{type:"system", subtype:"compact_boundary", timestamp:$ts}' >> "$TRANSCRIPT"
  render '.prompt_cache = {ttl:"5m"}'
  check has "5m · waiting for first prompt"   # compacted since: that cache is gone
  check lacks "▶"
}
test_cache_misses_survive_a_resume() {
  plan enterprise
  local pc='.prompt_cache = {caching_observed:true, requests:6, misses:2, miss_recache_tokens:150000, last_miss_cause:{causes:["ttl_expired_5m"]}}'
  render "$pc"; render "$pc"                   # the same process, rendered twice
  check has "✗ 2 misses · 150.0k rewritten (ttl)"
  new_process render 'del(.prompt_cache)'      # resumed: nothing from Claude Code yet
  check has "✗ 2 misses · 150.0k rewritten (ttl)"
  new_process render '.prompt_cache = {caching_observed:true, requests:1, misses:1, miss_recache_tokens:10000, last_miss_cause:{causes:["tools_changed"]}}'
  check has "✗ 3 misses · 160.0k rewritten (tools)"
  render '.prompt_cache = {caching_observed:true, requests:9, misses:3, miss_recache_tokens:200000, last_miss_cause:{causes:["ttl_expired_5m"]}}'
  check has "✗ 4 misses · 210.0k rewritten (ttl)"   # the first process moved on: its line, not a new one
  render '.session_id = "sess-2" | .prompt_cache = {caching_observed:true, misses:0}'
  check lacks "✗"                                    # other sessions don't share the ledger
  with STATUSLINE_CACHE_MISSES=0 -- render 'del(.prompt_cache)'; check lacks "✗"
}
test_cache_misses_keep_a_reused_process_id_apart() {
  plan enterprise
  render '.prompt_cache = {caching_observed:true, requests:6, misses:2, miss_recache_tokens:150000}'
  # Same parent process id, but its counters went back: a new process that got the old id.
  render '.prompt_cache = {caching_observed:true, requests:1, misses:1, miss_recache_tokens:5000}'
  check has "✗ 3 misses · 155.0k rewritten"
}
test_cache_warm_plugin_segment() {
  plan enterprise
  local d="$T/.claude-cache-warm/sessions" ms=$((NOW*1000))
  mkdir -p "$d"
  echo "{\"startedAt\":$((ms-600000))}" > "$d/sess-1.json"
  echo "{\"waker\":{\"status\":\"sleeping\",\"lastStatus\":\"warming\",\"nextPingAt\":$((ms+90000)),\"heartbeatAt\":$ms},\"pingTimes\":[$((ms-1000))]}" > "$d/sess-1.state.json"
  render; check matches '♨ ping in 1m [0-9]+s · 1 sent'
  echo "{\"waker\":{\"status\":\"done\",\"exitReason\":\"idle-cap\",\"exitedAt\":$ms},\"pingTimes\":[$((ms-2000)),$((ms-1000))]}" > "$d/sess-1.state.json"
  render; check has "♨ stopped after 2 (cap)"
}

# ===========================================================================
# Config file and glyphs
# ===========================================================================
test_emoji_off() {
  plan enterprise; with STATUSLINE_EMOJI=0 -- render
  check has "[~/proj/app]"; check lacks "📁"
}
test_config_file_and_env_priority() {
  plan enterprise
  echo "STATUSLINE_EMOJI=0" > "$T/.claude/statusline.conf"
  render; check has "[~/proj/app]"
  with STATUSLINE_EMOJI=1 -- render; check has "📁"     # env wins over the file
}
test_every_legend_key_works_from_config_file() {
  # --legend lists these as settable "env var, or ~/.claude/statusline.conf".
  plan enterprise
  printf '%s\n' DAILY_COST=0 > "$T/.claude/statusline.conf"
  render; check lacks "🕰️"
  printf '%s\n' STATUSLINE_GLYPH_DAY=TODAY > "$T/.claude/statusline.conf"
  render; check has "TODAY ~\$"
}
test_config_file_is_parsed_not_sourced() {
  plan enterprise
  printf '%s\n' "touch $T/pwned1" "STATUSLINE_EMOJI=\$(touch $T/pwned2)" "PATH=/nowhere" \
    > "$T/.claude/statusline.conf"
  render
  check exit0; check [ ! -e "$T/pwned1" ]; check [ ! -e "$T/pwned2" ]; check has "Opus 5.5"
}
test_budget_bar_styles_and_off() {
  plan enterprise
  echo '{"extra_usage":{"is_enabled":true,"used_credits":10000,"monthly_limit":50000,"decimal_places":2,"utilization":20}}' > "$USAGE"
  render; render; check has "💰"
  with BUDGET_BAR_STYLE=off -- render; check lacks "💰"
  with BUDGET_BAR_STYLE=dual -- render; check matches '\$[█░]+ ⏱'
  with BUDGET_BAR_LINE=2 -- render; check matches '^💵.*💰'
}

# ===========================================================================
# Narrow terminals wrap between segments instead of cropping
# ===========================================================================
width_ok() {  # every row fits $1 columns (emoji counted 2 wide)
  python3 -c '
import sys, unicodedata
lim = int(sys.argv[1]); bad = 0
for row in sys.stdin.read().splitlines():
    w = sum(0 if unicodedata.category(c) in ("Mn","Me","Cf") or c == "️" else
            2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in row)
    if w > lim: print("      %d cols: %s" % (w, row)); bad = 1
sys.exit(bad)' "$1" <<< "$PLAIN"
}
test_narrow_terminal_wraps() {
  plan pro
  local f=".effort = {level:\"high\"} | .rate_limits = {five_hour:{used_percentage:40, resets_at:$((NOW+7200))}, seven_day:{used_percentage:8, resets_at:$((NOW+3*86400))}}"
  render "$f"; local wide_rows; wide_rows=$(wc -l <<< "$PLAIN")
  with COLUMNS=50 -- render "$f"
  check exit0; check width_ok 48
  check [ "$(wc -l <<< "$PLAIN")" -gt "$wide_rows" ]
}
valid_utf8() { iconv -f UTF-8 -t UTF-8 <<< "$OUT" > /dev/null 2>&1 || { printf '      output is not valid UTF-8\n'; return 1; }; }
test_wrap_without_utf8_locale() {
  plan pro
  local f=".effort = {level:\"high\"} | .rate_limits = {five_hour:{used_percentage:40, resets_at:$((NOW+7200))}, seven_day:{used_percentage:8, resets_at:$((NOW+3*86400))}}"
  with LANG=C COLUMNS=50 -- render "$f"
  check exit0; check valid_utf8; check width_ok 48
}

# ===========================================================================
# Odd input
# ===========================================================================
test_missing_output_style_shows_no_segment() {
  render 'del(.output_style)'; check exit0; check lacks "🎨"
  render '.output_style = null'; check lacks "🎨"
}
test_unsafe_session_id_stays_inside_claude_dir() {
  plan pro
  render '.session_id = "../../escaped"'
  check exit0; check has "Opus 5.5"
  check [ ! -e "$T/escaped" ]; check [ ! -e "$T/escaped.txt" ]
  check [ -z "$(find "$T" -path "$T/.claude" -prune -o -path "$T/proj" -prune -o -name 'escaped*' -print)" ]
}

# ===========================================================================
# hooks/question-guard.sh — PostToolUse(AskUserQuestion)
# ===========================================================================
hook() {  # hook <script> <stdin json>: runs a hook as Claude Code does
  OUT=$(printf '%s' "$2" | env -i HOME="$T" PATH="$PATH" LANG="${UTF8:-C.UTF-8}" \
        ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} bash "$ROOT/hooks/$1" 2>/dev/null)
  STATUS=$?; PLAIN=$OUT
}
blocked()  { [[ "$(jq -r .decision <<< "$OUT" 2>/dev/null)" == block ]] || { printf '      not blocked; output: %s\n' "$OUT"; return 1; }; }
allowed()  { [[ -z "$OUT" ]] || { printf '      expected no output, got: %s\n' "$OUT"; return 1; }; }
reason_has()   { jq -r .reason <<< "$OUT" | grep -qF -- "$1" || { printf '      reason lacks: %s\n%s\n' "$1" "$(jq -r .reason <<< "$OUT")"; return 1; }; }
reason_lacks() { ! jq -r .reason <<< "$OUT" | grep -qF -- "$1" || { printf '      reason has: %s\n' "$1"; return 1; }; }
auq() {  # auq <answers-json>: PostToolUse input for two questions
  jq -nc --argjson a "$1" '{hook_event_name:"PostToolUse", tool_name:"AskUserQuestion",
    tool_input:{questions:[{question:"Colour?",options:[{label:"red"},{label:"blue"}]},
                           {question:"Finish?",options:[{label:"matte"},{label:"gloss"}]}]},
    tool_response:{answers:$a}}'
}
test_guard_lets_answered_questions_through() {
  hook question-guard.sh "$(auq '{"Colour?":"red","Finish?":"gloss"}')"
  check exit0; check allowed
}
test_guard_blocks_a_timed_out_question() {
  hook question-guard.sh "$(auq '{}')"
  check exit0; check blocked
  check reason_has "Do not proceed"; check reason_has "End your turn"
  check reason_has "- Colour? (options: red / blue)"; check reason_has "- Finish? (options: matte / gloss)"
}
test_guard_keeps_partial_answers() {
  hook question-guard.sh "$(auq '{"Colour?":"blue"}')"
  check blocked
  check reason_has "- Finish? (options: matte / gloss)"
  check reason_has "- Colour? → blue"
  check reason_lacks "- Colour? (options"
}
test_guard_ignores_bad_input() {
  hook question-guard.sh 'not json'; check exit0; check allowed
  hook question-guard.sh '{}';       check exit0; check allowed
}

# ===========================================================================
# hooks/cold-cache-block.sh — UserPromptSubmit
# ===========================================================================
reply() {  # reply <seconds ago> [5m|1h]: a main-chain response in the transcript
  local k=ephemeral_5m_input_tokens; [[ "${2:-5m}" == 1h ]] && k=ephemeral_1h_input_tokens
  jq -nc --arg ts "$(iso $((NOW - $1)))" --arg k "$k" '{type:"assistant", timestamp:$ts,
    message:{model:"claude-opus-5-5", usage:{input_tokens:3, cache_read_input_tokens:148000,
    cache_creation_input_tokens:2000, cache_creation:{($k):2000}}}}' >> "$TRANSCRIPT"
}
ups() {  # ups <prompt>: UserPromptSubmit input for this session
  jq -nc --arg p "$1" --arg tr "$TRANSCRIPT" '{hook_event_name:"UserPromptSubmit",
    session_id:"sess-1", transcript_path:$tr, prompt:$p}'
}
test_cold_block_allows_a_warm_cache() {
  reply 120; hook cold-cache-block.sh "$(ups "next step")"
  check exit0; check allowed
}
test_cold_block_blocks_an_expired_cache() {
  reply 400; hook cold-cache-block.sh "$(ups "next step")"
  check exit0; check blocked
  check reason_has "Prompt cache expired 6m ago (5m cache)"
  check reason_has "about 150.0k tokens"
  check reason_has "within 30 seconds"
}
test_cold_block_uses_the_1h_lifetime() {
  reply 400 1h;  hook cold-cache-block.sh "$(ups "next")"; check allowed
  : > "$TRANSCRIPT"; reply 3700 1h; hook cold-cache-block.sh "$(ups "next")"
  check blocked; check reason_has "(1h cache)"
  : > "$TRANSCRIPT"; reply 400 1h
  with FORCE_PROMPT_CACHING_5M=1 -- hook cold-cache-block.sh "$(ups "forced")"; check blocked
}
test_cold_block_resend_within_30s_goes_through() {
  reply 400
  hook cold-cache-block.sh "$(ups "do it")";    check blocked
  hook cold-cache-block.sh "$(ups "other")";    check blocked     # a different prompt is a new block
  hook cold-cache-block.sh "$(ups "other")";    check allowed     # the same one again: through
  hook cold-cache-block.sh "$(ups "do it")";    check blocked
  echo "$((NOW - 31)) $(printf 'do it' | cksum | cut -d' ' -f1)" > "$T/.claude/.cold-block/sess-1"
  hook cold-cache-block.sh "$(ups "do it")";    check blocked     # too late: blocked again
}
test_cold_block_never_blocks_machine_prompts_or_commands() {
  reply 400
  local p
  for p in "[cache-warm] Keep-alive ping to refresh the prompt cache." \
           "<task-notification><summary>Stop hook feedback</summary></task-notification>" \
           "<system-reminder>x</system-reminder>" "/clear" "/compact" "!ls" "   " ; do
    hook cold-cache-block.sh "$(ups "$p")"; check allowed
  done
}
test_cold_block_skips_first_prompt_compaction_and_headless() {
  hook cold-cache-block.sh "$(ups "hello")"; check allowed               # no response yet
  reply 400
  jq -nc --arg ts "$(iso $((NOW - 100)))" '{type:"system", subtype:"compact_boundary", timestamp:$ts}' >> "$TRANSCRIPT"
  hook cold-cache-block.sh "$(ups "go on")"; check allowed               # compacted since
  : > "$TRANSCRIPT"; reply 400
  with CLAUDE_CODE_ENTRYPOINT=sdk-cli -- hook cold-cache-block.sh "$(ups "go on")"; check allowed
}
test_cold_block_rejects_odd_session_ids() {
  reply 400
  hook cold-cache-block.sh "$(ups "x" | jq -c '.session_id = "../../evil"')"
  check allowed; check [ ! -e "$T/.claude/evil" ]
}
test_cold_block_reads_huge_transcripts() {
  # A tool result bigger than the 4 MB tail: the response line falls outside it.
  reply 400
  head -c 5000000 /dev/zero | tr '\0' 'x' | jq -Rc '{type:"user", message:{content:.}}' >> "$TRANSCRIPT"
  hook cold-cache-block.sh "$(ups "next")"; check blocked
}

# ===========================================================================
for t in $(declare -F | awk '{print $3}' | grep '^test_' | grep -- "${1:-}"); do
  new_home; EXTRA_ENV=(); WRAP=(); _ok=1; NOW=$(date +%s)
  "$t"
  if (( _ok )); then pass=$((pass+1)); printf '✓ %s\n' "${t#test_}"
  else fail=$((fail+1)); failed+=("$t"); printf '✗ %s\n' "${t#test_}"; fi
  rm -rf "$T"
done
printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
