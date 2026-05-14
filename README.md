# agent-pad

A lightweight system for managing multiple coding agents from Emacs and the
terminal. Agents run in tmux windows; Emacs provides the primary dashboard.

## How it works

- **Dispatch** agents into a shared tmux session (`agents` by default)
- **Monitor** status from an Emacs buffer or the tmux status bar
- **Attach** to any agent via `eat` inside Emacs — interact, then detach
- **Status detection** is automatic: silence → waiting, exit → done

No hooks, no daemons. Status is derived by polling tmux window activity
timestamps every 5 seconds.

## Installation

### Emacs (recommended)

Add to your Emacs config:

```elisp
(use-package agent-pad
  :vc (:url "https://github.com/subie/agent-pad"
            :rev :newest
            :branch "main")
  :commands (agent-pad agent-dispatch)
  :bind (("C-c q" . agent-pad)))
```

This installs the Emacs package and adds the shell commands to your PATH
automatically.

## Usage

### Dispatching agents

- `M-x agent-dispatch` — prompts for task name and command
- `C-u M-x agent-dispatch` — dispatch and immediately attach via `eat`

Example commands to dispatch:

```bash
# Non-interactive — agent runs the prompt and exits
copilot -p "refactor the auth module to use JWT"

# Interactive — agent stays open for follow-up conversation
copilot -i "fix the flaky tests in src/api"
```

### Monitoring

**Emacs (primary):** `M-x agent-pad`

| Key   | Action                                    |
|-------|-------------------------------------------|
| `RET` | Attach to agent in an `eat` buffer        |
| `+`   | Dispatch a new agent                      |
| `g`   | Refresh                                   |
| `d`   | Mark done and clean up                    |
| `k`   | Kill agent                                |
| `q`   | Quit                                      |

The queue auto-refreshes every 5 seconds. Agents needing attention
(waiting/blocked) sort to the top.

**tmux status bar (passive):** All agent windows show emoji-prefixed status:

```
⏳ auth-refactor | ❓ fix-tests | ✓  add-pagination
```

## Configuration

All settings via environment variables:

| Variable                | Default              | Description                              |
|-------------------------|----------------------|------------------------------------------|
| `AGENT_SESSION`         | `agents`             | tmux session name                        |
| `AGENT_STATE_DIR`       | `~/.agent-state`     | Directory for state files                |
| `AGENT_SILENCE_SECONDS` | `30`                 | Seconds of silence before marking waiting|

Emacs customization group: `M-x customize-group agent-pad`

## State file format

One file per task in `$AGENT_STATE_DIR/`, named by task:

```
status|task|timestamp|note
```

- `status`: `running`, `waiting`, `done`, `blocked`
- `task`: kebab-case identifier
- `timestamp`: epoch seconds
- `note`: optional free-text

## How status detection works

No hooks or background daemons. The Emacs refresh timer (every 5s) polls
`#{window_activity}` from tmux:

- If `now - last_activity > AGENT_SILENCE_SECONDS` → `waiting`
- If activity resumed after being silent → `running`
- If the process exits → `done` (via the `agent-start` wrapper)
- `blocked` is only set manually via `agent-signal`

## Dependencies

- **tmux** — process holder and passive dashboard
- **Emacs 29.1+** with [eat](https://codeberg.org/akib/emacs-eat) — terminal
  emulation for attaching to agents

## Shell-only usage

You can use agent-pad entirely from the terminal, without Emacs.

### Installation

```bash
git clone https://github.com/subie/agent-pad.git ~/dev/agent-pad
export PATH="$HOME/dev/agent-pad/bin:$PATH"  # add to .zshrc/.bashrc
```

### Dispatching agents

```bash
# Fire-and-forget (agent exits when done)
agent-start auth-refactor "copilot -p 'refactor the auth module'"

# Interactive (agent stays open for follow-up)
agent-start fix-tests "copilot -i 'fix the flaky tests'"

# Any command works
agent-start run-tests "cd ~/src/api && make test"
```

### Manual signaling

For scripts that want explicit control:

```bash
agent-signal waiting auth-refactor "needs code review"
agent-signal done auth-refactor "PR #42 ready"
agent-signal blocked fix-tests "waiting on test credentials"
```

### Cleanup

```bash
agent-clean              # remove all done state files and windows
agent-stop auth-refactor # kill a specific agent
```
