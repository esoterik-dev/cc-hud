#!/bin/bash
# Claude Code statusLine (official client):
#   line 1: dir | git | model | style | ctx bar | [5h window, plan-limit accounts]
#   burn:   5h burn rate (range), likely time it runs out, chance it runs out
#           before the reset (Pro/Max/Free only, once there is history)
#   line 2: session $ [+this prompt] | month $ | [plan usage] | tokens
#           tokens = fresh in / cache write / out / cache read, the four
#           disjoint usage components. Showing only fresh input would hide
#           the cache-write slice, which is often a third of the spend.
#   week:   wk bar, used, ⏲️ left, 🔄 reset time (plan-limit accounts only; the
#           5h window, with 📟 left and 📥 reset, ends line 1)
#   line 3: [cache TTL + verdict] | [cache-warm] | [cache misses] (omitted when empty)
#           cache TTL = time left before the current warm prefix goes cold, or
#           "cold" once it has — so you know whether to send the next request
#           now or it'll pay a full rewrite. Requires client v2.1.251+.
# Any row too wide for the terminal ($COLUMNS, which the client keeps current
# across resizes) wraps between segments instead of being cropped.
#
# Data sources, in order of authority:
#   1. GET /api/oauth/usage       server-side month-to-date usage-credit spend.
#      Same source /usage and claude.ai/settings/usage read, so it is the only
#      figure that matches the bill. Covers every device and every product
#      (Code, chat, Cowork), not just this machine. Auth: the session's own
#      claude.ai OAuth token from the Keychain — no admin key needed.
#      Undocumented client endpoint: verify the field names after a CC upgrade.
#   2. context_window.* / rate_limits.*   official, from stdin.
#   3. cost.total_cost_usd        NOT official — Claude Code computes it locally
#      from token counts at *list* rates, ignoring contracted discounts, and
#      only for this machine. Fine for a per-session gauge, wrong for a bill.
# The local .session-costs aggregation is now only a labelled fallback (~$) for
# when the usage endpoint is unreachable. It undercounts: sessions that never
# render a statusline (headless/worktree agents) are never recorded, and a
# session is filed under its first-activity month rather than by usage date.

# --- Config ---
# Env vars win; ~/.claude/statusline.conf supplies persistent defaults as plain
# KEY=value lines. The file is parsed, never sourced, so a typo in it cannot
# execute anything. Resolved here, above everything, so the glyph block and
# --legend both see the same values.
conf_file="$HOME/.claude/statusline.conf"
if [[ -f "$conf_file" ]]; then
  while IFS='=' read -r ck cv; do
    ck="${ck//[[:space:]]/}"; cv="${cv%%#*}"; cv="${cv//[\"\' ]/}"
    [[ -z "$cv" ]] && continue
    # Allowlist, so a stray line in the conf file can never assign PATH, IFS, etc.
    # Only set when the env var is unset, keeping env at higher priority.
    case "$ck" in
      BUDGET_BAR_STYLE|BUDGET_BAR_LINE|BUDGET_BAR_WIDTH|STATUSLINE_EMOJI|\
      STATUSLINE_GLYPH_IN|STATUSLINE_GLYPH_OUT|STATUSLINE_GLYPH_CACHE|\
      STATUSLINE_GLYPH_PROMPT|STATUSLINE_GLYPH_WRITE|STATUSLINE_GLYPH_TTL|\
      STATUSLINE_CACHE_TTL|STATUSLINE_VERDICT|STATUSLINE_CACHE_MISSES|STATUSLINE_CACHE_WARM|\
      STATUSLINE_FRESH_CTX|STATUSLINE_RESTART_COST_5M|STATUSLINE_RESTART_COST_1H|\
      STATUSLINE_BURST_QUICK|STATUSLINE_BURST_TASK|STATUSLINE_THEME|\
      PROMPT_DELTA|PROMPT_DELTA_SPIKE|PROMPT_DELTA_WINDOW)
        [[ -z "${!ck}" ]] && printf -v "$ck" '%s' "$cv"
        ;;
    esac
  done < <(grep -E '^[[:space:]]*(BUDGET_BAR_[A-Z_]+|STATUSLINE_[A-Z_]+|PROMPT_DELTA[A-Z_]*)=' "$conf_file" 2>/dev/null)
fi

# --- Theme: the muted colour for labels, glyphs and separators, and red ---
# Bright black (90) is soft grey on a light background but nearly invisible on
# a dark one, where bright white (97) stays readable. Red (31) is likewise too
# dark there, so dark uses bright red (91). Unset: follow
# COLORFGBG ("fg;bg", bg 0-6 or 8 = dark) when the terminal sets it, else light.
case "${STATUSLINE_THEME:-}" in
  dark)  dim=97 ;;
  light) dim=90 ;;
  *)     bg="${COLORFGBG##*;}"; dim=90
         [[ "$bg" =~ ^[0-9]+$ ]] && (( bg <= 6 || bg == 8 )) && dim=97 ;;
esac
red=31; (( dim == 97 )) && red=91
# Plan-limit text: Claude Code's own rate-limit/permission colour for the theme
# (dark rgb(177,185,249), light rgb(87,105,247)), 24-bit when the terminal says
# it can, else the nearest 256-colour.
case "$COLORTERM" in truecolor|24bit) truecolor=1 ;; *) truecolor=0 ;; esac
if (( dim == 97 )); then
  (( truecolor )) && lim_sgr="38;2;177;185;249" || lim_sgr="38;5;147"
else
  (( truecolor )) && lim_sgr="38;2;87;105;247" || lim_sgr="38;5;63"
fi

# --- Glyphs ---
# Emoji anchors so each segment says what it is. STATUSLINE_EMOJI=0 restores the
# original text/arrow glyphs for terminals that render emoji at odd widths.
if [[ "${STATUSLINE_EMOJI:-1}" == "0" ]]; then
  g_dir="";    d_open="["; d_close="]"
  g_branch=""; g_model="✨"; g_style=""
  g_ctx="";    g_spend="\$"; g_time=""; g_hour=""; g_week=""
  g_sess="";   g_month="mo"; g_day="dy"; g_in="↓"; g_out="↑"; g_cache="⚡"; g_write="✎"
  g_prompt=""; g_ttl=""; g_mest="mo"
else
  g_dir="📁";  d_open="";  d_close=""
  g_branch="🌿"; g_model="🤖"; g_style="🎨"
  g_ctx="🧠";  g_spend="💰"; g_time="⏳"; g_hour="⌚"; g_week="📅"
  g_sess="💵"; g_month="📅"; g_day="🕰️"; g_in="↓"; g_out="↑"; g_cache="⚡"; g_write="✎"
  g_prompt="📄"; g_ttl="⏱️"; g_mest="💳"
fi
g_warm="♨"

# Token-direction glyphs stay plain arrows by default: direction is unambiguous,
# they cost 1 column instead of 2, and they can't mis-render over SSH. Emoji
# trays (📥/📤) were dropped because the two are near-identical at this size.
g_in="${STATUSLINE_GLYPH_IN:-$g_in}"
g_out="${STATUSLINE_GLYPH_OUT:-$g_out}"
g_cache="${STATUSLINE_GLYPH_CACHE:-$g_cache}"
g_write="${STATUSLINE_GLYPH_WRITE:-$g_write}"
g_prompt="${STATUSLINE_GLYPH_PROMPT:-$g_prompt}"
g_ttl="${STATUSLINE_GLYPH_TTL:-$g_ttl}"
g_day="${STATUSLINE_GLYPH_DAY:-$g_day}"

# --- --legend: explain every glyph, then exit. Must run before stdin is read,
# --- otherwise an interactive invocation blocks forever on `cat`.
if [[ "$1" == "--legend" || "$1" == "-l" ]]; then
  b=$'\033[1m'; d=$'\033['"$dim"'m'; z=$'\033[0m'
  cat <<LEGEND
${b}Claude Code status line — what each glyph means${z}

${b}Line 1${z}
  ${g_dir}  working directory
  ${g_branch}  git branch ${d}(hidden outside a repo)${z}
  ${g_model}  active model
  ${g_style}  output style ${d}(hidden when default)${z}
  ${g_ctx}  context window used — bar + %. ${d}green <50, yellow <80, red above${z}
      ${d}As this fills, older turns get compacted away. /clear starts fresh.${z}
  ${g_spend}  budget pacing — this month's usage-credit spend vs the month itself
      ${d}█ spent    ┃ where the month is now    ░ month remaining${z}
      ${d}Fill LEFT of ┃ = under pace (green). Fill CROSSING ┃ = over pace (red).${z}
  ${g_time}  % of the month's ${b}working days${z} elapsed ${d}(the ┃ position, as a number)${z}
      ${d}Mon–Fri only, counted per month (20–23 days), so pacing measures the${z}
      ${d}days you actually spend credits on. The tick creeps through a weekday${z}
      ${d}and holds still all weekend — a quiet Saturday won't read as falling${z}
      ${d}behind. It can hit 100% before the last of the month if that tail is${z}
      ${d}a weekend.${z}

