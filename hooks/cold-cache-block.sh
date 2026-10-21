#!/bin/bash
# UserPromptSubmit hook: stop a prompt that would land on an expired prompt
# cache, so it doesn't silently re-write the whole conversation at full price.
#
# The cache is judged from the transcript, the same way Claude Code does for
# prompt_cache_likely_expired: the last main-chain response plus the session's
# cache lifetime (5m or 1h, read from the transcript's cache writes, else from
# the env vars Claude Code reads). Expired → the prompt is blocked with a note
# suggesting a new session. Sending the same prompt again within 30 seconds
# goes through.
#
# Never blocks: machine prompts (keep-alive pings, background-task reports,
# scheduled tasks), slash commands, a session's first prompt, the first prompt
# after a compaction, or headless runs (claude -p / Agent SDK).
#
# Register in ~/.claude/settings.json under hooks.UserPromptSubmit. Reads the
# hook JSON on stdin; always exits 0.

OVERRIDE_SECS=30
in=$(cat)

case "${CLAUDE_CODE_ENTRYPOINT:-}" in sdk-*) exit 0 ;; esac

IFS=$'\x1f' read -r sid transcript prompt <<< "$(jq -r '
  [(.session_id // ""), (.transcript_path // ""), (.prompt // "" | .[0:200] | gsub("[\u001f\n]"; " "))]
  | join("\u001f")' <<< "$in" 2>/dev/null)"

# Only a person's prompt. These prefixes are what keep-alives, background
# reports and the other machine senders put at the start of their prompts.
p="${prompt#"${prompt%%[![:space:]]*}"}"
case "$p" in
  ""|/*|!*|"[cache-warm]"*|"<task-notification"*|"<teammate-message"*|"<cross-session"*|"<channel"*|"<system-reminder"*) exit 0 ;;
esac
[[ "$sid" =~ ^[A-Za-z0-9_-]+$ && -f "$transcript" ]] || exit 0

# The tail is enough unless tool results made the last lines huge; then read it all.
scan() {
  jq -nrR --argjson now "$(date +%s)" '
    def ts: (.timestamp // "") | sub("\\.[0-9]+"; "") | (try fromdateiso8601 catch null);
    reduce (inputs | fromjson? // empty) as $e (
      {last: null, ctx: 0, ttl: null, compact: null};
      if $e.type == "assistant" and $e.message.usage and ($e.isSidechain | not)
         and $e.message.model != "<synthetic>" then
        ($e.message.usage) as $u
        | .last = ($e | ts)
        | .ctx = (($u.input_tokens // 0) + ($u.cache_read_input_tokens // 0) + ($u.cache_creation_input_tokens // 0))
        | .ttl = (if ($u.cache_creation.ephemeral_1h_input_tokens // 0) > 0 then "1h"
                  elif ($u.cache_creation.ephemeral_5m_input_tokens // 0) > 0 then "5m"
                  else .ttl end)
      elif $e.type == "system" and $e.subtype == "compact_boundary" then .compact = ($e | ts)
      else . end)
    | if .last == null then empty
      else "\($now - .last) \(.ctx) \(.ttl // "-") \(if .compact and .compact >= .last then 1 else 0 end)" end'
}
result=$(tail -c 4194304 "$transcript" | scan 2>/dev/null)   # a cut first line just fails to parse
[[ -z "$result" ]] && result=$(scan < "$transcript" 2>/dev/null)
read -r age ctx ttl compacted <<< "$result"
[[ "$age" =~ ^-?[0-9]+$ ]] || exit 0          # no response yet: first prompt
(( compacted )) && exit 0

# Same order as Claude Code: forcing 5m wins, then what the transcript shows, then 1h opt-ins.
if [[ "${FORCE_PROMPT_CACHING_5M:-}" == "1" ]]; then ttl=5m
elif [[ "$ttl" == "-" ]]; then
  [[ "${CLAUDE_CODE_PROMPT_CACHE_TTL:-}" == "1h" || "${ENABLE_PROMPT_CACHING_1H:-}" == "1" ]] && ttl=1h || ttl=5m
fi
ttl_secs=300; [[ "$ttl" == "1h" ]] && ttl_secs=3600
(( age <= ttl_secs )) && exit 0

# Expired. The same prompt sent again within OVERRIDE_SECS goes through.
state_dir="$HOME/.claude/.cold-block"
state="$state_dir/$sid"
now=$(date +%s)
sum=$(jq -r '.prompt // ""' <<< "$in" | cksum | cut -d' ' -f1)
if [[ -s "$state" ]]; then
  read -r b_at b_sum < "$state"
  if [[ "$b_sum" == "$sum" && "$b_at" =~ ^[0-9]+$ ]] && (( now - b_at <= OVERRIDE_SECS )); then
    rm -f "$state"; exit 0
  fi
fi
mkdir -p "$state_dir" 2>/dev/null && printf '%s %s\n' "$now" "$sum" > "$state"
find "$state_dir" -type f -mtime +1 -delete 2>/dev/null

fmt_age() { local s=$1; if (( s >= 3600 )); then echo "$(( s / 3600 ))h $(( s % 3600 / 60 ))m"; else echo "$(( s / 60 ))m"; fi; }
fmt_tok() { awk -v n="$1" 'BEGIN { if (n >= 1e6) printf "%.1fM", n/1e6; else if (n >= 1e3) printf "%.1fk", n/1e3; else printf "%d", n }'; }

reason="Prompt cache expired $(fmt_age "$age") ago ($ttl cache). Sending this would re-write about $(fmt_tok "$ctx") tokens of context at full price.
Cheaper: start a new session (/clear, or a new claude) and pick up from your progress notes.
Your message is back in the input box: press Enter within ${OVERRIDE_SECS} seconds to send it here anyway."

jq -n --arg r "$reason" '{decision: "block", reason: $r}'
exit 0
