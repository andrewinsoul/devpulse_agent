defmodule DevpulseAgent.Help do
  def show_help_info(cmd) do
    %{
      "config get" => """
      NAME
        devpulse config get

      DESCRIPTION
        Displays the active agent configurations. If a specific key parameter is provided, it
        returns only that individual setting's value. Otherwise, it prints the entire configuration suite.

      USAGE
        devpulse config get [key]

      VALID KEYS
        server_url, token, default_team, heartbeat_interval_ms, offline_retention_ms, log_level

      OPTIONS
        -s, --server <url>     Override the server target for this query execution context
        -t, --token <token>    Override the token authentication filter for this query
      """,
      "config set" => """
      NAME
        devpulse config set

      DESCRIPTION
        Updates a local configuration attribute inside the agent's persisted environment file.
        Automatically handles numeric casting transformations for intervals and retention configurations.

      USAGE
        devpulse config set <key> <value>

      VALID KEYS
        server_url, token, default_team, heartbeat_interval_ms, offline_retention_ms, log_level
      """,
      "login" => """
      NAME
        devpulse login

      DESCRIPTION
        Authenticates this machine globally with the DevPulse server using an invitation token.
        Exchanges the invitation token for a permanent Personal Access Token (PAT) and
        securely persists it to the global system configuration file.

      USAGE
        devpulse login --token <invite_token>

      OPTIONS
        -t, --token <token>    [REQUIRED] Specify the unique team invitation token string
      """,
      "init" => """
      NAME
        devpulse init

      DESCRIPTION
        Initializes a local project repository for DevPulse tracking. Uses the global
        machine token to fetch available teams and projects, links the current Git directory,
        and creates a tracking configuration context for the workspace.

      USAGE
        devpulse init

      OPTIONS
        -w, --workspace <dir>  Explicitly target a workspace directory (Defaults to current working directory)
      """,
      "whoami" => """
      NAME
        devpulse whoami

      DESCRIPTION
        Inspects and prints the resolved state metadata for the active session. Displays the
        currently loaded workspace root path, current team slug metadata, active session ID strings,
        and remaining authorization time-to-live expiration metrics.

      USAGE
        devpulse whoami

      OPTIONS
        -w, --workspace <dir>  Target a specific workspace directory configuration pathway
      """,
      "status" => """
      NAME
        devpulse status

      DESCRIPTION
        Evaluates the current operational status of the local agent context. Provides deep metrics on
        active engine heartbeat intervals, session validity windows, and the current volume load
        of heartbeats stored safely within the internal offline telemetry buffer.

      USAGE
        devpulse status

      OPTIONS
        -w, --workspace <dir>  Target a specific workspace directory context
      """,
      "start" => """
      NAME
        devpulse start

      DESCRIPTION
        Launches the core telemetry agent tracking process supervisor tree. Resolves local workspace bindings,
        executes a system handshake, opens persistent ingestion loops, and streams telemetry metrics.
        This command blocks terminal standard input/output streams to actively monitor the workspace context process.

      USAGE
        devpulse start

      OPTIONS
        -w, --workspace <dir>    Specify the tracking root path context
        --force_handshake        Force a clean handshake bypass validation regardless of existing session states
        --log_level <level>      Override tracking process log outputs dynamically
      """,
      "stop" => """
      NAME
        devpulse stop

      DESCRIPTION
        Safely halts any active background DevPulse telemetry agents operating inside this local
        VM instance runtime, flushing in-flight trackers and terminating supervisors gracefully.

      USAGE
        devpulse stop
      """
    }
    |> Map.fetch(cmd)
  end

  def show_generic_help_info() do
    """
    DevPulse CLI
    Developer observability for engineering teams.

    Usage:
      devpulse <command> [options]

    Commands:
      init           Set up repository tracking context for a workspace
      login          Authenticate this machine globally using an invite token
      whoami         Show current developer and session identity
      start          Start active telemetry monitoring for this workspace
      stop           Stop background monitoring on this runtime
      status         Show comprehensive workspace and buffer status

      config get     Display current configuration keys
      config set     Update configuration attributes

      help           Show this help message

    Run "devpulse help <command>" for detailed command usage.
    """
  end
end
