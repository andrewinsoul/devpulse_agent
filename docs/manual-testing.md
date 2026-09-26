# DevPulse Agent Manual Flow

This guide exercises the invitation-driven CLI flow manually. The developer does not select a project from the server. The CTO/team lead selects the team and repository when creating the invitation, and the CLI uses that assignment during `init`.

## 1. Prepare a Git repository

Use the repository that the team lead assigned in the invitation:

```bash
mkdir -p /tmp/devpulse-playground
cd /tmp/devpulse-playground
git init
# Replace this with the actual remote assigned to the project on the server.
git remote add origin https://github.com/your-org/your-repository.git
printf "# DevPulse playground\n" > README.md
git add README.md
git commit -m "initial commit"
```

The local `origin` URL must match the project’s `git_remote_url`. HTTPS and SSH forms of the same GitHub remote are accepted, for example:

```text
https://github.com/your-org/your-repository.git
git@github.com:your-org/your-repository.git
```

## 2. Confirm the server-side setup

On the server, the team lead should have created:

1. A user account.
2. An organization.
3. A team.
4. A project/repository under that team.
5. A developer invitation containing both the team and project.

The invitation payload now requires:

```elixir
%{
  email: "developer@example.com",
  team_id: team_id,
  project_id: project_id
}
```

The invitation page should display the assigned team, project, and Git remote URL.

## 3. Configure the CLI server URL

From the `devpulse_agent` repository:

```bash
export DEVPULSE_SERVER_URL=http://localhost:4000/api/v1
```

If running the compiled CLI instead of Mix, use the equivalent configuration mechanism supported by the installed binary.

## 4. Log in with the invitation token

The developer runs:

```bash
mix run -e 'DevpulseAgent.CLI.main(["login", "--token", "dp_invite_..."])'
```

Expected behavior:

- The server exchanges the accepted invitation for a PAT.
- The CLI saves the PAT in the global DevPulse configuration.
- The CLI saves the team/project assignment in a protected pending-assignment file.
- The CLI prints the assigned team and project.
- The CLI does not ask the developer to select a project.

The pending assignment is intentionally separate from the global PAT. It is consumed by `init` when the developer links a local repository.

If the accepted invitation requires browser reauthorization, the CLI opens the verification URL. After browser approval, the CLI polls the pairing status endpoint and stores the PAT and the same project assignment.

## 5. Verify the login state

```bash
mix run -e 'DevpulseAgent.CLI.main(["config", "get", "default_team"])'
mix run -e 'DevpulseAgent.CLI.main(["whoami"])'
```

The global configuration should contain the authenticated team. The pending assignment should contain:

- Team ID
- Project ID
- Project name
- Project Git remote URL
- Invitation ID when supplied by the server

Do not print or copy the PAT into logs or tickets.

## 6. Initialize the assigned repository

Run `init` from the assigned local repository:

```bash
cd /tmp/devpulse-playground
mix run -e 'DevpulseAgent.CLI.main(["init"])'
```

Or provide the path explicitly:

```bash
mix run -e 'DevpulseAgent.CLI.main(["init", "--workspace", "/tmp/devpulse-playground"])'
```

Expected behavior:

1. The CLI reads the pending assignment from login.
2. The CLI reads the current repository’s Git remote.
3. The CLI compares the local remote with the invited project’s remote.
4. The CLI writes `.devpulse.toml` with the assigned team and project.
5. The CLI writes the workspace mapping.
6. The pending assignment is removed after successful initialization.
7. No project-selection prompt appears.

Expected success output includes the assigned team, project, and local directory.

## 7. Verify repository mismatch protection

Create or use a second repository with a different origin:

```bash
mkdir -p /tmp/devpulse-wrong-repo
cd /tmp/devpulse-wrong-repo
git init
git remote add origin https://github.com/another-org/another-repository.git
```

Run:

```bash
mix run -e 'DevpulseAgent.CLI.main(["init", "--workspace", "/tmp/devpulse-wrong-repo"])'
```

