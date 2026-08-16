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

- Registering the local workspace with DevPulse.
- Establishing an authenticated agent session through a handshake.
- Sending periodic repository heartbeats.
- Persisting local configuration and session state.
- Handling temporary connectivity failures.
- Providing an interactive terminal experience powered by Rustler.

## Requirements

- Elixir
- Erlang/OTP
- Git
- Rust toolchain (required for building the Rustler NIF)

## Development

Install dependencies:

```bash
mix deps.get
```

Run the CLI:
```bash
mix run -e 'DevpulseAgent.CLI.main(["start"])'
```

Run against a specific workspace:
```bash
mix run -e 'DevpulseAgent.CLI.main(["start", "--workspace", "/path/to/project"])'
```

## Commands
- devpulse init
- devpulse login
- devpulse start
- devpulse stop
- devpulse status
- devpulse whoami
- devpulse doctor
- devpulse help

The CLI also provides suggestions for commands that are misspelled.

## Configuration
The agent maintains local configuration under the user's DevPulse configuration directory.

Important environment variables:
| Variable                         | Description             |    Default |
| -------------------------------- | ----------------------- | ---------: |
| `DEVPULSE_TOKEN`                 | DevPulse API token      |          — |
| `DEVPULSE_TEAM`                  | Default team            |          — |
| `DEVPULSE_HEARTBEAT_INTERVAL_MS` | Heartbeat interval      |     `5000` |
| `DEVPULSE_OFFLINE_RETENTION_MS`  | Offline event retention | `86400000` |
| `DEVPULSE_LOG_LEVEL`             | Agent log level         |     `info` |

For example:
```bash
export DEVPULSE_HEARTBEAT_INTERVAL_MS=10000
```
sets the heartbeat interval to 10 seconds.

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

## Native Terminal
The interactive terminal functionality is implemented using Rustler.
Rust source lives under:
```bash
native/terminal/
````

The compiled native artifact is generated during development/build and is not committed to the repository.

## Project Status

DevPulse Agent is under active development. The current focus is establishing the agent/server handshake, session lifecycle, heartbeat pipeline, and OTP architecture.