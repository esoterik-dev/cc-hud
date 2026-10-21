#!/bin/bash
# PostToolUse hook for AskUserQuestion: never let Claude act on a question the
# user didn't answer.
#
# With askUserQuestionTimeout set ("60s" | "5m" | "10m"), Claude Code closes an
# unanswered question and tells Claude to "proceed using your best judgment".
# This hook blocks that: if any question came back without an answer, Claude is
# told to stop, restate what is still open in plain text, and end its turn.
# Ending the turn matters for cost: an idle session can be kept warm by a
# keep-alive (e.g. claude-cache-warm), a session stuck in an open dialog cannot.
#
# Register in ~/.claude/settings.json under hooks.PostToolUse with
# "matcher": "AskUserQuestion". Reads the hook JSON on stdin; always exits 0.

in=$(cat)

# Each unanswered question with its options, one per line.
open=$(jq -r '
  (.tool_response.answers // {}) as $a
  | (.tool_input.questions // [])[]
  | select(($a[.question] // "") == "")
  | "- " + .question
    + (if (.options // []) | length > 0
       then " (options: " + ([.options[].label] | join(" / ")) + ")" else "" end)
' <<< "$in" 2>/dev/null)

[[ -z "$open" ]] && exit 0

# Keep any partial answers, so Claude doesn't ask for those again.
given=$(jq -r '(.tool_response.answers // {}) | to_entries[]
               | select((.value | tostring) != "") | "- \(.key) → \(.value)"' <<< "$in" 2>/dev/null)

reason="The user has NOT answered; the question closed because they were away. Do not proceed, do not guess or choose a default, and do not call any other tool. End your turn now: restate the unanswered question in plain text, with its options, and wait for the user's reply.

Unanswered:
$open"
[[ -n "$given" ]] && reason+="

Already answered (keep these):
$given"

jq -n --arg r "$reason" '{decision: "block", reason: $r}'
exit 0