Expected behavior:

- Initialization fails.
- The CLI identifies the invited remote and current remote.
- No workspace configuration is created for the wrong repository.
- The pending assignment remains available for the correct repository.

Example error:

```text
The current repository does not match the repository in the invitation.
Invited repository: https://github.com/your-org/your-repository.git
Current repository: https://github.com/another-org/another-repository.git
```

## 8. Verify initialized workspace state

From the assigned repository:

```bash
mix run -e 'DevpulseAgent.CLI.main(["whoami", "--workspace", "/tmp/devpulse-playground"])'
mix run -e 'DevpulseAgent.CLI.main(["status", "--workspace", "/tmp/devpulse-playground"])'
mix run -e 'DevpulseAgent.CLI.main(["doctor", "--workspace", "/tmp/devpulse-playground"])'
```

Verify that:

- The workspace resolves to the assigned project.
- The team is resolved from `.devpulse.toml`.
- No project selection is required.
- The session is initially absent until `start` performs the handshake.
- `doctor` reports that the Git repository and workspace link are healthy.

## 9. Start the agent

Start the long-running process:

```bash
mix run -e 'DevpulseAgent.CLI.main(["start", "--workspace", "/tmp/devpulse-playground"])'
```

Expected behavior:

- The agent uses the saved PAT for the handshake.
- The server verifies the assigned project and returns a short-lived session token.
- The CLI uses the session token for heartbeats.
- The agent monitors Git state and sends periodic heartbeat events.
- The process remains in the foreground.

Do not use the PAT or invitation token as the heartbeat credential.

From another terminal, inspect status:

```bash
mix run -e 'DevpulseAgent.CLI.main(["status", "--workspace", "/tmp/devpulse-playground"])'
```

## 10. Stop the agent

From a second terminal:

```bash
mix run -e 'DevpulseAgent.CLI.main(["stop", "--workspace", "/tmp/devpulse-playground"])'
```

Expected behavior:

- The workspace-scoped agent lock is found.
- The running agent stops gracefully.
- A subsequent `status` reports that the agent is not running.

## 11. Inspect local linked workspaces

```bash
mix run -e 'DevpulseAgent.CLI.main(["team", "list"])'
```

This reads local workspace mappings and displays their team, project/workspace name, and Git remote. It does not fetch a fresh project list from the server.

## 12. Verify configuration values

```bash
mix run -e 'DevpulseAgent.CLI.main(["config", "get"])'
mix run -e 'DevpulseAgent.CLI.main(["config", "get", "server_url"])'
mix run -e 'DevpulseAgent.CLI.main(["config", "get", "heartbeat_interval_ms"])'
```

Configuration can be changed with:

```bash
mix run -e 'DevpulseAgent.CLI.main(["config", "set", "heartbeat_interval_ms", "10000"])'
```

## 13. Useful help commands

```bash
mix run -e 'DevpulseAgent.CLI.main(["help"])'
mix run -e 'DevpulseAgent.CLI.main(["help", "login"])'
mix run -e 'DevpulseAgent.CLI.main(["help", "init"])'
mix run -e 'DevpulseAgent.CLI.main(["help", "start"])'
```

## 14. Troubleshooting checklist

If `login` fails:

- Confirm the invitation token is accepted and has not expired.
- Confirm the server URL points to the running DevPulse server.
- Confirm the invitation contains a project assignment.

If `init` fails with a missing assignment:

- Run `login` again with the invitation token.
- Confirm the server exchange response contains `project` and `assignment` fields.

If `init` fails with a repository mismatch:

- Run `git remote get-url origin`.
- Compare it with the repository URL shown in the invitation.
- Run `init` from the repository assigned by the team lead.

If `start` fails:

- Run `doctor` and `status` first.
- Confirm the workspace has been initialized.
- Confirm the server is running and reachable.
- Confirm the PAT is present and the session has not been revoked.

The native interactive terminal still requires a working Rust/Cargo toolchain when running the CLI in the development environment.
