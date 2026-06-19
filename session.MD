# DevPulse – Complete Project Summary

## Project Overview

**DevPulse** is a real‑time developer activity observability platform for remote teams.  
It uses a lightweight CLI agent (built with Elixir) that runs on each developer's machine, automatically detecting the active Git repository and branch. The agent sends heartbeats to a central server, where team leads can see who is actively coding and what they are working on at any moment.

### Architecture (Three‑Tier)

Phoenix LiveView Dashboard (Web UI)
│
▼
Phoenix Presence + Ash Resources (Server)
│
▼
Elixir CLI Agents (running on developers' machines)

---

## CLI Agent (Completed)

### Technology Stack

- **Elixir** (v1.14+) with `GenServer` for process management
- **Burrito** – builds standalone binaries for macOS (Intel/M1), Linux, and Windows
- **Req** – HTTP client for sending heartbeats
- **Jason** – JSON encoding/decoding
- **TOML** – configuration file format (`~/.config/devpulse/config.toml`)

### Project Structure

```

devpulse_agent/
├── lib/
│ └── devpulse_agent/
│ ├── application.ex # Supervisor & application lifecycle
│ ├── agent.ex # GenServer – Git monitoring & heartbeat sender
│ ├── git.ex # Git metadata extraction
│ └── cli.ex # Entry point for the Burrito binary
├── config/
│ └── config.exs # Compile‑time defaults (env vars)
├── mix.exs # Dependencies, release config, Burrito targets
└── README.md

```

### Core Modules

#### 1. `Git` – `lib/devpulse_agent/git.ex`

Extracts Git repository information using `System.cmd/3`.

- `repo_root/0` – returns absolute path of repo root, or `nil`
- `current_branch/0` – returns branch name, or `nil`
- `has_uncommitted_changes?/0` – `true` if tracked or untracked changes exist
- `get_metadata/0` – returns a map:
  ```elixir
  %{
    project_name: "my-app",
    repo_path: "/Users/alice/projects/my-app",
    branch: "main",
    has_changes: false
  }
  ```

2. Agent – lib/devpulse_agent/agent.ex
   A GenServer that:

Binds to a specific directory (passed at startup)

Immediately checks if the directory is a Git repo – if not, prints error and calls System.halt(1)

Sends its first heartbeat immediately after startup

Polls Git every @check_interval (5 seconds) and sends a heartbeat if the Git state changed or if @force_heartbeat_interval (30 seconds) has passed

Includes a unique session_id per terminal instance (so the server can distinguish multiple sessions from the same user)

The init/1 function resolves the server URL and API token using a priority chain (see below). It stores them in the state, so each heartbeat uses the resolved values.

3. CLI – lib/devpulse_agent/cli.ex
The entry point for the Burrito binary (and also used for development with mix run -e).

Responsibilities:

Parse command‑line arguments:

--path – directory to monitor (defaults to current working directory)

--token – API token (overrides all other sources)

--server – server URL (overrides all other sources)

Save token and server to ~/.config/devpulse/config.toml if provided via CLI flags (creates directory if it doesn't exist)

Start the application (Application.start(:devpulse_agent))

Monitor the agent process; if it exits, print the reason and halt the VM

Keep the process alive with Process.sleep(:infinity) until the agent stops or the user presses Ctrl+C

4. Application – lib/devpulse_agent/application.ex

Starts the supervision tree with a single child:
```elixir
%{
  id: DevpulseAgent.Agent,
  start: {DevpulseAgent.Agent, :start_link, [target_dir]},
  restart: :temporary
}
```
restart: :temporary ensures the agent is never restarted if it crashes (we want to exit on failure).

## Configuration Management
Priority Chain (Highest to Lowest)
CLI flags --token and --server

Environment variables DEVPULSE_TOKEN and DEVPULSE_SERVER

Config file ~/.config/devpulse/config.toml

Compile‑time fallback from config.exs (for development)

The config file is a simple TOML file:

```toml
api_token = "dp_abc123def456"
server_url = "https://api.devpulse.com"
```

The agent reads the file at startup using a simple regex parser (no external TOML library needed).

Saving Configuration
When --token or --server are provided, the CLI updates (or creates) the config file. It preserves existing values unless they are overridden.

## Build & Distribution (Burrito)
Burrito packages the entire Erlang runtime with the application into a single standalone binary. No Erlang/Elixir installation is required on the target machine.

mix.exs Configuration

```elixir
def releases do
  [
    devpulse: [
      steps: [:assemble, &Burrito.wrap/1],
      strip_beams: false
    ]
  ]
end

def burrito do
  [
    escript_main: DevpulseAgent.CLI,
    targets: [
      macos:     [os: :darwin, cpu: :x86_64],
      macos_m1:  [os: :darwin, cpu: :aarch64],
      linux:     [os: :linux,  cpu: :x86_64],
      windows:   [os: :windows, cpu: :x86_64]
    ]
  ]
end
```

## Build Commands

```
# Build the binary for the current platform
MIX_ENV=prod mix release devpulse

# Build for all targets (requires cross‑compilation setup)
MIX_ENV=prod mix release devpulse --overwrite
```
Output binaries are placed in _build/prod/ (single) or burrito_out/ (multi‑target).

## Developer Workflow (Onboarding Design)
- Team Lead invites a developer via the DevPulse web UI (email address).

- Server generates a unique API token (e.g., dp_...) and sends an invitation email.

- Developer clicks the link in the email and lands on a download page.

- The download page detects the OS (via User‑Agent) and shows:

  - macOS / Linux: curl -sL https://devpulse.com/install | bash -s YOUR_TOKEN

  - Windows: powershell -c "irm https://devpulse.com/install.ps1 | iex" -Token YOUR_TOKEN

- The one‑click installer downloads the correct binary, writes the token to ~/.config/devpulse/config.toml, and starts the agent.

- Future runs: The developer simply runs ./devpulse – the token is read from the config file.

## Testing & Mock Server
A simple Python mock server can be used to verify that the agent sends correct heartbeats.

mock_server.py (listens on http://localhost:4000)

```python
#!/usr/bin/env python3
from http.server import HTTPServer, BaseHTTPRequestHandler
import json

class DevPulseHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path == "/api/agent/heartbeat":
            content_length = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(content_length)
            print("\n📨 Received heartbeat:")
            print(f"  Headers: {dict(self.headers)}")
            try:
                payload = json.loads(body)
                print(f"  Payload: {json.dumps(payload, indent=2)}")
            except:
                print(f"  Raw body: {body.decode()}")
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(b'{"status": "ok"}')
        else:
            self.send_response(404)
            self.end_headers()

if __name__ == "__main__":
    server = HTTPServer(('localhost', 4000), DevPulseHandler)
    print("🚀 Mock server running on http://localhost:4000")
    server.serve_forever()
  ```

Run it:

```
python3 mock_server.py
```

Then run the agent (development or binary) and observe the logged payload.


## Development Commands
```
# Run the CLI with full argument parsing (no auto‑start from mix)
mix run --no-halt -e "DevpulseAgent.CLI.main([])"

# With flags
mix run --no-halt -e 'DevpulseAgent.CLI.main(["--token", "dp_test", "--server", "http://localhost:4000"])'

# Build the standalone binary
MIX_ENV=prod mix release devpulse

# Run the binary
./_build/prod/devpulse
```

## Next Steps (Server & Dashboard)
With the CLI complete, the remaining work is on the server side (planned architecture):

- Phoenix application with Ash Framework.

- Authentication using AshAuthentication – users, organizations, tokens.

- ActivityLog resource to store heartbeats (belongs to User).

- API endpoint POST /api/agent/heartbeat that:

  - Extracts the Bearer token, finds the user.

  - Creates an ActivityLog entry.

  - Updates Phoenix Presence metadata (for real‑time status).

- Phoenix Presence to track online/offline status and current projects.

- LiveView Dashboard showing a grid of team members with:

  - Active/idle/offline status (via Presence).

  - Current project and branch (from the latest heartbeat).

  - Detail view with historical activity (from ActivityLog).

- Onboarding UI – invite form, download page, one‑click install scripts.

- Stripe integration (future) for payment.

## Current State Summary

✅ CLI Agent – Fully functional, production‑ready

✅ Config management – Works with priority chain, cross‑platform

✅ Burrito builds – Builds standalone binaries for all platforms

✅ Mock server – Available for testing heartbeats

⏳ Server – Not yet started

⏳ Dashboard – Not yet started

⏳ Onboarding UI – Not yet started


