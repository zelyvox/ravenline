# ravenline

A raven that watches your Claude Code session. Two lines, pure bash.

```
⟨•▼•⟩  Opus 5.5 effort medium think  5h 51%  7d 7%
▓▓░░░░░░ 31%  ⎇ main*
```

You can read the session from the raven without reading any numbers. `⟨ ⟩`
are its folded wings, `▼` the closed beak, `▽` the open, cawing one.

## Moods

| Mood | When | Looks like |
| --- | --- | --- |
| alarm | context ≥ 90% | `⟩◉▽◉⟨ !!` wings flared |
| ruffled | context ≥ 75% | `⟪°▼°⟫ 🪶` feathers puffed up |
| locked in | effort `xhigh` / `max` | `⟨▸▼◂⟩ ⚡` |
| focused | context ≥ 50% | `⟨◐▼◐⟩` |
| idle | otherwise | blinks, peers |

While idle, every 15 seconds the raven does one of nine things: roosts under
the moon ☾, stretches its wings, caws (`kraa`), preens and drops a feather 🪶,
spots something shiny and keeps it 🪙, reads an omen 🔮, gives a knowing wink,
gazes at the stars ✶, or is joined for a moment by its twin — Huginn and
Muninn, thought and memory.

## What it shows

- **Line 1:** the raven, model, effort, `think` when extended thinking is on,
  5-hour / 7-day rate-limit usage, and any weekly limit scoped to one model,
  such as `fable` on Max (each turns red at 80%)
- **Line 2:** context gauge (green → yellow → red), git branch with `*` for
  uncommitted changes
- **Below:** one line per background worker that is still running: Claude Code
  subagents (`✦`), Codex sessions and Zelyvox lanes (`⚙`), with elapsed time.
  A worker drops off when it finishes, including a subagent that ends by handing
  its report back. Logs older than two hours are never opened.

### The one network call

Claude Code gives status lines the 5-hour and 7-day limits only. For
model-scoped limits, ravenline asks Anthropic's usage endpoint
(`api.anthropic.com/api/oauth/usage`) itself: in the background, at most once
every 5 minutes, shared by all sessions. It reads the OAuth token from
`~/.claude/.credentials.json` and hands it to `curl` on stdin, so it never
appears in a process list or on disk; `~/.curlrc` is ignored and redirects are
not followed. Only model names and percentages are cached
(`~/.claude/ravenline-usage.tsv`). A cache older than 30 minutes (or twice the
refresh interval, if longer) is not shown. The endpoint is undocumented; if it
changes, the extra limit simply disappears. Set `RAVENLINE_USAGE=0` to turn
the call off.

On macOS, Claude Code keeps the token in the Keychain rather than in
`.credentials.json`, so the extra limit does not show there.

## Install

Needs `bash`, `git` and `jq` (`curl` for model-scoped limits). Tested on Windows (Git Bash); uses only portable
bash, so macOS and Linux should work too.

```bash
curl -fsSL https://raw.githubusercontent.com/zelyvox/ravenline/main/ravenline.sh \
  -o ~/.claude/ravenline.sh
```

Then in `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/ravenline.sh",
    "refreshInterval": 1
  }
}
```

`refreshInterval` keeps the raven moving between messages; leave it out if you
prefer a still bird.

## Options

| Variable | Effect |
| --- | --- |
| `NO_COLOR` | any value disables colors |
| `RL_TICK` | pin the animation clock (tests, screenshots) |
| `RAVENLINE_CLAUDE_DIR` | Claude Code data dir to scan for workers (default `~/.claude`) |
| `RAVENLINE_CODEX_DIR` | Codex data dir (default `~/.codex`) |
| `ZELYVOX_LANES_DIR` | Zelyvox lane metadata (default `~/.zelyvox/lanes`) |
| `RAVENLINE_LIMITS_FILE` | where the latest rate limits are saved for other local tools (default `~/.claude/ravenline-limits.json`) |
| `RAVENLINE_USAGE` | `0` turns off the usage-endpoint call and the model-scoped limits |
| `RAVENLINE_USAGE_TTL` | seconds between endpoint calls (default `300`, `60` to `86400`) |
| `RAVENLINE_USAGE_FILE` | model-scoped limits cache (default `~/.claude/ravenline-usage.tsv`) |
| `RAVENLINE_CREDENTIALS_FILE` | where the OAuth token is read from (default `~/.claude/.credentials.json`) |

## Development

```bash
bash demo.sh          # every mood + edge cases; exits 1 on failure
bash demo.sh stunts   # the nine idle stunts, frame by frame
```

## License

MIT © 2026 Zelyvox
