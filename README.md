<p align="center">
  <img src="docs/devpulse-brand.jpeg" alt="DevPulse">
</p>

<p align="center">
  A lightweight Elixir agent for monitoring developer activity.
</p>

---

# DevPulse Agent

The DevPulse Agent is a lightweight Elixir CLI agent that runs locally on a developer's machine and reports development activity to the DevPulse Server.

It is responsible for:

- Linking a local Git workspace to the team and project assigned by an invitation.
- Establishing an authenticated agent session through a PAT-backed handshake.
- Sending periodic repository heartbeats with a short-lived session token.
- Persisting local configuration and session state.
- Handling temporary connectivity failures.
- Providing an interactive terminal experience powered by Rustler.

## Requirements

- Elixir
- Erlang/OTP
- Git
- Rust toolchain (required for building and running the Rustler NIF)

The test suite skips native terminal compilation because it does not exercise the
interactive terminal. Rust/Cargo is therefore required for development runs and
release builds, but not for `mix test`.

## Development

Install dependencies:

```bash
mix deps.get
```

## CLI workflow

A team lead creates a developer invitation for a specific team and project. After the developer accepts the invitation in the browser, the CLI uses the assignment from that invitation; the developer does not select a project manually.

### 1. Authenticate with the invitation

```bash
mix run -e 'DevpulseAgent.CLI.main(["login", "--token", "<invite-token>"])'
```

The server exchanges the invitation token for a Personal Access Token (PAT). The CLI stores the PAT globally and stores the assigned team/project separately for the next `init` command.

### 2. Link the assigned repository

Run this from the assigned Git repository:

```bash
mix run -e 'DevpulseAgent.CLI.main(["init"])'
```

Or provide the repository path explicitly:

```bash
mix run -e 'DevpulseAgent.CLI.main(["init", "--workspace", "/path/to/project"])'
```

`init` verifies the local `origin` remote against the project remote from the invitation before writing `.devpulse.toml`. Equivalent HTTPS and SSH forms are accepted, for example:

```text
https://github.com/acme/project.git
git@github.com:acme/project.git
```

A mismatched or missing `origin` remote prevents initialization.

### 3. Start monitoring

`init` only links the workspace; it does not start the agent. Start remains a separate foreground command:

```bash
mix run -e 'DevpulseAgent.CLI.main(["start", "--workspace", "/path/to/project"])'
```

The agent uses the saved PAT for the handshake. The server returns a short-lived session token, and the agent uses that session token for heartbeat requests.

## Commands

- `devpulse login --token <invite-token>` — exchange an accepted invitation for a PAT and project assignment.
- `devpulse init [--workspace <path>]` — automatically link the invitation’s project after checking the Git remote.
- `devpulse start [--workspace <path>]` — start foreground monitoring and heartbeat delivery.
- `devpulse stop [--workspace <path>]` — stop the workspace-scoped agent.
- `devpulse status [--workspace <path>]` — show session, buffer, and agent status.
- `devpulse whoami [--workspace <path>]` — show the linked team and session identity.
- `devpulse doctor [--workspace <path>]` — check Git, workspace, session, buffer, and server reachability.
- `devpulse team list` — list locally linked workspaces.
- `devpulse config get` / `devpulse config set` — inspect or change local configuration.
- `devpulse help` — show command help.

The CLI also provides suggestions for commands that are misspelled.

## Configuration
The agent maintains local configuration under the user's DevPulse configuration directory.

Important environment variables:
| Variable                         | Description             |    Default |
| -------------------------------- | ----------------------- | ---------: |
| `DEVPULSE_SERVER_URL`            | DevPulse API base URL  | `http://localhost:4000/api/v1` |
| `DEVPULSE_TOKEN`                 | Saved PAT used for handshakes |          — |
| `DEVPULSE_TEAM`                  | Default team fallback for local resolution |          — |
| `DEVPULSE_HEARTBEAT_INTERVAL_MS` | Heartbeat interval      |     `5000` |
| `DEVPULSE_OFFLINE_RETENTION_MS`  | Offline event retention | `86400000` |
| `DEVPULSE_MAX_BUFFER_EVENTS`     | Maximum buffered events | `10000` |
| `DEVPULSE_MAX_BUFFER_BYTES`      | Maximum serialized buffer size | `10485760` |
| `DEVPULSE_LOG_LEVEL`             | Agent log level         |     `info` |

For example:
```bash
export DEVPULSE_HEARTBEAT_INTERVAL_MS=10000
```
sets the heartbeat interval to 10 seconds.

The global configuration stores the PAT. The project assignment returned by `login` is stored separately in `pending_assignment.json` and is consumed by `init` after the local repository remote is verified. A successful `init` clears the pending assignment.

## Architecture

The agent is built around OTP:

```
CLI
 │
 ▼
RunnerSupervisor
 │
 ▼
Agent (GenServer)
 │
 ├── Handshake
 │
 ├── Heartbeats
 │
 └── Client / HTTP communication
```

The agent uses a supervisor to manage its long-running process and a GenServer to maintain runtime state and coordinate heartbeat activity.

Session credentials, pending heartbeats, and the single-instance lock are stored in a workspace/project-scoped directory under the user configuration directory. State writes use temporary files and atomic replacement; malformed session state is quarantined instead of crashing the agent. Offline buffering is bounded by both event count and serialized bytes, and every heartbeat carries an event ID so the server can deduplicate retries.

`devpulse stop` works from a separate CLI process by reading the scoped lock and signaling the owning process. `devpulse start` remains foreground-compatible and blocks while the agent is running.

## Native Terminal
The interactive terminal functionality is implemented using Rustler.
Rust source lives under:
```bash
native/terminal/
````

The compiled native artifact is generated during development/build and is not committed to the repository.

## Project Status

DevPulse Agent is under active development. The current focus is establishing the agent/server handshake, session lifecycle, heartbeat pipeline, and OTP architecture.
