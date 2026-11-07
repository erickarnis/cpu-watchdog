# cpu-watchdog

A tiny macOS launchd agent that catches runaway processes and forgotten dev
servers before they drain your battery.

Every 5 minutes (at low priority) it checks for:

- **Runaway processes** — anything above 80% CPU for 3 checks in a row (~15 min).
- **Forgotten dev servers** — `node`/`bun`/`deno`/`python`/… running a
  dev/serve/watch command whose parent app is gone (parent = launchd) for 6+ hours.

When it finds one, it shows an alert with three buttons:

| Button | What it does |
|---|---|
| **Ignore** (default, Return/Esc) | Nothing. You won't be alerted about that process again. |
| **Copy kill command** | Puts `kill <pid> \|\| kill -9 <pid>` on the clipboard. |
| **Kill** | Checks the PID is still the same process, sends `SIGTERM`, waits up to 5 s, then `SIGKILL` if needed. |

Nothing is ever killed unless you click **Kill**. Each process is reported once.
Unanswered alerts close themselves after ~4.5 minutes.

## Install

```sh
git clone https://github.com/erickarnis/cpu-watchdog.git
cd cpu-watchdog
./install.sh
```

The agent runs the script from wherever you cloned it, so edits take effect on
the next check without reinstalling.

Uninstall:

```sh
./install.sh uninstall
```

## Configuration

Edit the variables at the top of `cpu-watchdog.sh`:

| Variable | Default | Meaning |
|---|---|---|
| `CPU_THRESHOLD` | `80` | % of one core (top-style; can exceed 100) |
| `STRIKES` | `3` | consecutive high checks before alerting |
| `ORPHAN_HOURS` | `6` | how long an orphaned dev server may run |
| `IGNORE_RE` | `kernel_task\|WindowServer\|…` | process names never flagged for CPU |

## Files

- Log of every alert and action: `~/Library/Application Support/cpu-watchdog/watchdog.log`
- State (which processes were already reported): `…/cpu-watchdog/state`

## Test it

```sh
yes > /dev/null &   # fake CPU hog
STATE_DIR=/tmp/wd-test STRIKES=1 CPU_THRESHOLD=40 ./cpu-watchdog.sh
```

An alert for `yes` should appear; click **Kill**.
