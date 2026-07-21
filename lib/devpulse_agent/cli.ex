defmodule DevpulseAgent.CLI do
  @moduledoc """
  Entry point for the DevPulse CLI binary.
  """

  require Logger

  alias DevpulseAgent.Utils.{Suggestion, Formatter, Prompt}
  alias DevpulseAgent.{Agent, Buffer, Client, Config, Git, Session, Workspace, Help}

  def main(args) do
    case Dotenvy.source([".env", System.get_env()]) do
      {:ok, env} ->
        System.put_env(env)

      {:error, reason} ->
        IO.warn("Failed to load .env: #{inspect(reason)}")
    end

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
      "init",
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

      ["init"] ->
        run_init(rest)

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
             "init",
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

  defp run_init(args) do
    {opts, _, _} =
      OptionParser.parse(args, switches: common_switches(), aliases: common_aliases())

    workspace_path = Keyword.get(opts, :workspace) || File.cwd!()

    config = Config.load()
    token = Map.get(config, :token)

    IO.inspect(token, label: ">>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>> MMM ")

    if is_nil(token) do
      IO.puts(:stderr, "❌ Error: Not authenticated. Run `devpulse login --token <token>` first.")
      System.halt(1)
    end

    base_url = System.get_env("api_base_url", "http://localhost:4000/api/v1")
    IO.puts("Fetching authorized team channels...")
    teams = Client.get_teams(base_url, token)
    IO.inspect(teams, label: "TEAMS >>>>>>>>>>>>>>>>> ")

    if teams != [] do
      team_names = Enum.map(teams, & &1["name"])
      selected_name = Prompt.select("Choose an engineering team:", team_names)
      selected_team = Enum.find(teams, &(&1["name"] == selected_name))
      team_slug = selected_team["slug"]

      IO.puts("Fetching projects under team [#{team_slug}]...")

      projects = Client.get_projects(base_url, token, team_slug)
      IO.inspect(projects, label: "PROJECTS >>>>>>>>>>>>>>>>>>> ")
      project_names = Enum.map(projects, & &1["name"])
      selected_proj_name = Prompt.select("Select the project repository to bind:", project_names)
      selected_project = Enum.find(projects, &(&1["name"] == selected_proj_name))

      remote_url =
        case Git.remote_url(workspace_path) do
          {:ok, url} -> url
          _ -> nil
        end

      new_mapping = %{
        path: workspace_path,
        team_slug: team_slug,
        project_slug: selected_project["slug"],
        remote_url: remote_url
      }

      updated_mappings = [new_mapping | Map.get(config, :workspace_mappings, [])]
      updated_config = Map.put(config, :workspace_mappings, updated_mappings)

      Config.save!(updated_config)

      IO.puts("🎉 Workspace initialized successfully!")
      IO.puts("Linked project: #{selected_project["name"]} (#{team_slug})")
      IO.puts("Path tracking ready: #{workspace_path}")
    end
  end

  defp run_help([]), do: IO.puts(Help.show_generic_help_info())

  defp run_help([command]) do
    case Help.show_help_info(command) do
      {:ok, help} ->
        IO.puts(help)

      :error ->
        IO.puts("No help available for '#{command}'")
    end
  end

  defp open_browser(url) do
    cmd =
      case :os.type() do
        {:unix, :darwin} -> "open"
        {:unix, _} -> "xdg-open"
        {:win32, _} -> "start"
      end

    System.cmd(cmd, [url])
  rescue
    _ -> :ok
  end

  defp await_authorization(base_url, pairing_code, retries \\ 60)

  defp await_authorization(_base_url, _pairing_code, 0) do
    {:error, "Authorization timed out. Please try logging in again."}
  end

  defp await_authorization(base_url, pairing_code, retries) do
    Process.sleep(2_000)

    case Client.check_pairing_status(base_url, pairing_code) do
      {:ok, %{"status" => "approved"} = config} ->
        {:ok, config}

      {:ok, %{"status" => "pending"}} ->
        await_authorization(base_url, pairing_code, retries - 1)

      {:error, reason} ->
        {:error, reason}

      _ ->
        await_authorization(base_url, pairing_code, retries - 1)
    end
  end

  defp run_login(args) do
    {opts, _, _} =
      OptionParser.parse(args, switches: common_switches(), aliases: common_aliases())

    invite_token = Keyword.get(opts, :token)

    if is_nil(invite_token) do
      IO.puts(:stderr, "Error: Missing invite token. Usage: devpulse login --token <your_token>")
      System.halt(1)
    end

    case authenticate_machine(invite_token) |> IO.inspect(label: "---- NATURE ------") do
      {:ok, config} ->
        Config.save!(config)

        IO.puts(
          "🎉 You have successfully logged in globally! Run `devpulse init` inside a repository to connect your project."
        )

      {:ok, :retrigger, %{"verification_url" => url, "pairing_code" => code}} ->
        base_url =
          System.get_env("api_base_url", "http://localhost:4000/api/v1")

        IO.puts("""

        \e[33m\e[1m⚠️  Token Expired\e[0m
        -------------------------------------------------------------
        Your invite token has expired or is no longer valid.

        To re-authenticate, open the link below in your browser:
        \e[36m\e[4m#{url}\e[0m

        Waiting for browser authorization...
        """)

        open_browser(url)

        case await_authorization(base_url, code) do
          {:ok, %{"token" => token} = config} ->
            config_to_save =
              config
              |> Map.delete("token")
              |> Map.put(:token, token)

            Config.save!(config_to_save)

            IO.puts("""

            \e[32m\e[1m🎉 Successfully re-authenticated!\e[0m
            Run `devpulse init` inside a repository to connect your project.
            """)

          {:error, reason} ->
            IO.puts(:stderr, "\n❌ Re-authentication failed: #{reason}")
            System.halt(1)
        end

      {:error, reason} ->
        IO.puts(:stderr, "❌ Login failed: #{reason}")
        System.halt(1)

      _ ->
        IO.puts(:stderr, "❌ Login failed: An error occured during login...")
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

  defp authenticate_machine(invite_token) do
    if is_nil(invite_token) do
      {:error, "token is required, pass the invite token using the token flag"}
    else
      base_url =
        System.get_env("api_base_url", "http://localhost:4000/api/v1")

      case Client.exchange_invite(base_url, invite_token) do
        {:ok, %{"status" => "success", "token" => pat}} ->
          {:ok, %{token: pat}}

        {:error, {reason, _body}} when reason in [:unauthorized, :not_found] ->
          Client.retrigger_auth(base_url, invite_token)

        {:error, {:transport_error, reason}} ->
          {:error, "Network connection failed: #{inspect(reason)}"}

        {:error, {:http_error, status, %{"error" => message}}} ->
          {:error, "Server error (#{status}): #{message}"}

        _error ->
          {:error, "An unexpected error occurred while communicating with the server."}
      end
    end
  end

  # defp handshake(config, team_slug, repo_metadata) do
  #   token = config.master_api_token
  #   if is_nil(token) or token == "" do
  #     {:error, :missing_master_api_token}
  #   else
  #     hostname = hostname()
  #     operating_system = operating_system()
  #     fingerprint = hardware_fingerprint(hostname, operating_system, repo_metadata.repo_path)
  #     Client.handshake(config.server_url, token, %{
  #       team_slug: team_slug,
  #       hostname: hostname,
  #       operating_system: operating_system,
  #       hardware_fingerprint: fingerprint,
  #       project_name: repo_metadata.project_name,
  #       repo_path: repo_metadata.repo_path,
  #       git_remote_url: repo_metadata.remote_url
  #     })
  #     |> case do
  #       {:ok, body} ->
  #         {:ok,
  #          Session.from_handshake_response(body, %{
  #            team_slug: team_slug,
  #            hostname: hostname,
  #            operating_system: operating_system,
  #            hardware_fingerprint: fingerprint,
  #            server_url: config.server_url
  #          })}
  #       {:error, reason} ->
  #         {:error, reason}
  #     end
  #   end
  # end

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
  #
  #   body =
  #     Enum.map_join(rows, "\n", fn {label, value} ->
  #       "#{String.pad_trailing(label, width)} : #{value}"
  #     end)
  #
  #   """
  #   DevPulse Configuration
  #   #{String.duplicate("-", 60)}
  #
  #   #{body}
  #   """
  # end
  #
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
      /\      / __ \___ _   __  / __ \__  __/ /____ ___       /\
    _/  \/\_ / / / / _ \ | / / / /_/ / / / / / ___/ _ \    __/  \/\_
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
