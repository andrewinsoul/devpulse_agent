# Manual Testing Guide

This project is a good place to learn Elixir because the flow is small and easy to trace:

- `CLI` receives commands
- `Config` reads and writes local files
- `Workspace` decides which team a folder belongs to
- `Session` stores login data
- `Agent` runs the long-lived heartbeat loop

The easiest way to test safely is to use a temporary home directory so the app does not touch your real config.

## 1. Start from the project root

Run commands from the folder that contains `mix.exs`:

```bash
cd /Users/nature/Documents/elixir_projcets/dev_pulse/devpulse_agent
```

## 2. Use a temporary HOME

This keeps config files isolated while you test:

```bash
export HOME="$(mktemp -d)"
```

If you want extra logs while learning, set:

```bash
export DEVPULSE_LOG_LEVEL=debug
```

## 3. Create a scratch Git repo

The CLI expects a Git workspace for most commands:

```bash
mkdir -p /tmp/devpulse-playground
cd /tmp/devpulse-playground
git init
touch README.md
git add README.md
git commit -m "init"
```

If Git refuses to commit because your name or email is missing, set them once:

```bash
git config --global user.name "Your Name"
git config --global user.email "you@example.com"
```

## 4. Run the smallest commands first

Go back to the Elixir project folder, then try these one by one:

```bash
mix test
mix run -e 'DevpulseAgent.CLI.main(["config","get"])'
mix run -e 'DevpulseAgent.CLI.main(["config","set","default_team","core"])'
mix run -e 'DevpulseAgent.CLI.main(["config","get","default_team"])'
```

What to learn here:

- `mix test` tells you whether the code still behaves as expected
- `config get` shows the current stored settings
- `config set` shows how local files are written

## 5. Test workspace lookup

Now ask the CLI to inspect the scratch repo:

```bash
mix run -e 'DevpulseAgent.CLI.main(["whoami","--workspace","/tmp/devpulse-playground","--team","core"])'
mix run -e 'DevpulseAgent.CLI.main(["status","--workspace","/tmp/devpulse-playground","--team","core"])'
```

What to learn here:

- `whoami` tells you what workspace and team the CLI believes it is using
- `status` shows whether a session exists and what config values are active

## 6. Test team linking

This writes a workspace-local file:

```bash
mix run -e 'DevpulseAgent.CLI.main(["team","link","core","--workspace","/tmp/devpulse-playground"])'
mix run -e 'DevpulseAgent.CLI.main(["whoami","--workspace","/tmp/devpulse-playground"])'
mix run -e 'DevpulseAgent.CLI.main(["status","--workspace","/tmp/devpulse-playground"])'
```

What to learn here:

- `team link` stores the team in the workspace
- the next commands should pick up that saved choice automatically
- `team select` still works as a backward-compatible alias
- if a workspace is already linked to a different team, the CLI should stop instead of overwriting it
- `login` and `start` now re-save the resolved team after they know the workspace is safe

## 7. Test the long-running agent last

`start` is the background loop. It is the best command to inspect with logs, but run it only after the smaller commands are working:

```bash
mix run -e 'DevpulseAgent.CLI.main(["start","--workspace","/tmp/devpulse-playground","--team","core"])'
```

What to watch for:

- startup messages from the CLI
- `DevPulse agent ready for team ...`
- heartbeat or handshake logs
- retry or buffer logs when the server is offline

## 8. Good places for learning logs

Add small `Logger.debug/1` or `Logger.info/1` lines in these places:

- `lib/devpulse_agent/cli.ex` for command parsing and dispatch
- `lib/devpulse_agent/workspace.ex` for team resolution
- `lib/devpulse_agent/config.ex` for file reads and writes
- `lib/devpulse_agent/agent.ex` for session setup, handshake, heartbeat, and retries

Keep secrets out of logs:

- do not print `master_api_token`
- do not print `session_token`

## 9. A simple learning order

If your goal is to master Elixir while building this app, this order works well:

1. Learn how function clauses work in `CLI` and `Workspace`
2. Learn structs and maps in `Session` and `Config`
3. Learn pattern matching and guards in `Agent`
4. Learn `GenServer` life cycle events like `init/1`, `handle_info/2`, and `handle_call/3`
5. Learn supervision with `RunnerSupervisor`

## 10. A good test habit

When you make a change:

1. run `mix test`
2. run one CLI command
3. read the logs
4. change only one thing at a time

That makes it much easier to understand what Elixir is doing.
