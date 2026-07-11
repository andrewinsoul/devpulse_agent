defmodule DevpulseAgent.CLI do
  @moduledoc """
  Entry point for the DevPulse CLI binary.
  """

  require Logger

  alias DevpulseAgent.Utils.{Suggestion, Formatter}
  alias DevpulseAgent.{Agent, Buffer, Client, Config, Git, Session, Workspace, Help}

  def main(args) do
    Application.ensure_all_started(:devpulse_agent)

    case dispatch(args) do
      :ok -> :ok
      {:error, reason} -> print_error(reason)
    end
  end

  defp dispatch(args) do
    {command, rest} = split_command(args)

    commands = [
      "login",
      "start",
      "stop",
      "logout",
      "status",
      "doctor",
      "whoami",
      "config get",
      "config set",
      "team link",
      "team unlink",
      "team list"
    ]

    case command do
      ["team", "link"] ->
        run_team_link(rest)

      ["team", "list"] ->
        run_ls_team(rest)

      # ["team", "select"] -> run_team_link(rest)
      ["config", "get"] ->
        run_config_get(rest)

      ["config", "set"] ->
        run_config_set(rest)

      # ["init"] -> run_init(rest)
      ["help"] ->
        run_help(rest)

      ["login"] ->
        run_login(rest)

      ["doctor"] ->
        run_doctor(rest)

      ["whoami"] ->
        run_whoami(rest)

      ["status"] ->
        run_status(rest)

      ["start"] ->
        run_start(rest)

      ["stop"] ->
        run_stop(rest)

      [] ->
        input = Enum.join(args, " ")

        case Suggestion.suggest(input, commands) do
          {:ok, suggestion} ->
            IO.puts("""
            Unknown command: #{input}

            Did you mean?

                devpulse #{suggestion}
            """)

          {:error, :no_match} ->
            IO.puts("Unknown command: #{input}")
        end

      error ->
        IO.inspect(error)
        {:error, error}
    end
  end

  defp run_ls_team(_args) do
    mappings = Config.load().workspace_mappings

    if mappings == [] do
      IO.puts("No linked workspaces found.")
    else
      rows =
        Enum.map(mappings, fn mapping ->
          [
            mapping.team_slug,
            Path.basename(mapping.path),
            mapping.remote_url
          ]
        end)

      Formatter.print_table(
        headers: ["TEAM", "PROJECT", "REMOTE"],
        rows: rows
      )
    end

    :ok
  end

  defp run_doctor(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: common_switches(),
        aliases: common_aliases()
      )

    workspace = workspace_root(opts)
    config = Config.load() |> merge_cli_overrides(opts)
    session = Session.load()
    buffered = Buffer.load()

    git_repo? = git_repository?(workspace)

    workspace_linked? =
      case Workspace.resolve_team(workspace, opts, config) do
        {:ok, _, _} -> true
        _ -> false
      end

    session_found? = match?(%Session{}, session)
    session_valid? = session_valid?(session)

    buffer_size = length(buffered)

    rows = [
      ["Git Repository", yes_no(git_repo?)],
      ["Workspace Linked", yes_no(workspace_linked?)],
      ["Session Found", yes_no(session_found?)],
      ["Session Valid", yes_no(session_valid?)],
      ["Server Reachable", Formatter.warning("TODO")],
      ["Offline Buffer", "#{yes_no(buffer_size < 100)} (#{buffer_size} pending)"]
    ]

    Formatter.print_table(
      title: "DevPulse Doctor",
      rows: rows,
      headers: ["CHECK", "STATUS"]
    )

    recommendations =
      recommendations(
        git_repo?,
        workspace_linked?,
        session_found?,
        session_valid?
      )

    if recommendations == [] do
      IO.puts("")
      IO.puts("#{Formatter.success()} DevPulse is healthy.")
    else
      IO.puts("")
      IO.puts("Recommendations")
      IO.puts("----------------")

      Enum.each(recommendations, fn recommendation ->
        IO.puts("• #{recommendation}")
      end)

      IO.puts("")
      IO.puts("#{Formatter.warning("DevPulse requires attention.")}")
    end

    :ok
  end

  defp git_repository?(workspace) do
    match?({:ok, _}, Git.metadata(workspace))
  end

  defp session_valid?(%Session{} = session) do
    not Session.expired?(session)
  end

  defp session_valid?(_), do: false

  defp recommendations(
         git_repo?,
         workspace_linked?,
         session_found?,
         session_valid?
       ) do
    []
    |> maybe_add(
      not git_repo?,
      "Current directory is not a Git repository."
    )
    |> maybe_add(
      not workspace_linked?,
      "Link this workspace using: devpulse team link <team>"
    )
    |> maybe_add(
      not session_found?,
      "Authenticate using: devpulse login"
    )
    |> maybe_add(
      session_found? and not session_valid?,
      "Your session has expired. Run: devpulse login"
    )
  end

  defp maybe_add(list, true, message), do: [message | list]
  defp maybe_add(list, false, _message), do: list

  defp split_command(args) do
    case args do
      [first, second | rest]
      when first in ["team", "config"] and second in ["link", "select", "get", "set", "list"] ->
        {[first, second], rest}

      [command | rest]
      when command in [
             #  "init",
             "login",
             "whoami",
             "status",
             "start",
             "stop",
             "doctor",
             "help"
           ] ->
        {[command], rest}

      _ ->
        {[], args}
    end
  end

  # defp run_init(args) do
  #   {opts, _, _} =
  #     OptionParser.parse(args, switches: common_switches(), aliases: common_aliases())

  #   config = Config.load() |> merge_cli_overrides(opts)
  #   Config.save!(config)
  #   IO.puts("DevPulse configuration initialized at #{Config.config_file()}")
  #   :ok
  # end

  defp run_help([]), do: IO.puts(Help.show_generic_help_info())

  defp run_help([command]) do
    case Help.show_help_info(command) do
      {:ok, help} ->
        IO.puts(help)

      :error ->
        IO.puts("No help available for '#{command}'")
    end
  end

  defp run_login(args) do
    {opts, _, _} =
      OptionParser.parse(args, switches: common_switches(), aliases: common_aliases())

    workspace = workspace_root(opts)
    config = Config.load() |> merge_cli_overrides(opts)

    with {:ok, team_slug} <- resolve_team_choice(workspace, opts, config),
         :ok <- persist_team_link(workspace, team_slug),
         {:ok, config} <-
           perform_handshake(config, workspace, team_slug) do
      Config.save!(config)
      IO.puts("You have successfully logged in...")
    end
  end

  defp run_team_link(args) do
    {opts, positional, _} =
      OptionParser.parse(args, switches: [workspace: :string], aliases: [w: :workspace])

    case positional do
      [team_slug] ->
        workspace = Path.expand(Keyword.get(opts, :workspace, File.cwd!()))
        remote_url = Git.remote_url(workspace)

        case Workspace.link_team(workspace, team_slug, remote_url) do
          {:ok, :linked, _path} ->
            IO.puts("Linked team #{team_slug} to #{workspace}")
            :ok

          {:ok, :already_linked, _path} ->
            IO.puts("Workspace #{workspace} is already linked to team #{team_slug}")
            :ok

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        {:error, :team_link_requires_a_team_slug}
    end
  end

  defp run_whoami(args) do
    {opts, _, _} =
      OptionParser.parse(args, switches: common_switches(), aliases: common_aliases())

    workspace = workspace_root(opts)
    config = Config.load() |> merge_cli_overrides(opts)

    with {:ok, team_slug} <- resolve_team_choice(workspace, opts, config) do
      session = Session.load()

      Formatter.print_table(
        headers: ["PROPERTY", "VALUE"],
        rows: [
          ["Workspace", workspace],
          ["Team", team_slug || "unassigned"]
        ],
        title: "Configuration"
      )

      case session do
        %Session{} = session ->
          Formatter.print_table(
            headers: ["PROPERTY", "VALUE"],
            rows: [
              ["ID", session.session_id || "unknown"],
              ["Expires", format_datetime(session.expires_at)]
            ],
            title: "Session"
          )

        _ ->
          Formatter.print_table(
            headers: ["PROPERTY", "VALUE"],
            rows: [
              ["Status", "none"]
            ],
            title: "Session"
          )
      end

      :ok
    end
  end

  defp run_status(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: common_switches(),
        aliases: common_aliases()
      )

    workspace = workspace_root(opts)
    config = Config.load() |> merge_cli_overrides(opts)
    session = Session.load()
    buffered = Buffer.load()

    with {:ok, team_slug} <- resolve_team_choice(workspace, opts, config) do
      Formatter.print_table(
        title: "DevPulse Status",
        headers: ["PROPERTY", "VALUE"],
        rows: [
          ["Server URL", config.server_url],
          ["Workspace", workspace],
          ["Team", team_slug],
          ["Session Active", yes_no(not is_nil(session) and not Session.expired?(session))],
          ["Session Expires", format_datetime(session && session.expires_at)],
          ["Buffered Heartbeats", length(buffered)],
          ["Heartbeat Interval", "#{config.heartbeat_interval_ms} ms"],
          ["Offline Retention", "#{config.offline_retention_ms} ms"],
          ["Log Level", config.log_level]
        ]
      )

      :ok
    end
  end

  defp yes_no(true), do: Formatter.green("✔")
  defp yes_no(false), do: Formatter.red("✖")

  defp run_config_get(args) do
    {opts, positional, _} =
      OptionParser.parse(args, switches: common_switches(), aliases: common_aliases())

    config = Config.load() |> merge_cli_overrides(opts)

    case positional do
      [key] ->
        case config_key_atom(key) do
          nil ->
            {:error, :invalid_config_key}

          atom_key ->
            value = Map.get(config, atom_key)
            IO.puts(format_value(value))
            :ok
        end

      [] ->
        Formatter.print_table(
          headers: ["KEY", "VALUE"],
          rows: [
            ["Server URL", config.server_url],
            ["Default Team", config.default_team]
          ]
        )

        :ok

      _ ->
        {:error, :invalid_config_key}
    end
  end

  defp run_config_set(args) do
    {_opts, positional, _} =
      OptionParser.parse(args, switches: common_switches(), aliases: common_aliases())

    case positional do
      [key, value] ->
        case config_key_atom(key) do
          nil ->
            {:error, :invalid_config_key}

          atom_key ->
            casted_value = cast_config_value(atom_key, value)
            Config.set(atom_key, casted_value)
            IO.puts("Updated #{key}")
            :ok
        end

      _ ->
        {:error, :config_set_requires_key_and_value}
    end
  end

  defp run_start(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: common_switches(),
        aliases: common_aliases()
      )

    workspace = workspace_root(opts)
    config = Config.load() |> merge_cli_overrides(opts)

    with {:ok, team_slug} <- resolve_team_choice(workspace, opts, config),
         :ok <- persist_team_link(workspace, team_slug) do
      case startable_config(config, team_slug) do
        :ok ->
          boot_banner(workspace, team_slug)

          start_opts = [
            workspace: workspace,
            team: team_slug,
            force_handshake: Keyword.get(opts, :force_handshake, false),
            config: config,
            name: DevpulseAgent.RunnerSupervisor
          ]

          case DevpulseAgent.RunnerSupervisor.start_link(start_opts) do
            {:ok, sup_pid} ->
              ref = Process.monitor(sup_pid)

              receive do
                {:DOWN, ^ref, :process, _pid, reason} ->
                  case reason do
                    :normal -> :ok
                    other -> {:error, other}
                  end
              end

            {:error, reason} ->
              {:error, normalize_start_error(reason)}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp run_stop(_args) do
    case Process.whereis(Agent) do
      nil ->
        IO.puts("DevPulse agent is not running in this VM")
        :ok

      pid ->
        Agent.stop(pid)
        IO.puts("Stopped DevPulse agent")
        :ok
    end
  end

  defp perform_handshake(config, workspace, team_slug) do
    if is_nil(team_slug) do
      {:error, :team_required}
    else
      with {:ok, repo_metadata} <- Git.metadata(workspace),
           {:ok, session} <- handshake(config, team_slug, repo_metadata) do
        Session.save!(session)
        IO.puts("Handshake succeeded for team #{team_slug}")
        IO.puts("Session expires at #{format_datetime(session.expires_at)}")
        {:ok, config}
      else
        {:error, :missing_master_api_token} ->
          {:error, :missing_master_api_token}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp handshake(config, team_slug, repo_metadata) do
    token = config.master_api_token

    if is_nil(token) or token == "" do
      {:error, :missing_master_api_token}
    else
      hostname = hostname()
      operating_system = operating_system()
      fingerprint = hardware_fingerprint(hostname, operating_system, repo_metadata.repo_path)

      Client.handshake(config.server_url, token, %{
        team_slug: team_slug,
        hostname: hostname,
        operating_system: operating_system,
        hardware_fingerprint: fingerprint,
        project_name: repo_metadata.project_name,
        repo_path: repo_metadata.repo_path,
        git_remote_url: repo_metadata.remote_url
      })
      |> case do
        {:ok, body} ->
          {:ok,
           Session.from_handshake_response(body, %{
             team_slug: team_slug,
             hostname: hostname,
             operating_system: operating_system,
             hardware_fingerprint: fingerprint,
             server_url: config.server_url
           })}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp startable_config(config, team_slug) do
    cond do
      is_nil(team_slug) or team_slug == "" ->
        {:error, :team_required}

      is_nil(config.master_api_token) or config.master_api_token == "" ->
        {:error, :missing_master_api_token}

      true ->
        :ok
    end
  end

  defp resolve_team_choice(workspace, opts, config) do
    case Workspace.resolve_team(workspace, [team: Keyword.get(opts, :team)], config) do
      {:ok, team_slug, _source} -> {:ok, team_slug}
      {:error, reason} -> {:error, reason}
    end
  end

  defp workspace_root(opts),
    do: Path.expand(Keyword.get(opts, :workspace, Keyword.get(opts, :path, File.cwd!())))

  defp merge_cli_overrides(config, opts) do
    config
    |> maybe_put(:server_url, Keyword.get(opts, :server))
    |> maybe_put(:master_api_token, Keyword.get(opts, :token))
    |> maybe_put(:heartbeat_interval_ms, Keyword.get(opts, :heartbeat_interval_ms))
    |> maybe_put(:offline_retention_ms, Keyword.get(opts, :offline_retention_ms))
    |> maybe_put(:log_level, Keyword.get(opts, :log_level))
  end

  defp maybe_put(config, _key, nil), do: config
  defp maybe_put(config, key, value), do: Map.put(config, key, value)

  defp common_switches do
    [
      workspace: :string,
      path: :string,
      server: :string,
      token: :string,
      team: :string,
      heartbeat_interval_ms: :integer,
      offline_retention_ms: :integer,
      log_level: :string,
      force_handshake: :boolean
    ]
  end

  defp common_aliases do
    [w: :workspace, p: :path, s: :server, t: :token]
  end

  defp print_error(reason) do
    IO.puts(:stderr, "Error: #{format_reason(reason)}")
    {:error, reason}
  end

  # defp print_status(status) do
  #   IO.puts("Status for Workspace\n#{String.duplicate("-", 60)}")
  #   IO.puts("Server              :  #{status.server_url}")
  #   IO.puts("Workspace           :  #{status.workspace}")
  #   IO.puts("Team                :  #{status.team_slug || "unassigned"}")
  #   IO.puts("Session active      :  #{bool_text(status.session_active)}")
  #   IO.puts("Session expires     :  #{format_datetime(status.session_expires_at)}")
  #   IO.puts("Buffered heartbeats :  #{status.buffered_heartbeats}")
  #   IO.puts("Heartbeat interval  :  #{status.heartbeat_interval_ms}ms")
  #   IO.puts("Offline retention   :  #{status.offline_retention_ms}ms")
  #   IO.puts("Log level           :  #{status.log_level}")
  # end

  # defp format_config(config) do
  #   rows = [
  #     {"Server URL", config.server_url},
  #     {"Master API Token", masked(config.master_api_token)},
  #     {"Default Team", present(config.default_team)},
  #     {"Heartbeat Interval", "#{config.heartbeat_interval_ms} ms"},
  #     {"Offline Retention", "#{config.offline_retention_ms} ms"},
  #     {"Log Level", config.log_level}
  #   ]

  #   width =
  #     rows
  #     |> Enum.map(fn {label, _} -> String.length(label) end)
  #     |> Enum.max()

  #   body =
  #     Enum.map_join(rows, "\n", fn {label, value} ->
  #       "#{String.pad_trailing(label, width)} : #{value}"
  #     end)

  #   """
  #   DevPulse Configuration
  #   #{String.duplicate("-", 60)}

  #   #{body}
  #   """
  # end

  # defp present(nil), do: "<not configured>"
  # defp present(""), do: "<not configured>"
  # defp present(value), do: to_string(value)

  defp format_value(nil), do: ""
  defp format_value(value), do: to_string(value)

  defp cast_config_value(:heartbeat_interval_ms, value), do: Config.parse_integer(value) || value
  defp cast_config_value(:offline_retention_ms, value), do: Config.parse_integer(value) || value
  defp cast_config_value(_key, value), do: value

  defp format_datetime(nil), do: "unknown"
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_datetime(value) when is_binary(value), do: value

  # defp bool_text(true), do: "yes"
  # defp bool_text(false), do: "no"
  # defp bool_text(nil), do: "no"

  # defp masked(nil), do: ""

  # defp masked(token) when is_binary(token) and byte_size(token) > 8,
  #   do: String.slice(token, 0, 4) <> "..."

  # defp masked(token), do: token

  defp format_reason({:not_git_repo, workspace}), do: "#{workspace} is not a git repository"
  defp format_reason(:team_required), do: "workspace team selection is required"

  defp format_reason({:ambiguous_team, teams}),
    do: "ambiguous team mapping: #{Enum.join(teams, ", ")}"

  defp format_reason({:workspace_team_conflict, existing_team, requested_team}),
    do: "workspace is already linked to #{existing_team}; cannot link #{requested_team}"

  defp format_reason(:missing_master_api_token), do: "master API token is missing"
  defp format_reason(:team_link_requires_a_team_slug), do: "team link requires a team slug"

  defp format_reason(:invalid_config_key),
    do: "config get requires a key when using positional arguments"

  defp format_reason(:config_set_requires_key_and_value),
    do: "config set requires a key and value"

  defp format_reason(reason), do: inspect(reason)

  defp boot_banner(workspace, team_slug) do
    logo = ~S"""
               ____              ____        __
      /\      / __ \___ _   __  / __ \__  __/ /____ ___      /\
    _/  \/\_ / / / / _ \ | / / / /_/ / / / / / ___/ _ \    _/  \/\_
            / /_/ /  __/ |/ / / ____/ /_/ / (__  )  __/
           /_____/\___/|___/ /_/    \__,_/_/____/\___/...
    """

    IO.puts([IO.ANSI.green(), logo, IO.ANSI.reset()])
    IO.puts("Workspace: #{workspace}")
    IO.puts("Team: #{team_slug || "unassigned"}")
    IO.puts("")
    IO.puts("🟢 DevPulse Agent started")
    IO.puts("⏳ Press Ctrl+C to stop")
  end

  defp hostname do
    with {:ok, host} <- :inet.gethostname() do
      to_string(host)
    else
      _ -> "unknown-host"
    end
  end

  defp operating_system do
    {family, name} = :os.type()
    "#{family}/#{name}"
  end

  defp hardware_fingerprint(hostname, operating_system, repo_path) do
    :crypto.hash(:sha256, Enum.join([hostname, operating_system, repo_path], "|"))
    |> Base.encode16(case: :lower)
  end

  defp persist_team_link(workspace, team_slug) do
    remote_url = Git.remote_url(workspace)

    case Workspace.link_team(workspace, team_slug, remote_url) do
      {:ok, _status, _path} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp config_key_atom(key) do
    case String.trim(key) do
      "server_url" -> :server_url
      "master_api_token" -> :master_api_token
      "default_team" -> :default_team
      "heartbeat_interval_ms" -> :heartbeat_interval_ms
      "offline_retention_ms" -> :offline_retention_ms
      "log_level" -> :log_level
      "workspace_mappings" -> :workspace_mappings
      _ -> nil
    end
  end

  defp normalize_start_error({:shutdown, {:failed_to_start_child, _child, reason}}),
    do: normalize_start_error(reason)

  defp normalize_start_error({:shutdown, reason}), do: normalize_start_error(reason)

  defp normalize_start_error({:failed_to_start_child, _child, reason}),
    do: normalize_start_error(reason)

  defp normalize_start_error(reason), do: reason
end
