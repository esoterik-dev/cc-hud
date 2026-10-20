# cc-hud

A cost-aware status line for Claude Code: spend, burn rate, plan limits and cache TTL.

```
line 1: dir | git | model | style | context bar | 5h window
burn:   5h burn rate, likely time it runs out, chance it runs out before the reset
line 2: session $ [+this prompt] | month $ | plan usage | tokens
week:   weekly window bar, used, time left, reset time
line 3: cache TTL + verdict | cache-warm | cache misses
```

Every glyph and config key: `bash cc-hud.sh --legend`.

## Install

Requires `bash`, `jq` and `curl`. Linux and macOS.

```sh
cp cc-hud.conf.example ~/.claude/statusline.conf   # optional
```

Then in `~/.claude/settings.json`:

```json
"statusLine": { "type": "command", "command": "bash /path/to/cc-hud/cc-hud.sh", "refreshInterval": 10 }
```

## Where the numbers come from

1. `GET /api/oauth/usage`: server-side month-to-date spend and plan windows, the same source as `/usage`. Uses the session's own OAuth token, which is sent only to `api.anthropic.com` and never stored.
2. `context_window.*` / `rate_limits.*` from the status line's stdin.
3. `cost.total_cost_usd`: computed locally at list rates; fine as a per-session gauge, not a bill.

See the header comment in `cc-hud.sh` for details.