${b}Lines 2–3${z} ${d}(cache TTL, verdict, cache-warm and misses on line 3)${z}
  ${g_sess}  this session's cost ${d}(local estimate at list rates; ≈ on a plan)${z}
  ${g_prompt}  what the CURRENT prompt has added to that session total
      ${d}Re-anchored each time you submit a prompt, so it answers "what is${z}
      ${d}this turn costing me", not "what has the session cost".${z}
      ${d}↑/↓ N% appears only when this prompt is N% above/below the mean${z}
      ${d}of the last few prompts — a spike flag, quiet when you're on trend.${z}
      ${d}Works from the very first finished prompt; the average widens to${z}
      ${d}PROMPT_DELTA_WINDOW prompts as the session goes on.${z}
  ${g_day}  today's spend ${d}(local estimate; always ~, see below)${z}
      ${d}There is no official daily figure — /usage reports by month — so${z}
      ${d}this is summed locally and always carries a leading ~.${z}
      ${d}Each render banks only the increase since the render before it, so${z}
      ${d}a session left open past midnight, or resumed days later, splits${z}
      ${d}across the days it actually spent in. Starts from the moment the${z}
      ${d}feature was installed; it cannot backfill. DAILY_COST=0 hides it.${z}
  ${g_month}  month-to-date credit spend / your monthly limit
      ${d}Official — same source as /usage. A leading ~ means that source was${z}
      ${d}unreachable and you're seeing a local estimate instead.${z}
  ${d}Input splits into three disjoint parts that together are everything${z}
  ${d}you sent. All three are shown, because they bill at different rates:${z}
  ${g_in}  fresh input ${d}— the uncached remainder, billed 1x. With caching on this${z}
      ${d}is usually tiny (a couple of tokens per request); that is expected,${z}
      ${d}not a bug. The bulk of your input is ${g_write} and ${g_cache}.${z}
  ${g_write}  cache-write tokens ${d}— context newly written to cache. The priciest${z}
      ${d}slice per token (1.25x base for a 5-minute TTL, 2x for an hour).${z}
  ${g_cache}  cache-read tokens ${d}(cheap re-reads of context already sent — 0.1x;${z}
      ${d}0.05x on Opus 5.5, 0.025x on Fable/Mythos 5.1)${z}
  ${g_ttl}  cache TTL + time left before the ${b}current${z} warm prefix goes cold
      ${d}green: plenty of time left · yellow: getting close · red: about to${z}
      ${d}expire. Shows ${b}cold${z} on a red background once it has — the next request${z}
      ${d}pays a full rewrite instead of a cheap read. Hidden until this session${z}
      ${d}has shown any cache activity, or on clients before v2.1.251 (no${z}
      ${d}prompt_cache field). STATUSLINE_CACHE_TTL=0 hides it unconditionally.${z}
  ▶ ◐ ↻  resume-or-restart verdict for the selected model and cache state
      ${d}▶ resume       cheaper to keep going in this session${z}
      ${d}◐ quick only   resume for a quick follow-up (≤8 requests); start a new${z}
      ${d}               session from your progress notes for a full task${z}
      ${d}↻ new session  a fresh session from your progress notes is cheaper${z}
      ${d}               (shown on a red background, like ${z}${b}cold${z}${d})${z}
      ${d}(ctx/limit) = current context / the threshold it was judged against.${z}
      ${d}STATUSLINE_VERDICT=0 hides it.${z}
  ✗  cache misses this session + tokens they re-wrote, with the last cause
      ${d}(ttl, tools, system, model, rewrite, server, ?). Compactions don't${z}
      ${d}count — those are expected rebuilds. Hidden at 0.${z}
      ${d}STATUSLINE_CACHE_MISSES=0 hides it.${z}
  ${g_warm}  claude-cache-warm keep-alive: next ping countdown + pings sent since${z}
      ${d}you were last active; "stopped after N (cap)" once it gives up, so the${z}
      ${d}cache goes cold next. Hidden without the plugin, or while it has nothing${z}
      ${d}to warm. STATUSLINE_CACHE_WARM=0 hides it.${z}
  ${g_out}  output tokens this session ${d}(what Claude generated)${z}
  ${d}5h / wk    plan-limit windows, shown only when the client reports them${z}

${b}Plan-limit accounts${z} ${d}(Pro/Max/Free, or usage credits turned off)${z}
  The 5-hour window ends line 1 and the weekly window gets its own row
  ${d}(together they replace ${g_spend} month pacing and ${g_month} month spend):${z}
  ${g_hour} 5h ███┃░░ 40%/${g_time}38% 📟 3h8m 📥 6:40 PM
  ${g_week} wk █░░░┃░  8%/${g_time}78% ⏲️ 1d14h 🔄 Wed 9:30 AM
      ${d}fill = window used, ┃ / ${g_time} = how far through the window you are.${z}
      ${d}Fill crossing ┃ = you'll hit the cap before it resets.${z}
      ${d}📟 / ⏲️ time left, 📥 / 🔄 local time it resets (day added if not today).${z}
      ${d}Drawn in Claude Code's own rate-limit colour for the theme.${z}
  🔥 5h 14%/h (9–22) · hits 100% ~5:55 PM (5:10 PM–7:20 PM) · 71% chance to run out
      ${d}Pro/Max/Free only (never Enterprise), on the row under line 1. Burn rate${z}
      ${d}of the 5h window, measured over several look-backs (10m–90m, and since${z}
      ${d}the window opened at 0%): median, then (slowest–fastest). "hits 100% ~" is${z}
      ${d}when the median rate hits 100%, with the range the fastest and slowest${z}
      ${d}give; "lasts till reset" when the median doesn't get there. The chance is${z}
      ${d}the share of look-backs that run out before the reset. Range and chance${z}
      ${d}appear once there are two estimates; usage % is sampled into${z}
      ${d}~/.claude/.usage-5h-history on each change and at least every 5 min.${z}
  ${g_mest}  month-to-date spend at API list price ${d}(local estimate, this machine${z}
      ${d}only; a session counts in the month it started; refreshed every 5 min)${z}
  ≈\$  dollar figures are what this usage would cost on the API at list
      ${d}prices, not what you are billed. A plan with usage credits turned on${z}
      ${d}also gets the ${g_month} month spend and its bar, as on Enterprise.${z}

${b}Narrow terminals${z} ${d}— a row wider than the terminal wraps between segments${z}
  ${d}(a leading │ or · is dropped on the new row); follows a resize at the next refresh.${z}

${b}Config${z} ${d}— env var, or ~/.claude/statusline.conf as KEY=value lines${z}
  BUDGET_BAR_STYLE=marker|banded|dual|off   ${d}marker: fill + month tick${z}
                                            ${d}banded: sizes the gap instead${z}
                                            ${d}dual:   two separate bars${z}
  BUDGET_BAR_LINE=1|2|3                     ${d}which row the budget bar sits on${z}
  BUDGET_BAR_WIDTH=20                       ${d}cells; min 6${z}
  STATUSLINE_EMOJI=0                        ${d}text glyphs instead of emoji${z}
  STATUSLINE_THEME=light|dark               ${d}muted-text and red colours for your terminal background${z}
                                            ${d}(unset: COLORFGBG if set, else light)${z}
  STATUSLINE_GLYPH_IN=↓                     ${d}override the token glyphs${z}
  STATUSLINE_GLYPH_OUT=↑
  STATUSLINE_GLYPH_CACHE=⚡
  STATUSLINE_GLYPH_WRITE=✎
  STATUSLINE_GLYPH_PROMPT=📄                ${d}the per-prompt delta glyph${z}
  STATUSLINE_GLYPH_TTL=⏱️                    ${d}override the cache-TTL glyph${z}
  STATUSLINE_GLYPH_DAY=🕰️                    ${d}override the daily-spend glyph${z}
  STATUSLINE_CACHE_TTL=0                    ${d}hide the cache-TTL segment${z}
  STATUSLINE_VERDICT=0                      ${d}hide the resume-or-restart verdict${z}
  STATUSLINE_CACHE_MISSES=0                 ${d}hide the cache-miss counter${z}
  STATUSLINE_CACHE_WARM=0                   ${d}hide the cache-warm keep-alive segment${z}
  STATUSLINE_FRESH_CTX=50000                ${d}verdict: context of a freshly restarted session${z}
  STATUSLINE_RESTART_COST_5M=60000          ${d}verdict: restart cost (input-token equivalents), 5m TTL${z}
  STATUSLINE_RESTART_COST_1H=85000          ${d}verdict: restart cost, 1h TTL${z}
  STATUSLINE_BURST_QUICK=8                  ${d}verdict: requests in a quick follow-up${z}
  STATUSLINE_BURST_TASK=17                  ${d}verdict: requests in a full task${z}
  DAILY_COST=0                              ${d}hide today's spend${z}
  PROMPT_DELTA=0                            ${d}hide the per-prompt delta${z}
  PROMPT_DELTA_SPIKE=25                     ${d}±% deviation before ↑/↓ shows${z}
  PROMPT_DELTA_WINDOW=5                     ${d}prompts averaged for the baseline${z}
LEGEND
  exit 0
fi

input=$(cat)

# --- Portability: GNU (Linux) vs BSD (macOS) stat/date ---
if stat --version >/dev/null 2>&1; then gnu_tools=1; else gnu_tools=0; fi
file_size()  { if (( gnu_tools )); then stat -c %s "$1"; else stat -f %z "$1"; fi; }
file_mtime() { if (( gnu_tools )); then stat -c %Y "$1"; else stat -f %m "$1"; fi; }
# The session's claude.ai OAuth token: Keychain on macOS, a plain file elsewhere.
creds_file="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json"
oauth_token() {
  if command -v security >/dev/null 2>&1; then
    security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null
  else
    cat "$creds_file" 2>/dev/null
  fi | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null
}

