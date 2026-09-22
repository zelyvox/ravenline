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

- **Line 1:** the raven, model, effort, `think` when extended thinking is on, and
  5-hour / 7-day rate-limit usage (turns red at 80%)
- **Line 2:** context gauge (green → yellow → red), git branch with `*` for
  uncommitted changes

## Install

Needs `bash`, `git` and `jq`. Tested on Windows (Git Bash); uses only portable
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

## Development

```bash
bash demo.sh          # every mood + edge cases; exits 1 on failure
bash demo.sh stunts   # the nine idle stunts, frame by frame
```

## License

MIT © 2026 Zelyvox
