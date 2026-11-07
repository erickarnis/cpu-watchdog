# cpu-watchdog

A macOS background agent that alerts you when a process has been pegging the
CPU, or when a dev server outlives the terminal, editor or AI agent that started it.

<img src="docs/alert.png" width="372" alt="Alert: Runaway process — node (astro dev) at 480% CPU for 15+ min, with Kill, Copy kill command and Ignore buttons">

Every 5 minutes it flags:

- **Runaway processes**: above 80% CPU for 3 checks in a row (~15 min).
- **Forgotten dev servers**: `node`, `bun`, `deno`, `python`, `ruby` or `php`
  running a dev/serve/watch command with no parent process (reparented to
  launchd) for 6+ hours.

Nothing is killed unless you click **Kill**. That sends `SIGTERM`, then
`SIGKILL` after 5 s if needed, and first checks the PID hasn't been reused.
**Ignore** is the default button, and each process is reported once.

Plain zsh and AppleScript, no dependencies.

## Install

```sh
git clone https://github.com/erickarnis/cpu-watchdog.git
cd cpu-watchdog
./install.sh              # ./install.sh uninstall to remove
```

The agent runs the script in place, so edits apply on the next check.

## Configure

Variables at the top of `cpu-watchdog.sh`:

| Variable | Default | |
|---|---|---|
| `CPU_THRESHOLD` | `80` | % of one core (can exceed 100) |
| `STRIKES` | `3` | consecutive 5-min checks before alerting |
| `ORPHAN_HOURS` | `6` | age before an orphaned dev server is flagged |
| `IGNORE_RE` | `kernel_task\|WindowServer\|…` | never flagged for CPU |

Log: `~/Library/Application Support/cpu-watchdog/watchdog.log`

## Try it

```sh
yes > /dev/null &
STATE_DIR=/tmp/wd-test STRIKES=1 CPU_THRESHOLD=40 ./cpu-watchdog.sh
```

## License

MIT