# --- Every scalar field pulled from stdin, in ONE jq call ---
# Was ~15 separate `echo | jq` invocations. Each jq process-startup is cheap in
# isolation, but with refreshInterval re-running this every second across every
# open session on the machine, that per-call overhead multiplies into render
# times that can exceed the 1-second tick — Claude Code then cancels the
# in-flight render before it prints anything, which is what a blank/stale
# status line looks like. One call amortizes the startup cost across all
# fields. Joined on \x1f (unit separator, never a legitimate field value)
# rather than @tsv/plain-space, because bash `read` collapses runs of the
# *whitespace* IFS characters (space/tab/newline) and would misalign every
# variable after the first absent field — \x1f isn't whitespace, so `read`
# keeps empty fields as empty fields instead of swallowing the delimiter.
IFS=$'\x1f' read -r cwd model_name model_id output_style effort_level transcript session_id \
  session_cost_in ctx_max ctx_pct ctx_tok rl5_pct rl7_pct rl5_reset rl7_reset \
  pc_ttl pc_expires pc_warm pc_observed pc_misses pc_miss_tok pc_miss_cause <<< "$(
  echo "$input" | jq -r '
  # resets_at -> epoch seconds, whether it arrives as epoch s/ms or ISO-8601.
  def ep: if type == "number" then (if . > 1e12 then . / 1000 else . end | floor)
          elif type == "string" then (try (sub("\\.[0-9]+"; "") | sub("(\\+00:00|Z)$"; "Z") | fromdateiso8601) catch "")
          else "" end;
  [
    (.workspace.current_dir // ""),
    (.model.display_name // ""),
    (.model.id // ""),
    (.output_style.name // ""),
    (.effort.level // ""),
    (.transcript_path // ""),
    (.session_id // ""),
    (.cost.total_cost_usd // 0),
    (.context_window.context_window_size // ""),
    (.context_window.used_percentage // ""),
    (.context_window.total_input_tokens // ""),
    (.rate_limits.five_hour.used_percentage // ""),
    (.rate_limits.seven_day.used_percentage // ""),
    (.rate_limits.five_hour.resets_at | ep),
    (.rate_limits.seven_day.resets_at | ep),
    (.prompt_cache.ttl // ""),
    (.prompt_cache.expires_at // ""),
    (.prompt_cache.warm // false),
    (.prompt_cache.caching_observed // false),
    (.prompt_cache.misses // 0),
    (.prompt_cache.miss_recache_tokens // 0),
    (.prompt_cache.last_miss_cause.causes[0]? // "")
  ] | join("")'
)"

# prompt_cache.ttl only arrives after the first request; until then fall back
# to the env vars Claude Code reads (inherited by this process). 5M wins.
if [[ -z "$pc_ttl" ]]; then
  if [[ -n "$FORCE_PROMPT_CACHING_5M" ]]; then pc_ttl="5m"
  else pc_ttl="${CLAUDE_CODE_PROMPT_CACHE_TTL:-}"
  fi
fi

session_cost=$(awk -v c=$session_cost_in 'BEGIN { printf "%.2f", c }')

# --- Git branch ---
git_branch=""
if git -C "$cwd" rev-parse --git-dir > /dev/null 2>&1; then
  git_branch=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null \
            || git -C "$cwd" rev-parse --short HEAD 2>/dev/null)
fi

# --- Cumulative session tokens (for the line-2 breakdown) ---
# context_window.* is the current context snapshot, not the session total, so the
# breakdown still comes from the transcript. The transcript writes each message
# multiple times (streaming snapshots / resumes), so we dedupe by message.id and
# keep the final snapshot per id — otherwise the totals are ~2-3x inflated.
# The prompt counter rides along in the same pass: a submitted prompt is the
# only user entry carrying .promptSource ("typed", a slash command, a paste),
# so counting those is an exact turn index. Meta entries, tool results and
# sub-agent (sidechain) traffic all leave it null.
#
# This is by far the most expensive step in the script (a full jq -rs parse of
# the whole transcript) — cheap on the old event-driven triggers, but with
# refreshInterval re-running this every second regardless of whether anything
# changed, it can take longer than the tick itself on a large transcript (or
# under load from several concurrent sessions each polling their own), and
# Claude Code cancels an in-flight render when the next tick fires — which
# reads as the segment (or the whole status line) intermittently going blank
# or stale. So: skip the reparse entirely unless the transcript's size changed
# since the last render, keyed per session under ~/.claude/.token-cache/.
tok_cache="$HOME/.claude/.token-cache/${session_id:-unknown}"
tok_sig=""
# The v2: prefix invalidates cache files written before last_ctx was added.
[[ -n "$transcript" && -f "$transcript" ]] && tok_sig="v2:$(file_size "$transcript" 2>/dev/null)"

in_tok=0; out_tok=0; cr_tok=0; cw_tok=0; n_prompt=0; last_ctx=""
cached_sig=""
if [[ -n "$tok_sig" && -s "$tok_cache" ]]; then
  read -r cached_sig in_tok out_tok cr_tok cw_tok n_prompt last_ctx < "$tok_cache" 2>/dev/null
fi

if [[ -n "$transcript" && -f "$transcript" && "$cached_sig" != "$tok_sig" ]]; then
  # A session actively streaming can grow the transcript mid-write; jq -rs
  # slurps the whole file, so a partially-flushed trailing line makes the
  # *entire* parse fail (not just that line). The old always-recompute design
  # just self-healed on the next render; caching means a failed parse must
  # NOT be written as truth, or it freezes at 0 until the file size next
  # changes — fall back to whatever was already cached instead.
  tok_line=$(jq -rs '
      ([.[] | select(.type=="assistant" and .message.usage)]
       | group_by(.message.id)
       | map(max_by(.message.usage.output_tokens // 0))) as $m |
      [ ($m | map(.message.usage.input_tokens            // 0) | add // 0),
        ($m | map(.message.usage.output_tokens           // 0) | add // 0),
        ($m | map(.message.usage.cache_read_input_tokens // 0) | add // 0),
        ($m | map(.message.usage.cache_creation_input_tokens // 0) | add // 0),
        ([.[] | select(.promptSource != null and (.isSidechain | not))] | length),
        # Live context = the last main-chain request, not the session sums above.
        ([.[] | select(.type=="assistant" and .message.usage and (.isSidechain | not)
                       and .message.model != "<synthetic>")] | last | .message.usage
         | ((.input_tokens // 0) + (.cache_read_input_tokens // 0)
            + (.cache_creation_input_tokens // 0))) // 0
      ] | @tsv
    ' "$transcript" 2>/dev/null)
  if [[ $? -eq 0 && -n "$tok_line" ]]; then
    read -r in_tok out_tok cr_tok cw_tok n_prompt last_ctx <<< "$tok_line"
    in_tok=${in_tok:-0}; out_tok=${out_tok:-0}; cr_tok=${cr_tok:-0}
    cw_tok=${cw_tok:-0}; n_prompt=${n_prompt:-0}; last_ctx=${last_ctx:-0}
    mkdir -p "$HOME/.claude/.token-cache" 2>/dev/null
    printf '%s %s %s %s %s %s %s\n' "$tok_sig" "$in_tok" "$out_tok" "$cr_tok" "$cw_tok" "$n_prompt" "$last_ctx" > "$tok_cache" 2>/dev/null
  fi
fi

# --- Fallbacks if stdin lacked context_window (older client / first frame) ---
if [[ -z "$ctx_max" || "$ctx_max" == "0" ]]; then
  if [[ "$model_id" == *"1m"* || "$model_id" == *"[1m]"* ]]; then ctx_max=1000000; else ctx_max=200000; fi
fi
[[ -z "$ctx_tok" && "$last_ctx" =~ ^[0-9]+$ ]] && ctx_tok=$last_ctx
if [[ -z "$ctx_pct" ]]; then
  ctx_pct=$(awk -v c=$ctx_tok -v m=$ctx_max 'BEGIN { printf "%d", (c/m)*100 }')
fi
pct=$(awk -v p=$ctx_pct 'BEGIN { printf "%d", p }')

# --- Persist this session's official cost, tagged by its first-activity month ---
# Stored as: ~/.claude/.session-costs/<YYYY-MM>/<session_id>.txt
# Using the session's first-activity month (not today) keeps a session in the
# month it started even if reopened later.
costs_root="$HOME/.claude/.session-costs"
if [[ -n "$session_id" && -n "$transcript" && -f "$transcript" ]] && \
   awk -v c=$session_cost_in 'BEGIN { exit !(c > 0) }'; then
  # The first-activity month never changes for a session's lifetime, so once
  # known it's cached instead of re-running a full-transcript jq scan on every
  # render — the other thing (besides the token breakdown) refreshInterval
  # turned from "once per event" into "once per second".
  month_cache="$costs_root/.month-cache/$session_id"
  if [[ -s "$month_cache" ]]; then
    session_month=$(<"$month_cache")
  else
    session_month=$(jq -rs '
        [.[] | select(.type=="assistant" and .timestamp) | .timestamp] | first // empty
      ' "$transcript" 2>/dev/null | cut -c1-7)
    if [[ -n "$session_month" ]]; then
      mkdir -p "$costs_root/.month-cache"
      printf '%s' "$session_month" > "$month_cache"
    fi
  fi
  if [[ -n "$session_month" ]]; then
    mkdir -p "$costs_root/$session_month"
    printf "%s" "$session_cost_in" > "$costs_root/$session_month/$session_id.txt"
  fi
fi

# --- Today's spend, accrued incrementally ---
# There is no official daily figure (the usage endpoint reports by month), so
# this is summed locally from cost.total_cost_usd and always rendered with a
# leading ~. Bucketing a session by the day it *started* — the way the monthly
# aggregation does — would misfile every session left open past midnight or
# resumed later, so instead each render banks only the increase since the
# render before it, into whichever day that increase actually landed in.
#   .by-day/.cursor/<session_id>      last cost observed for this session
#   .by-day/<YYYY-MM-DD>/<sid>.txt    what this session accrued on that day
day_root="$costs_root/.by-day"
if [[ "${DAILY_COST:-1}" != "0" && -n "$session_id" ]]; then
  day_cursor="$day_root/.cursor/$session_id"
  dc_last=""
  [[ -s "$day_cursor" ]] && read -r dc_last < "$day_cursor"
  [[ "$dc_last" =~ ^[0-9]+(\.[0-9]+)?$ ]] || dc_last=""

  if [[ -z "$dc_last" ]]; then
    # Never seen this session (or its cursor was pruned): seed at the current
    # total. Anything spent before now belongs to days we can't reconstruct,
    # so claiming it for today would be worse than starting from zero.
    mkdir -p "$day_root/.cursor" 2>/dev/null
    printf '%s' "$session_cost_in" > "$day_cursor"
  elif awk -v c="$session_cost_in" -v l="$dc_last" 'BEGIN { exit !(c > l) }'; then
    dc_bucket="$day_root/$(date +%F)/$session_id.txt"
    mkdir -p "$day_root/$(date +%F)" 2>/dev/null
    dc_acc=0
    [[ -s "$dc_bucket" ]] && read -r dc_acc < "$dc_bucket"
    [[ "$dc_acc" =~ ^[0-9]+(\.[0-9]+)?$ ]] || dc_acc=0
    awk -v a="$dc_acc" -v c="$session_cost_in" -v l="$dc_last" \
        'BEGIN { printf "%.6f", a + (c - l) }' > "$dc_bucket"
    printf '%s' "$session_cost_in" > "$day_cursor"
  elif awk -v c="$session_cost_in" -v l="$dc_last" 'BEGIN { exit !(c < l) }'; then
    # /clear, or a fresh session reusing the id. Re-seed; never subtract from
    # a day that has already been banked.
    printf '%s' "$session_cost_in" > "$day_cursor"
  fi
fi

# --- Per-prompt cost delta + spike detection ---
# cost.total_cost_usd is cumulative for the session, and the status line
# re-renders many times per turn, so a "since last render" delta would just be
# noise. Instead we anchor a baseline at each prompt boundary and report
# cost_now - baseline: what THIS prompt has added so far.
#
# State, per session, under ~/.claude/.prompt-costs/
#   <session_id>       "<prompt_index> <baseline_cost> <last_seen_cost>"
#   <session_id>.hist  one finished prompt's delta per line (last 20 kept)
#
# The index is re-derived from the transcript on every render, so a skipped
# render or a deleted state file self-corrects instead of drifting forever.
#
# Why the third field: n_prompt comes from the transcript (it moves the instant
# you hit enter) but cost.total_cost_usd is pushed by the client and only moves
# on an API-response boundary — and no render fires between the two. So the
# first render of a turn already has the turn's first response billed into
# cost, and anchoring at that value swallows it. A single-response turn then
# has base == cost for its whole life and reports $0.00 forever, while a
# tool-heavy turn merely under-reports. Anchoring instead at the cost we
# observed on the *previous* render keeps that first response in the turn it
# belongs to.
pd_enabled="${PROMPT_DELTA:-1}"
pd_spike="${PROMPT_DELTA_SPIKE:-25}"
pd_window="${PROMPT_DELTA_WINDOW:-5}"
[[ "$pd_spike"  =~ ^[0-9]+$ ]] || pd_spike=25
[[ "$pd_window" =~ ^[0-9]+$ ]] && (( pd_window >= 1 )) || pd_window=5

pd_root="$HOME/.claude/.prompt-costs"
pd_delta=""; pd_dir=""; pd_dev=""
if [[ "$pd_enabled" != "0" && -n "$session_id" && -n "$transcript" && -f "$transcript" ]]; then
  pd_state="$pd_root/$session_id"
  pd_hist="$pd_root/$session_id.hist"
  mkdir -p "$pd_root" 2>/dev/null

  pd_n=""; pd_base=""; pd_last=""
  [[ -s "$pd_state" ]] && read -r pd_n pd_base pd_last < "$pd_state"
  # A truncated or hand-edited state file must not poison the arithmetic.
  # pd_last is also absent on a state file written by an older version.
  [[ "$pd_n"    =~ ^[0-9]+$            ]] || pd_n=""
  [[ "$pd_base" =~ ^[0-9]+(\.[0-9]+)?$ ]] || pd_base=""
  [[ "$pd_last" =~ ^[0-9]+(\.[0-9]+)?$ ]] || pd_last=""
  pd_on_disk=$(printf '%s %s %s' "$pd_n" "$pd_base" "$pd_last")

  if [[ -z "$pd_n" || -z "$pd_base" ]]; then
    # First render we've ever seen for this session. On prompt 1 the whole
    # session cost IS this prompt's cost, so anchor at 0. Joining a session
    # already in progress (a resume, or the file was pruned), we can't know
    # what the current prompt has spent already, so anchor at "now" and
    # under-report this one turn rather than inherit the session's history.
    pd_n=$n_prompt
    if (( n_prompt <= 1 )); then pd_base=0; else pd_base=$session_cost_in; fi
  elif (( n_prompt > pd_n )); then
    # A new prompt was submitted: bank the finished one, then re-anchor.
    # The boundary is the previous render's cost, not the current one — see
    # the note on pd_last above. Fall back to "now" only when we have no
    # carried value (state written by an older version of this script).
    pd_boundary=${pd_last:-$session_cost_in}
    if awk -v c="$pd_boundary" -v b="$pd_base" 'BEGIN { exit !(c > b) }'; then
      awk -v c="$pd_boundary" -v b="$pd_base" 'BEGIN { printf "%.6f\n", c - b }' >> "$pd_hist"
      if (( $(wc -l < "$pd_hist" 2>/dev/null || echo 0) > 20 )); then
        tail -20 "$pd_hist" > "$pd_hist.$$" && mv -f "$pd_hist.$$" "$pd_hist"
      fi
    fi
    pd_n=$n_prompt; pd_base=$pd_boundary
  fi

  # Cost moving backwards means /clear or a fresh session reusing the id.
  # Re-anchor rather than render a negative delta.
  if awk -v c="$session_cost_in" -v b="$pd_base" 'BEGIN { exit !(c < b) }'; then
    pd_base=0
  fi

  # One write per render covers every branch above and carries this render's
  # cost forward to be the next turn's anchor. Skipped when nothing moved, so
  # a quiet render doesn't churn the file.
  pd_line=$(printf '%s %s %s' "$pd_n" "$pd_base" "$session_cost_in")
  if [[ "$pd_line" != "$pd_on_disk" ]]; then
    printf '%s\n' "$pd_line" > "$pd_state"
  fi

  pd_raw=$(awk -v c="$session_cost_in" -v b="$pd_base" 'BEGIN { d=c-b; printf "%.6f", (d>0 ? d : 0) }')
  pd_delta=$(awk -v d="$pd_raw" 'BEGIN { printf "%.2f", d }')

  # Spike flag: compare against the mean of the last N *finished* prompts.
  # Silent while on trend, so the arrow only ever means "look at this".
  # One finished prompt is enough of a baseline to compare against — the
  # average simply widens toward PROMPT_DELTA_WINDOW as the session goes on.
  if [[ "$pd_delta" != "0.00" && -s "$pd_hist" ]]; then
    read -r pd_dir pd_dev < <(
      tail -n "$pd_window" "$pd_hist" \
      | awk -v d="$pd_raw" -v t="$pd_spike" '
          { s += $1; n++ }
          END {
            if (n == 0 || s <= 0) exit
            p = (d / (s/n) - 1) * 100
            if      ( p >= t) printf "up %d",    p + 0.5
            else if (-p >= t) printf "down %d", -p + 0.5
          }'
    )
  fi
fi

# --- Month-to-date spend (official, cached; refreshed in background every 5 min) ---
# The usage endpoint is rate limited, so never call it inline on a render.
month=$(date +%Y-%m)
spend_cache="$HOME/.claude/.usage-spend"          # "<used> <limit> <pct>"
cache_file="$HOME/.claude/.monthly-cost-$month"   # fallback: local list-rate sum

cache_age_of() {
  if [[ -f "$1" ]]; then echo $(( $(date +%s) - $(file_mtime "$1" 2>/dev/null || echo 0) ))
  else echo 999999; fi
}

limits_cache="$HOME/.claude/.usage-limits"        # "<spend_on> <5h_pct> <5h_reset> <wk_pct> <wk_reset>"
usage_stamp="$HOME/.claude/.usage-fetch"          # last fetch attempt, success or not

# Throttled on the attempt, not on success: a plan with spending off never
# writes $spend_cache, and keying on it would hit the endpoint every render.
if [[ $(cache_age_of "$usage_stamp") -gt 300 ]]; then
  : > "$usage_stamp" 2>/dev/null
  (
    tok=$(oauth_token)
    [[ -z "$tok" ]] && exit 0
    resp=$(curl -sf --max-time 5 "https://api.anthropic.com/api/oauth/usage" \
         -H "Authorization: Bearer $tok" \
         -H "anthropic-beta: oauth-2025-04-20" 2>/dev/null) || exit 0
    # Plan-limit windows (Pro/Max; Enterprise may report them too). "-" keeps
    # the space-separated fields aligned when a window is absent.
    tmp="$limits_cache.$$"
    jq -r 'def ep: if type == "string" then (try (sub("\\.[0-9]+"; "") | sub("(\\+00:00|Z)$"; "Z") | fromdateiso8601) catch "-") else "-" end;
           [ (if (.extra_usage.is_enabled != false or .spend.enabled == true) then 1 else 0 end),
             (.five_hour.utilization // "-"), (.five_hour.resets_at | ep),
             (.seven_day.utilization // "-"), (.seven_day.resets_at | ep) ] | map(tostring) | join(" ")' \
      <<< "$resp" > "$tmp" 2>/dev/null
    if [[ -s "$tmp" ]]; then mv -f "$tmp" "$limits_cache"; else rm -f "$tmp"; fi
    # Spending turned off (Pro/Max without usage credits) still reports
    # spend.used = 0. That is not a budget, so drop any stale figure instead.
    if [[ "$(jq -r '.extra_usage.is_enabled != false or .spend.enabled == true' <<< "$resp")" == "false" ]]; then
      rm -f "$spend_cache"; exit 0
    fi
    tmp="$spend_cache.$$"
    jq -r '(.extra_usage.used_credits // .spend.used.amount_minor) as $u
               | select($u != null)
               | [ $u,
                   (.extra_usage.monthly_limit // .spend.limit.amount_minor // 0),
                   (.extra_usage.decimal_places // .spend.used.exponent // 2),
                   (.extra_usage.utilization    // .spend.percent        // 0) ] | @tsv' <<< "$resp" \
      | awk -F'\t' 'NF>=4 { d=10^$3; printf "%.2f %.0f %d\n", $1/d, $2/d, int($4+0.5) }' \
      > "$tmp" 2>/dev/null
    if [[ -s "$tmp" ]]; then mv -f "$tmp" "$spend_cache"; else rm -f "$tmp"; fi
  ) >/dev/null 2>&1 &
fi

# Fallback aggregation — only consulted when the endpoint is unreachable.
if [[ $(cache_age_of "$cache_file") -gt 300 ]]; then
  (
    month_dir="$costs_root/$(date +%Y-%m)"
    if [[ -d "$month_dir" ]]; then
      awk 'BEGIN{s=0} {s+=$1} END{printf "%.2f", s}' "$month_dir"/*.txt 2>/dev/null > "$cache_file"
    else
      printf "0.00" > "$cache_file"
    fi
    # Piggy-back the per-prompt state cleanup: one pair of small files per
    # session accumulates otherwise. Throttled with this block, never inline.
    find "$pd_root" -maxdepth 1 -type f -mtime +14 -delete 2>/dev/null
    # Same for the daily buckets: drop day files past a week, then the day
    # directories they leave empty. -name '2*' keeps this away from .cursor.
    find "$day_root" -mindepth 2 -maxdepth 2 -type f -name '*.txt' -mtime +7 -delete 2>/dev/null
    find "$day_root" -mindepth 1 -maxdepth 1 -type d -name '2*' -empty -delete 2>/dev/null
    find "$day_root/.cursor" -maxdepth 1 -type f -mtime +14 -delete 2>/dev/null
  ) >/dev/null 2>&1 &
fi

spend_used=""; spend_limit=""; spend_pct=""
[[ -s "$spend_cache" ]] && read -r spend_used spend_limit spend_pct < "$spend_cache"
monthly_cost=$(cat "$cache_file" 2>/dev/null || echo "--")

# --- Plan kind: usage-credit spend (Enterprise, or credits enabled) and/or
# --- plan-limit windows (Pro/Max/Free). Either, or both, may apply.
lim_spend_on=""; lim5=""; lim5_reset=""; limw=""; limw_reset=""
[[ -s "$limits_cache" ]] && read -r lim_spend_on lim5 lim5_reset limw limw_reset < "$limits_cache"
# Before the first fetch lands, the credentials file names the plan (Linux;
# on macOS the Keychain is too slow to ask every render, so wait for the fetch).
sub_type=""
[[ -f "$creds_file" ]] && sub_type=$(jq -r '.claudeAiOauth.subscriptionType // empty' "$creds_file" 2>/dev/null)
plan_limits=0
case "$sub_type" in pro|max|free) plan_limits=1 ;; esac
[[ "$lim_spend_on" == "0" ]] && plan_limits=1
# Usage % and reset time per window: the client's stdin first, the fetched cache second.
num() { [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]] && awk -v p="$1" 'BEGIN { printf "%d", p + 0.5 }'; }
epoch_ok() { [[ "$1" =~ ^[0-9]+$ ]] && echo "$1"; }
u5=$(num "$rl5_pct");  [[ -z "$u5" ]] && u5=$(num "$lim5")
uw=$(num "$rl7_pct");  [[ -z "$uw" ]] && uw=$(num "$limw")
r5=$(epoch_ok "$rl5_reset"); [[ -z "$r5" ]] && r5=$(epoch_ok "$lim5_reset")
rw=$(epoch_ok "$rl7_reset"); [[ -z "$rw" ]] && rw=$(epoch_ok "$limw_reset")
# Subscription dollar figures are what the usage would cost on the API, not a bill.
cur="\$"; (( plan_limits )) && cur="≈\$"

# Today's total. Only ever a single day's directory — a handful of files — so
# it is summed inline rather than background-cached: the figure stays live
# instead of going up to five minutes stale, for about a millisecond a render.
daily_cost=""
if [[ "${DAILY_COST:-1}" != "0" ]]; then
  daily_cost=$(awk 'BEGIN{s=0}{s+=$1}END{printf "%.2f", s}' \
               "$day_root/$(date +%F)"/*.txt 2>/dev/null)
  [[ -z "$daily_cost" ]] && daily_cost="0.00"
fi

# --- Helpers ---
fmt_secs() {  # 4m 10s · 42s · 39m (whole minutes from 10m up)
  local s=$1
  if   (( s >= 600 )); then echo "$(( s / 60 ))m"
  elif (( s >= 60 ));  then echo "$(( s / 60 ))m $(( s % 60 ))s"
  else                      echo "${s}s"
  fi
}

fmt_dur() {  # 1d14h · 3h12m · 42m, for limit-window resets
  local s=$1; (( s < 0 )) && s=0
  if   (( s >= 86400 )); then echo "$(( s / 86400 ))d$(( s % 86400 / 3600 ))h"
  elif (( s >= 3600 ));  then echo "$(( s / 3600 ))h$(( s % 3600 / 60 ))m"
  else                        echo "$(( s / 60 ))m"
  fi
}

fmt_tok() {
  awk -v n=$1 'BEGIN {
    if (n >= 1000000) printf "%.1fM", n/1000000
    else if (n >= 1000) printf "%.1fk", n/1000
    else printf "%d", n
  }'
}

# --- Bar width ---
# Resolved before both bars so the context bar and the budget bar to its right
# are always the same length; BUDGET_BAR_WIDTH moves the pair together.
bb_width="${BUDGET_BAR_WIDTH:-20}"
[[ "$bb_width" =~ ^[0-9]+$ ]] && (( bb_width >= 6 )) || bb_width=20

# --- Context bar ---
bar_width=$bb_width
filled=$(awk -v p=$pct -v w=$bar_width 'BEGIN { f=(p/100)*w; printf "%d", (f>w?w:f) }')
[ $filled -gt $bar_width ] && filled=$bar_width
bar=""
for ((k=0; k<filled; k++)); do bar+="█"; done
for ((k=filled; k<bar_width; k++)); do bar+="░"; done

# --- Path with ~ ---
home_dir="$HOME"
disp_cwd="$cwd"
[[ "$disp_cwd" == "$home_dir"* ]] && disp_cwd="~${disp_cwd#$home_dir}"

# Above 3 segments, collapse the middle: keep the first segment and the last
# two, so line 1 stays short without losing "where am I" (repo/lib) context.
IFS='/' read -r -a _cwd_segs <<< "$disp_cwd"
_cwd_parts=()
for _seg in "${_cwd_segs[@]}"; do [[ -n "$_seg" ]] && _cwd_parts+=("$_seg"); done
_cwd_n=${#_cwd_parts[@]}
if (( _cwd_n > 3 )); then
  _cwd_prefix=""; [[ "$disp_cwd" == /* ]] && _cwd_prefix="/"
  disp_cwd="${_cwd_prefix}${_cwd_parts[0]}/…/${_cwd_parts[_cwd_n-2]}/${_cwd_parts[_cwd_n-1]}"
fi

# --- Colors ---
C="\033[36m"; P="\033[35m"; B="\033[34m"; G="\033[32m"; Y="\033[33m"; D="\033[${dim}m"; R="\033[0m"; RED="\033[${red}m"

# Real-ESC twins. The vars above hold the *text* "\033[..m", which only becomes
# an escape when printf interprets it. The budget bar is assembled into a single
# string and emitted with %s, so it needs literal ESC bytes instead.
e=$'\033'
eC="$e[36m"; eG="$e[32m"; eY="$e[33m"; eD="$e[${dim}m"; eR="$e[0m"; eRED="$e[${red}m"

# threshold color: green < 50%, yellow < 80%, red otherwise
color_for() { local v=$1; if [ "$v" -lt 50 ]; then echo "$G"; elif [ "$v" -lt 80 ]; then echo "$Y"; else echo "$RED"; fi; }
bar_color=$(color_for $pct)

# --- Budget-pacing bar: resolve values (config was read at the top) ---
bb_style="${BUDGET_BAR_STYLE:-marker}"
bb_line="${BUDGET_BAR_LINE:-1}"

# --- Month elapsed % (working days, Mon–Fri; BSD date) ---
# The usage endpoint reports no reset date, so the budget window is the calendar
# month — which is how claude.ai labels it ("this month's spend"). The *pacing*
# axis, though, counts only working days: credits get spent Mon–Fri, so the tick
# advances through the month's 20–23 weekdays and holds still over the weekend.
# A weekday in progress earns fractional credit, so the tick creeps rather than
# jumping a whole day at midnight.
# If credits ever reset on a billing anniversary instead, anchor the month
# arithmetic below on that day rather than the 1st.
# $1 optionally overrides "now" (epoch seconds), so this is testable without
# faking the system clock.
month_elapsed_pct() {
  local nowsec y m d hh mm ss dow1 nd
  nowsec=${1:-$(date +%s)}
  # One date call for every field of "now"; two more for the month's shape.
  if (( gnu_tools )); then
    read -r y m d hh mm ss < <(date -d "@$nowsec" "+%Y %m %d %H %M %S" 2>/dev/null)
    [[ -n "$y" && -n "$ss" ]] || return 1
    dow1=$(date -d "$y-$m-01" +%u 2>/dev/null) || return 1
    nd=$(date -d "$y-$m-01 +1 month -1 day" +%d 2>/dev/null) || return 1
  else
    read -r y m d hh mm ss < <(date -r "$nowsec" "+%Y %m %d %H %M %S" 2>/dev/null)
    [[ -n "$y" && -n "$ss" ]] || return 1
    dow1=$(date -j -f "%Y-%m-%d %H:%M:%S" "$y-$m-01 00:00:00" +%u 2>/dev/null) || return 1
    nd=$(date -j -v1d -v+1m -v-1d -f "%Y-%m-%d %H:%M:%S" "$y-$m-01 00:00:00" +%d 2>/dev/null) || return 1
  fi
  # 10# throughout so 08/09 aren't read as octal.
  awk -v dow1="$((10#$dow1))" -v nd="$((10#$nd))" -v day="$((10#$d))" \
      -v secs="$(( (10#$hh)*3600 + (10#$mm)*60 + 10#$ss ))" '
    # Mon–Fri days among the first n of the month, closed-form: every whole week
    # contributes 5, then walk the ≤6 remaining days. Cheap enough to run on
    # every statusline render, unlike a date(1) call per day.
    function weekdays(start, n,    c, i) {
      c = 5 * int(n / 7)
      for (i = 0; i < n % 7; i++) if (((start - 1 + i) % 7) < 5) c++
      return c
    }
    BEGIN {
      total = weekdays(dow1, nd); if (total <= 0) exit 1
      elapsed = weekdays(dow1, day - 1)                  # weekdays already done
      if ((((dow1 - 1 + day - 1) % 7) + 1) <= 5)         # is today Mon–Fri?
        elapsed += secs / 86400                          # else the tick freezes
      p = elapsed / total * 100
      if (p < 0) p = 0
      if (p > 100) p = 100
      printf "%d", p + 0.5
    }'
}

# --- Budget-pacing bar renderers ---
# Each takes (spend_pct, elapsed_pct, width) and echoes an ESC-coloured bar.
# Shared contract: fill = budget consumed, and the month position is the datum
# you compare it against. Under pace is good, so it stays green; over pace goes
# red regardless of the absolute percentage.
bb_cells() {  # spend_pct elapsed_pct width -> "fill_cells month_cell"
  awk -v s="$1" -v e="$2" -v w="$3" 'BEGIN {
    f=int(s*w/100 + 0.5); if(f>w)f=w; if(f<0)f=0
    m=int(e*w/100 + 0.5); if(m>w)m=w; if(m<1)m=1
    printf "%d %d", f, m
  }'
}

bar_marker() {  # one bar, month drawn as a tick you compare the fill against
  # $4 optionally overrides the tick colour (yellow by default).
  local sp=$1 ep=$2 w=$3 tick_col=${4:-$eY} f m i out="" fill_col
  read -r f m < <(bb_cells "$sp" "$ep" "$w")
  (( f > m )) && fill_col="$eRED" || fill_col="$eG"
  for ((i=1; i<=w; i++)); do
    if (( i == m )); then
      out+="${tick_col}┃" # month tick always wins the cell, fill or not
    elif (( i <= f )); then out+="${fill_col}█"
    else out+="${eD}░"
    fi
  done
  printf '%s%s' "$out" "$eR"
}

bar_banded() {  # three bands: spent | gap to month | month remaining
  local sp=$1 ep=$2 w=$3 f m i out=""
  read -r f m < <(bb_cells "$sp" "$ep" "$w")
  if (( f <= m )); then
    for ((i=1; i<=f;  i++)); do out+="${eG}█";   done   # spent
    for ((i=f+1; i<=m; i++)); do out+="${eC}▒";  done   # headroom (under pace)
    for ((i=m+1; i<=w; i++)); do out+="${eD}░";  done   # month remaining
  else
    for ((i=1; i<=m;  i++)); do out+="${eG}█";   done   # spent, on pace
    for ((i=m+1; i<=f; i++)); do out+="${eRED}▓"; done  # overspend
    for ((i=f+1; i<=w; i++)); do out+="${eD}░";  done
  fi
  printf '%s%s' "$out" "$eR"
}

bar_dual() {  # two independent half-width bars, explicitly labelled
  local sp=$1 ep=$2 w=$3 hw i out="" f m
  hw=$(( (w - 1) / 2 )); (( hw < 3 )) && hw=3
  read -r f m < <(bb_cells "$sp" "$ep" "$hw")
  local sc; (( sp > ep )) && sc="$eRED" || sc="$eG"
  out+="${eD}\$"
  for ((i=1; i<=f;  i++)); do out+="${sc}█"; done
  for ((i=f+1; i<=hw; i++)); do out+="${eD}░"; done
  out+=" ${eD}⏱"
  for ((i=1; i<=m;  i++)); do out+="${eC}█"; done
  for ((i=m+1; i<=hw; i++)); do out+="${eD}░"; done
  printf '%s%s' "$out" "$eR"
}

# --- Assemble the budget bar (empty when off, unstyled, or no spend data) ---
budget_bar=""
if [[ -n "$spend_used" && "$bb_style" != "off" ]]; then
  bb_elapsed=$(month_elapsed_pct) || bb_elapsed=""
  if [[ -n "$bb_elapsed" ]]; then
    bb_spend=${spend_pct:-0}
    case "$bb_style" in
      banded) bb_render=$(bar_banded "$bb_spend" "$bb_elapsed" "$bb_width") ;;
      dual)   bb_render=$(bar_dual   "$bb_spend" "$bb_elapsed" "$bb_width") ;;
      *)      bb_render=$(bar_marker "$bb_spend" "$bb_elapsed" "$bb_width") ;;
    esac
    # Label so this is never mistaken for the context-window bar beside it.
    if [[ "$bb_style" == "dual" ]]; then
      budget_bar="${bb_render} ${eD}${bb_spend}%/${g_time}${bb_elapsed}%${eR}"
    else
      budget_bar="${eD}${g_spend}${eR} ${bb_render} ${eD}${bb_spend}%/${g_time}${bb_elapsed}%${eR}"
    fi
  fi
fi

# --- Plan-limit segments (Pro/Max): the 5-hour window sits on line 1 beside
# --- the context bar (where Enterprise has its month bar), the weekly window on
# --- a row of its own. Each gets a pacing bar (same contract as the monthly bar,
# --- but the datum is how far through the window you are), its usage, time left
# --- and the local clock time it resets.
window_elapsed_pct() {  # reset_epoch window_secs -> 0..100, fails when unknown/past
  local left=$(( $1 - $(date +%s) ))
  (( left > 0 && left <= $2 )) || return 1
  echo $(( 100 - left * 100 / $2 ))
}
fmt_clock() {  # epoch -> "8:10 PM" today, "Wed 9:30 AM" any other day (local time)
  # Rounded to the nearest minute: resets land at :59.9, which would read a minute early.
  # %l (space-padded hour) works in GNU and BSD date alike; the pad is squeezed out.
  local fmt="%l:%M %p" t=$(( $1 + 30 )) out
  if (( gnu_tools )); then
    [[ "$(date -d "@$t" +%F)" == "$(date +%F)" ]] || fmt="%a %l:%M %p"
    out=$(date -d "@$t" "+$fmt")
  else
    [[ "$(date -r "$t" +%F)" == "$(date +%F)" ]] || fmt="%a %l:%M %p"
    out=$(date -r "$t" "+$fmt")
  fi
  out="${out#"${out%%[! ]*}"}"; echo "${out//  / }"
}
# Rows wrap only at these marks, so a narrow terminal (a phone) gets whole
# segments on the next row instead of a cropped one. See emit_wrapped.
brk=$'\x1e'
hour_seg=""; week_seg=""
if (( plan_limits )); then
  eL="$e[${lim_sgr}m"
  pb_width=$(( bb_width / 2 )); (( pb_width < 6 )) && pb_width=6
  now_s=$(date +%s)
  # Per window: label, used %, reset epoch, window length, glyph, time-left
  # glyph, reset-time glyph.
  for win in "5h ${u5:--} ${r5:--} 18000 ${g_hour:--} 📟 📥" \
             "wk ${uw:--} ${rw:--} 604800 ${g_week:--} ⏲️ 🔄"; do
    read -r w_lbl w_used w_reset w_secs w_glyph w_gleft w_greset <<< "$win"
    [[ "$w_glyph" == "-" ]] && w_glyph=""
    [[ "$w_used" =~ ^[0-9]+$ ]] || continue
    w_seg="${w_glyph}${w_glyph:+ }${eL}${w_lbl}${eR}"
    w_el=""
    [[ "$w_reset" =~ ^[0-9]+$ ]] && w_el=$(window_elapsed_pct "$w_reset" "$w_secs")
    if [[ -n "$w_el" && "$bb_style" != "off" ]]; then
      case "$bb_style" in
        banded) w_bar=$(bar_banded "$w_used" "$w_el" "$pb_width") ;;
        dual)   w_bar=$(bar_dual   "$w_used" "$w_el" "$pb_width") ;;
        *)      w_bar=$(bar_marker "$w_used" "$w_el" "$pb_width" "$eL") ;;
      esac
      w_seg+=" ${w_bar}"
    fi
    w_col=$(color_for "$w_used"); w_col="${w_col//\\033/$e}"
    w_seg+=" ${w_col}${w_used}%${eR}"
    [[ -n "$w_el" ]] && w_seg+="${eL}/${g_time}${w_el}%${eR}"
    if [[ "$w_reset" =~ ^[0-9]+$ ]] && (( w_reset > now_s )); then
      w_seg+="${brk} ${eL}${w_gleft} $(fmt_dur $(( w_reset - now_s ))) ${w_greset} $(fmt_clock "$w_reset")${eR}"
    fi
    if [[ "$w_lbl" == "5h" ]]; then hour_seg="$w_seg"; else week_seg="$w_seg"; fi
  done
fi

# --- 5h burn rate + exhaustion forecast (non-Enterprise plans only) ---
# The only signal is the 5h usage %, so it is sampled into a history shared by
# every session (the limit is account-wide): on each change, and at least every
# 5 minutes. The window also gives one free fact: it opened at 0%, 5h before
# its reset. The burn rate is then measured over several look-backs (10m to
# 90m, and since the window opened): short ones catch a burst, long ones fold
# in idle time. Their median is the estimate, their spread the range, and the
# share of them that hit 100% before the reset is the chance of running out.
consumer_plan=0
case "$sub_type" in
  pro|max|free)    consumer_plan=1 ;;
  enterprise|team) consumer_plan=0 ;;
  *)               consumer_plan=$plan_limits ;;  # no credentials file (macOS): trust the fetch
esac
burn_seg=""
if (( consumer_plan && plan_limits )) && [[ "$r5" =~ ^[0-9]+$ ]]; then
  # Sample: the client's live figure stamped now, else the fetched one stamped
  # with when it was fetched.
  b_now="$rl5_pct"; b_t=$(date +%s)
  if ! [[ "$b_now" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    b_now="$lim5"; b_t=$(file_mtime "$limits_cache" 2>/dev/null)
  fi
  b_hist="$HOME/.claude/.usage-5h-history"            # "<epoch> <pct> <reset_epoch>"
  if [[ "$b_now" =~ ^[0-9]+(\.[0-9]+)?$ && "$b_t" =~ ^[0-9]+$ ]]; then
    lt=""; lp=""; lr=""
    [[ -s "$b_hist" ]] && read -r lt lp lr < <(tail -n 1 "$b_hist")
    [[ "$lt" =~ ^[0-9]+$ ]] || lt=0
    [[ "$lr" =~ ^[0-9]+$ ]] || lr=0
    if (( b_t > lt )) && { [[ "$b_now" != "$lp" ]] || (( b_t - lt >= 300 || r5 - lr > 120 || lr - r5 > 120 )); }; then
      echo "$b_t $b_now $r5" >> "$b_hist" 2>/dev/null
      # Only the current window matters; keep the file to the last 6 hours.
      if (( $(wc -l < "$b_hist") > 300 )); then
        awk -v c=$(( b_t - 21600 )) '$1 >= c' "$b_hist" > "$b_hist.$$" && mv -f "$b_hist.$$" "$b_hist"
      fi
    fi
    read -r b_rate b_lo b_hi b_eta b_early b_late b_chance b_n < <(
      awk -v tn="$b_t" -v pn="$b_now" -v r="$r5" '
        $3 - r <= 120 && r - $3 <= 120 && $1 < tn { n++; T[n] = $1; P[n] = $2 }
        function at(t,   i) {           # usage at time t, linear between samples
          for (i = n; i > 0 && T[i] > t; i--) ;
          if (i == n) return P[n] + (pn - P[n]) * (t - T[n]) / (tn - T[n])
          if (T[i+1] == T[i]) return P[i+1]
          return P[i] + (P[i+1] - P[i]) * (t - T[i]) / (T[i+1] - T[i])
        }
        END {
          T[0] = r - 18000; P[0] = 0     # the window opened at 0%
          span = tn - T[0]
          if (span < 600 || pn <= 0) exit
          split("600 1200 1800 2700 3600 5400", H, " ")
          k = 0
          for (h = 1; h <= 6; h++) {
            if (H[h] >= span) continue
            t0 = tn - H[h]
            # Needs a real sample within 5 min before t0, or the window start near it.
            ok = (t0 - T[0] <= 300)
            for (i = 1; i <= n && !ok; i++) if (T[i] <= t0 && t0 - T[i] <= 300) ok = 1
            if (!ok) continue
            rate[++k] = (pn - at(t0)) * 3600 / H[h]
          }
          rate[++k] = pn * 3600 / span   # since the window opened
          for (i = 1; i <= k; i++) { if (rate[i] < 0) rate[i] = 0
            for (j = i; j > 1 && rate[j-1] > rate[j]; j--) { x = rate[j]; rate[j] = rate[j-1]; rate[j-1] = x } }
          med = (k % 2) ? rate[(k+1)/2] : (rate[k/2] + rate[k/2+1]) / 2
          left = 100 - pn; hit = 0
          for (i = 1; i <= k; i++) if (rate[i] > 0 && tn + left * 3600 / rate[i] < r) hit++
          eta = med > 0 ? int(tn + left * 3600 / med) : -1
          early = rate[k] > 0 ? int(tn + left * 3600 / rate[k]) : -1
          late = rate[1] > 0 ? int(tn + left * 3600 / rate[1]) : -1
          printf "%.2f %.2f %.2f %d %d %d %d %d\n", med, rate[1], rate[k], eta, early, late, int(hit * 100 / k + 0.5), k
        }' "$b_hist" 2>/dev/null)
  fi
  fmt_rate() { awk -v x="$1" 'BEGIN { if (x < 9.95) printf "%.1f", x; else printf "%d", x + 0.5 }'; }
  if [[ "$b_now" =~ ^[0-9]+(\.[0-9]+)?$ ]] && awk -v p="$b_now" 'BEGIN { exit !(p >= 100) }'; then
    burn_seg="🔥 ${eL}5h${eR} ${eRED}limit reached${eR} ${eL}· back at $(fmt_clock "$r5")${eR}"
  elif [[ "$b_chance" =~ ^[0-9]+$ ]]; then
    if   (( b_chance < 25 )); then b_col="$eG"
    elif (( b_chance < 60 )); then b_col="$eY"
    else                           b_col="$eRED"
    fi
    # A single estimate (only the window-open anchor so far) has no spread to
    # show, so the range and the chance wait for a second one.
    (( b_n < 2 )) && b_col="$eL"
    b_lo_s=$(fmt_rate "$b_lo"); b_hi_s=$(fmt_rate "$b_hi")
    burn_seg="🔥 ${eL}5h${eR} ${b_col}$(fmt_rate "$b_rate")%/h${eR}"
    [[ "$b_lo_s" != "$b_hi_s" ]] && burn_seg+="${brk} ${eL}(${b_lo_s}–${b_hi_s})${eR}"
    if (( b_eta > 0 && b_eta < r5 )); then
      b_from=$(fmt_clock "$b_early")
      if (( b_late > 0 && b_late < r5 )); then b_to=$(fmt_clock "$b_late"); else b_to="after reset"; fi
      burn_seg+="${brk} ${eL}· hits 100% ~${eR}${b_col}$(fmt_clock "$b_eta")${eR}"
      [[ "$b_from" != "$b_to" ]] && burn_seg+="${brk} ${eL}(${b_from}–${b_to})${eR}"
    else
      burn_seg+="${brk} ${eL}· lasts till reset${eR}"
    fi
    (( b_n >= 2 )) && burn_seg+="${brk} ${eL}·${eR} ${b_col}${b_chance}% chance to run out${eR}"
  fi
fi

# --- Cache-TTL segment: time left before the *current* warm prefix goes cold,
# or a flag that it just did. Reuses the context bar's red/yellow/green
# thresholds, inverted (little time left is urgent, not little usage is fine).
# Before any cache activity only the TTL label shows; STATUSLINE_CACHE_TTL=0
# hides it all.
ttl_seg=""
cache_warm=0
if [[ "$pc_warm" == "true" && "$pc_expires" =~ ^[0-9]+$ ]] && (( pc_expires > $(date +%s) )); then
  cache_warm=1
fi
if [[ "${STATUSLINE_CACHE_TTL:-1}" != "0" && "$pc_observed" == "true" ]]; then
  if (( cache_warm )); then
    ttl_total=300; [[ "$pc_ttl" == "1h" ]] && ttl_total=3600
    remaining=$(( pc_expires - $(date +%s) ))
    urgency=$(awk -v r=$remaining -v t=$ttl_total \
      'BEGIN { p = 100 - (r*100/t); if (p<0) p=0; if (p>100) p=100; printf "%d", p }')
    if   (( urgency < 50 )); then ttl_col="$eG"
    elif (( urgency < 80 )); then ttl_col="$eY"
    else                          ttl_col="$eRED"
    fi
    # Countdown, kept current by statusLine.refreshInterval in settings.json.
    # Without it, renders only happen on events and the number freezes while idle.
    ttl_seg="${eD}${g_ttl}${g_ttl:+ }${pc_ttl:-?} · ${ttl_col}$(fmt_secs "$remaining") left${eR}"
  else
    # Fixed 256-colour red (160) and white (231), not palette red (41), so a
    # light terminal theme cannot wash it out to pink.
    ttl_seg="${eD}${g_ttl}${g_ttl:+ }${pc_ttl:+$pc_ttl · }${eR}${e}[1;38;5;231;48;5;160m cold ${eR}"
  fi
elif [[ "${STATUSLINE_CACHE_TTL:-1}" != "0" && -n "$pc_ttl" ]]; then
  # Before the first request: no countdown yet, but the configured TTL is known.
  ttl_seg="${eD}${g_ttl}${g_ttl:+ }${pc_ttl} · waiting for first prompt${eR}"
fi

# --- Resume-or-restart verdict ---
# A session restarted from a progress file lands near S tokens and costs ~F to
# bootstrap, while every request in the old one re-reads all C tokens at the
# model's cache-read rate r. n = requests still to come.
#   warm: resume while C < S + F/(n·r)            n = task / quick burst size
#   cold: resume while C < (F + n·r·S)/(w + n·r)  w = cache-write multiplier
# Defaults come from a replay of the author's own transcripts; tune them in
# statusline.conf (STATUSLINE_FRESH_CTX, _RESTART_COST_5M/_1H, _BURST_QUICK/_TASK).
num_or() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 > 0 )) && echo "$1" || echo "$2"; }
verdict_seg=""
if [[ "${STATUSLINE_VERDICT:-1}" != "0" && "$pc_observed" == "true" && "$ctx_tok" =~ ^[0-9]+$ ]]; then
  case "$model_id" in
    *fable-5-1*|*mythos-5-1*) read_mult=0.025 ;;
    *opus-5-5*)               read_mult=0.05 ;;
    *)                        read_mult=0.1 ;;
  esac
  v_fresh=$(num_or "$STATUSLINE_FRESH_CTX" 50000)
  v_quick=$(num_or "$STATUSLINE_BURST_QUICK" 8)
  v_task=$(num_or "$STATUSLINE_BURST_TASK" 17)
  if [[ "$pc_ttl" == "1h" ]]; then v_write=2;    v_boot=$(num_or "$STATUSLINE_RESTART_COST_1H" 85000)
  else                             v_write=1.25; v_boot=$(num_or "$STATUSLINE_RESTART_COST_5M" 60000)
  fi
  read -r v_kind v_limit < <(awk -v c="$ctx_tok" -v r="$read_mult" -v w="$v_write" \
                                 -v f="$v_boot" -v s="$v_fresh" -v nq="$v_quick" -v nt="$v_task" \
                                 -v warm="$cache_warm" 'BEGIN {
    if (warm == 1) {
      task = s + f / (nt * r); quick = s + f / (nq * r)
      if (c < task) printf "resume %d", task
      else if (c < quick) printf "quick %d", quick
      else printf "new %d", quick
    } else {
      lim = (f + nq * r * s) / (w + nq * r)
      if (c < lim) printf "resume %d", lim; else printf "new %d", lim
    }
  }')
  case "$v_kind" in
    resume) verdict_seg="${eG}▶ resume${eR}" ;;
    quick)  verdict_seg="${eY}◐ quick only${eR}" ;;
    new)    verdict_seg="${e}[1;38;5;231;48;5;160m ↻ new session ${eR}" ;;
  esac
  [[ -n "$verdict_seg" ]] && verdict_seg+=" ${eD}($(fmt_tok "$ctx_tok")/$(fmt_tok "$v_limit"))${eR}"
fi

# --- cache-warm keep-alive (claude-cache-warm plugin), read from its state
# files. Only a live waker counts: its heartbeat lands every minute, so one
# older than 3 min (cache-warm's own WAKER_STALE_MS) is a dead process.
warm_seg=""
ccw_dir="${CCW_HOME:-$HOME/.claude-cache-warm}/sessions"
if [[ "${STATUSLINE_CACHE_WARM:-1}" != "0" && "$session_id" =~ ^[A-Za-z0-9_-]+$ \
      && -f "$ccw_dir/$session_id.json" && -f "$ccw_dir/$session_id.state.json" ]]; then
  IFS=$'\t' read -r w_status w_last w_exit w_next w_sent w_age < <(
    jq -rn --argjson now "$(( $(date +%s) * 1000 ))" '
      input as $s | input as $st | ($st.waker // {}) as $w
      | ([$s.lastHumanAt, $s.lastWorkStopAt, $s.startedAt] | map(. // 0) | max) as $act
      | [ ($w.status // "-"), ($w.lastStatus // "-"), ($w.exitReason // "-"),
          (if $w.nextPingAt then (($w.nextPingAt - $now) / 1000 | floor) else "-" end),
          ([$st.pingTimes[]? | select(. > $act)] | length),
          (($now - ($w.heartbeatAt // $w.exitedAt // 0)) / 1000 | floor) ] | @tsv
    ' "$ccw_dir/$session_id.json" "$ccw_dir/$session_id.state.json" 2>/dev/null)
  if [[ "$w_status" == "sleeping" && "$w_last" == "warming" && "$w_next" =~ ^-?[0-9]+$ ]] && (( w_age < 180 )); then
    (( w_next > 0 )) && w_txt="ping in $(fmt_secs "$w_next")" || w_txt="pinging…"
    (( w_sent > 0 )) && w_txt+=" · ${w_sent} sent"
    warm_seg="${eC}${g_warm}${g_warm:+ }${w_txt}${eR}"
  elif [[ "$w_status" == "pinged" ]] && (( w_age < 180 )); then
    warm_seg="${eC}${g_warm}${g_warm:+ }pinging…${eR}"
  elif [[ "$w_status" == "done" ]] && (( w_sent > 0 )); then
    case "$w_exit" in
      idle-cap|ping-cap) warm_seg="${eD}${g_warm}${g_warm:+ }stopped after ${w_sent} (cap)${eR}" ;;
      suspended)         warm_seg="${eY}${g_warm}${g_warm:+ }suspended: pings missed${eR}" ;;
    esac
  fi
fi

# --- Cache misses: the client's own ledger. Compactions are counted apart
# (expected_rebuilds), so every miss here is a rewrite nobody planned.
miss_seg=""
if [[ "${STATUSLINE_CACHE_MISSES:-1}" != "0" && "$pc_misses" =~ ^[0-9]+$ ]] && (( pc_misses > 0 )); then
  case "$pc_miss_cause" in
    ttl_expired_*)         miss_cause="ttl" ;;
    tools_changed)         miss_cause="tools" ;;
    system_prompt_changed) miss_cause="system" ;;
    model_changed)         miss_cause="model" ;;
    messages_rewritten)    miss_cause="rewrite" ;;
    likely_server_side)    miss_cause="server" ;;
    "")                    miss_cause="" ;;
    *)                     miss_cause="?" ;;
  esac
  miss_seg="${eRED}✗ ${pc_misses} miss$( (( pc_misses > 1 )) && echo es) · $(fmt_tok "$pc_miss_tok") rewritten${eR}"
  [[ -n "$miss_cause" ]] && miss_seg+=" ${eD}(${miss_cause})${eR}"
fi

# --- Wrapping ---
# Claude Code crops each status row at the terminal width and passes that width
# (live, so it follows a resize) in $COLUMNS. emit_wrapped breaks a row at its
# $brk marks instead, carrying whole segments down. Two columns are kept spare
# for the client's own padding. No $COLUMNS (older client): rows print as is.
wrap_cols=$(( ${COLUMNS:-0} - 2 ))
vis_width() {  # $1 -> REPLY: terminal columns, colour codes stripped, emoji 2 wide
  local s="$1" wide
  while [[ "$s" =~ $'\e'\[[0-9\;]*m ]]; do s="${s//"${BASH_REMATCH[0]}"/}"; done
  # Wide glyphs in use: the BMP four, and SMP emoji except 🕰 (narrow, but only
  # ever used with VS16, which ${#s} already counts as its second column).
  wide="${s//[^⌚⏳⚡✨$'\U1F300'-$'\U1FAFF']/}"; wide="${wide//🕰/}"
  REPLY=$(( ${#s} + ${#wide} ))
}
strip_sep() {  # $1 -> REPLY: drop the " │ " / " · " that joined a segment to the one before
  local s="$1" pre=""
  while [[ "$s" =~ ^($'\e'\[[0-9\;]*m) || "$s" == " "* ]]; do
    if [[ "$s" == " "* ]]; then s="${s:1}"; else pre+="${BASH_REMATCH[1]}"; s="${s:${#BASH_REMATCH[1]}}"; fi
  done
  if [[ "$s" == [│·]* ]]; then
    s="${s:1}"
    while [[ "$s" =~ ^($'\e'\[[0-9\;]*m) ]]; do pre+="${BASH_REMATCH[1]}"; s="${s:${#BASH_REMATCH[1]}}"; done
    s="${s# }"
  fi
  REPLY="$pre$s"
}
emit_wrapped() {  # print row $1, wrapped at its $brk marks to fit wrap_cols
  local row="" used=0 c
  local -a parts
  IFS="$brk" read -r -a parts <<< "$1"
  for c in "${parts[@]}"; do
    [[ -z "$c" ]] && continue
    vis_width "$c"
    if (( used > 0 && wrap_cols > 0 && used + REPLY > wrap_cols )); then
      printf '%s\n' "$row"
      strip_sep "$c"; c="$REPLY"; vis_width "$c"; row=""; used=0
    fi
    row+="$c"; used=$(( used + REPLY ))
  done
  printf '%s\n' "$row"
}

# --- Line 1 ---
# emoji mode: "📁 ~/.claude"   emoji-off mode: "[~/.claude]"
line1=$(
printf "${D}%s%s%s${R}${C}%s${R}${D}%s${R}" "$g_dir" "${g_dir:+ }" "$d_open" "$disp_cwd" "$d_close"
[ -n "$git_branch" ] && printf "\x1e ${D}%s${R}${P}%s%s${R}" "$g_branch" "${g_branch:+ }" "$git_branch"
printf "\x1e ${D}%s${R}${B}%s%s${R}" "$g_model" "${g_model:+ }" "$model_name"
[ -n "$effort_level" ] && printf "${D} (%s)${R}" "$effort_level"
[ "$output_style" != "null" ] && [ "$output_style" != "default" ] && printf "\x1e ${D}%s${R}${G}%s%s${R}" "$g_style" "${g_style:+ }" "$output_style"
printf "\x1e ${D}%s${R}%s${bar_color}%s${R} ${D}%d%%${R}" "$g_ctx" "${g_ctx:+ }" "$bar" "$pct"
[[ -n "$hour_seg" ]] && printf '\x1e %s' "$hour_seg"
[[ "$bb_line" == "1" && -n "$budget_bar" ]] && printf '\x1e %s' "$budget_bar"
)
emit_wrapped "$line1"

# --- 5h burn row (non-Enterprise plans, once there is enough history) ---
[[ -n "$burn_seg" ]] && emit_wrapped "$burn_seg"

# --- Line 2 ---
line2=$(
printf "${D}%s%s${R}${Y}%s%s${R}" "$g_sess" "${g_sess:+ }" "$cur" "$session_cost"

# What this prompt added. Hidden at $0.00 (a turn that hasn't spent yet) so a
# fresh prompt doesn't show a dead [+$0.00].
if [[ -n "$pd_delta" && "$pd_delta" != "0.00" ]]; then
  pd_txt="${g_prompt}${g_prompt:+ }+${cur}$pd_delta"
  case "$pd_dir" in
    up)   pd_col="$RED"; pd_txt+=" ↑${pd_dev}%" ;;
    down) pd_col="$G";   pd_txt+=" ↓${pd_dev}%" ;;
    *)    pd_col="$D" ;;
  esac
  printf "\x1e ${D}[${R}${pd_col}%s${R}${D}]${R}" "$pd_txt"
fi

# Today's spend. Always ~ (≈ on a plan): there is no official daily source.
if [[ -n "$daily_cost" ]]; then
  if (( plan_limits )); then day_cur="$cur"; else day_cur="~\$"; fi
  printf "\x1e ${D}│ %s%s%s%s${R}" "$g_day" "${g_day:+ }" "$day_cur" "$daily_cost"
fi

# Month-to-date spend: official figure when we have it, else the local sum
# prefixed with ~ so an estimate can never be mistaken for the real number.
# A plan without usage credits has no month budget; its limits show below instead.
if [[ -n "$spend_used" ]]; then
  sc=$(color_for "${spend_pct:-0}")
  printf "\x1e ${D}│ %s%s${R}${sc}\$%s${R}${D}/\$%s${R}" "$g_month" "${g_month:+ }" "$spend_used" "$spend_limit"
elif (( ! plan_limits )); then
  printf "\x1e ${D}│ %s%s~\$%s${R}" "$g_month" "${g_month:+ }" "$monthly_cost"
fi
# A plan's month to date at API list price, summed locally like the day figure
# (this machine only, sessions filed under the month they started in).
(( plan_limits )) && printf "\x1e ${D}│ %s%s%s%s${R}" "$g_mest" "${g_mest:+ }" "$cur" "$monthly_cost"

# Plan usage reported by the client. A plan-limit account gets its own row
# for these instead (hour_seg on line 1, week_seg on its own row).
if (( ! plan_limits )) && [[ -n "$rl5_pct" ]]; then
  p5=$(awk -v p=$rl5_pct 'BEGIN { printf "%d", p }')
  c5=$(color_for $p5)
  printf "\x1e ${D}│${R} ${c5}5h %d%%${R}" "$p5"
  if [[ -n "$rl7_pct" ]]; then
    p7=$(awk -v p=$rl7_pct 'BEGIN { printf "%d", p }')
    c7=$(color_for $p7)
    printf " ${c7}wk %d%%${R}" "$p7"
  fi
fi

# All four usage components, so the breakdown accounts for every token sent:
# ↓ fresh input (billed 1x), ✎ cache write (1.25x/2x by TTL), ↑ output,
# ⚡ cache read (0.1x). With caching on, ↓ alone is only the uncached
# remainder — often a couple of tokens per request — so omitting ✎ made the
# input side look broken and hid roughly a third of the spend.
# Directional glyphs are spaced (↓ 160), cache is flush (⚡11.9M) — the arrows
# read as separate tokens, the bolt reads as a unit with its number. An emoji
# override needs its own trailing space: STATUSLINE_GLYPH_CACHE="🔥 "
printf "\x1e ${D}│${R} ${C}%s%s%s${R} ${P}%s%s%s${R} ${B}%s%s%s${R} ${D}%s%s${R}" \
  "$g_in"    "${g_in:+ }"    "$(fmt_tok $in_tok)" \
  "$g_write" "${g_write:+ }" "$(fmt_tok $cw_tok)" \
  "$g_out"   "${g_out:+ }"   "$(fmt_tok $out_tok)" \
  "$g_cache" "$(fmt_tok $cr_tok)"
[[ "$bb_line" == "2" && -n "$budget_bar" ]] && printf '\x1e %s' "$budget_bar"
)
emit_wrapped "$line2"

# --- Weekly-limit row (Pro/Max; the 5h window is on line 1); omitted otherwise ---
[[ -n "$week_seg" ]] && emit_wrapped "$week_seg"

# --- Line 3: cache health (TTL + verdict, cache-warm, misses); omitted when empty ---
cache_line=""
ttl_verdict="$ttl_seg"
[[ -n "$verdict_seg" ]] && ttl_verdict+="${ttl_verdict:+${brk} ${eD}·${eR} }$verdict_seg"
for seg in "$ttl_verdict" "$warm_seg" "$miss_seg"; do
  [[ -z "$seg" ]] && continue
  [[ -n "$cache_line" ]] && cache_line+="${brk} ${eD}│${eR} "
  cache_line+="$seg"
done
[[ -n "$cache_line" ]] && emit_wrapped "$cache_line"

# --- Last line (only when the budget bar is given its own row) ---
if [[ "$bb_line" == "3" && -n "$budget_bar" ]]; then
  printf '%s\n' "$budget_bar"
fi

# Claude Code discards statusline output when the command exits non-zero, so the
# script must never end on a failed test. A trailing `[[ ... ]] && printf` guard
# returns 1 whenever its condition is false — that alone blanks the status line.
exit 0
