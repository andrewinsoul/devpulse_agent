defmodule DevpulseAgent.Help do
  def show_help_info(cmd) do
    %{
      "team link" => """
      NAME
        devpulse team link

      DESCRIPTION
        Links the specified team slug to your current active workspace. This establishes
        a local environment reference mapping the team configuration to the underlying Git repository.

      USAGE
        devpulse team link <team_slug>

      OPTIONS
        -w, --workspace <dir>  Explicitly target a workspace directory (Defaults to the current working directory)
      """,
      "config get" => """
      NAME
        devpulse config get

      DESCRIPTION
        Displays the active agent configurations. If a specific key parameter is provided, it
        returns only that individual setting's value. Otherwise, it prints the entire configuration suite.

      USAGE
        devpulse config get [key]

      VALID KEYS
        server_url, master_api_token, default_team, heartbeat_interval_ms, offline_retention_ms, log_level

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
        server_url, master_api_token, default_team, heartbeat_interval_ms, offline_retention_ms, log_level
      """,
      "login" => """
      NAME
        devpulse login

      DESCRIPTION
        Authenticates this machine with the DevPulse server. Resolves the team targets,
        verifies Git metadata hooks, and executes a handshake to obtain an operational telemetry session token.

      USAGE
        devpulse login

      OPTIONS
        -s, --server <url>     Target a custom metrics ingestion server URL
        -t, --token <token>    Specify the master API authorization token directly
        -w, --workspace <dir>  Specify the target workspace root directory path
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
      init           Initialize a new local configuration file
      login          Authenticate this machine and start a session
      whoami         Show current developer and session identity
      start          Start active telemetry monitoring for this workspace
      stop           Stop background monitoring on this runtime
      status         Show comprehensive workspace and buffer status

      config get     Display current configuration keys
      config set     Update configuration attributes

      team link      Link current workspace to an engineering team
      team select    Link workspace to a team (alias path)

      help           Show this help message

    Run "devpulse help <command>" for detailed command usage.
    """
  end
end
