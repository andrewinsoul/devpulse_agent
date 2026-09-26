defmodule DevpulseAgent.CLI do
  @moduledoc """
  Entry point for the DevPulse CLI binary.
  """

  # require Logger

  alias DevpulseAgent.Utils.{Suggestion, Formatter}
  alias DevpulseAgent.{Buffer, Client, Config, Git, Help, Lifecycle, Session, Workspace}

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
      "status",
      "doctor",
      "whoami",
      "config get",
      "config set",
      "init",
      "team list"
    ]

    case command do
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
        input = List.first(args)

        case Suggestion.suggest(input || "", commands) do
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
    {session_file, buffer_file} = scoped_state_files(workspace)
    session = if session_file, do: Session.load(session_file), else: nil
    buffered = if buffer_file, do: Buffer.load(buffer_file), else: []

    git_repo? = git_repository?(workspace)

    workspace_linked? =
      case resolve_team_choice(workspace, opts, config) do
        {:ok, _team_slug} -> true
        _ -> false
      end

    session_found? = match?(%Session{}, session)
    session_valid? = session_valid?(session)

    buffer_size = length(buffered)
    server_reachable? = server_reachable?(config[:server_url] || config["server_url"])

    rows = [
      ["Git Repository", yes_no(git_repo?)],
      ["Workspace Linked", yes_no(workspace_linked?)],
      ["Session Found", yes_no(session_found?)],
      ["Session Valid", yes_no(session_valid?)],
      ["Server Reachable", yes_no(server_reachable?)],
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
        session_valid?,
        server_reachable?
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

  defp server_reachable?(server_url) do
    case Client.check_server(server_url) do
      {:ok, status} when is_integer(status) and status in 100..599 -> true
      _ -> false
    end
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
         session_valid?,
         server_reachable?
       ) do
    []
    |> maybe_add(
      not git_repo?,
      "Current directory is not a Git repository."
    )
    |> maybe_add(
      not workspace_linked?,
      "Initialize this workspace using: devpulse init"
    )
    |> maybe_add(
      not session_found?,
      "Authenticate using: devpulse login"
    )
    |> maybe_add(
      session_found? and not session_valid?,
      "Your session has expired. Run: devpulse login"
    )
    |> maybe_add(
      not server_reachable?,
      "DevPulse server is unreachable. Check the configured server URL and server status."
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
      OptionParser.parse(args,
        switches: common_switches(),
        aliases: common_aliases()
      )

    requested_workspace = Path.expand(Keyword.get(opts, :workspace) || File.cwd!())
    config = Config.load() |> merge_cli_overrides(opts)
    token = Map.get(config, :token)
    team_info = config[:team] || config["team"] || %{}
    team_slug = config[:default_team] || team_info[:slug] || team_info["slug"]

    cond do
      is_nil(token) or token == "" ->
        {:error, :missing_master_api_token}

      is_nil(team_slug) or team_slug == "" ->
        {:error, :team_not_available}

      true ->
        with {:ok, repo_metadata} <- Git.metadata(requested_workspace),
             {:ok, assignment} <- resolve_init_assignment(repo_metadata.repo_path),
             :ok <- validate_assignment_remote(assignment, repo_metadata.remote_url),
             :ok <-
               initialize_workspace(
                 repo_metadata.repo_path,
                 config,
                 team_info,
                 team_slug,
                 assignment
               ) do
          :ok
        end
    end
  end

  defp resolve_init_assignment(workspace_path) do
    case Config.load_pending_assignment() do
      assignment when is_map(assignment) ->
        normalize_assignment(assignment)

      nil ->
        workspace_config = Config.load_workspace_config(workspace_path)

        project = %{
          "id" => workspace_config[:project_id] || workspace_config["project_id"],
          "name" => workspace_config[:project_name] || workspace_config["project_name"],
          "git_remote_url" =>
            workspace_config[:project_remote_url] || workspace_config["project_remote_url"]
        }

        team = %{
          "id" => workspace_config[:team_id] || workspace_config["team_id"],
          "name" => workspace_config[:team_name] || workspace_config["team_name"],
          "slug" => workspace_config[:team_slug] || workspace_config["team_slug"]
        }

        normalize_assignment(%{
          "team" => team,
          "project" => project,
          "assignment" => %{
            "team_id" => team["id"],
            "project_id" => project["id"]
          }
        })
    end
  end

  defp normalize_assignment(assignment) do
    team = assignment[:team] || assignment["team"] || %{}
    project = assignment[:project] || assignment["project"] || %{}
    assignment_data = assignment[:assignment] || assignment["assignment"] || %{}

    project_id =
      project[:id] || project["id"] || assignment_data[:project_id] ||
        assignment_data["project_id"]

    project_name = project[:name] || project["name"]

    project_remote_url =
      project[:git_remote_url] || project["git_remote_url"] || project[:remote_url] ||
        project["remote_url"]

    cond do
      is_nil(project_id) or project_id == "" ->
        {:error, :invalid_project_assignment}

      is_nil(project_name) or project_name == "" ->
        {:error, :invalid_project_assignment}

      is_nil(project_remote_url) or project_remote_url == "" ->
        {:error, :invalid_project_assignment}

      true ->
        {:ok,
         %{
           team: team,
           project: %{
             "id" => project_id,
             "name" => project_name,
             "git_remote_url" => project_remote_url
           },
           assignment: assignment_data
         }}
    end
  end

  defp validate_assignment_remote(assignment, actual_remote_url) do
    expected_remote_url = assignment.project["git_remote_url"]

    cond do
      is_nil(actual_remote_url) or actual_remote_url == "" ->
        {:error, {:repository_remote_missing, expected_remote_url}}

      Git.remote_matches?(expected_remote_url, actual_remote_url) ->
        :ok

      true ->
        {:error, {:repository_mismatch, expected_remote_url, actual_remote_url}}
    end
  end

  defp initialize_workspace(workspace_path, config, team_info, team_slug, assignment) do
    project_data = assignment.project
    project_remote_url = project_data["git_remote_url"]
    invited_team = assignment[:team] || assignment["team"] || %{}

    team_data = %{
      "id" => invited_team[:id] || invited_team["id"] || team_info[:id] || team_info["id"],
      "name" =>
        invited_team[:name] || invited_team["name"] || team_info[:name] || team_info["name"] ||
          team_slug,
      "slug" => invited_team[:slug] || invited_team["slug"] || team_slug
    }

    team_slug = team_data["slug"]

    with {:ok, _workspace_file} <-
           Config.save_workspace_config(workspace_path, %{
             workspace_path: workspace_path,
             team: team_data,
             project: project_data
           }) do
      new_workspace_mapping = %{
        path: workspace_path,
        team_slug: team_slug,
        project_slug: project_data["id"],
        remote_url: project_remote_url
      }

      updated_mappings =
        config
        |> Map.get(:workspace_mappings, [])
        |> Enum.reject(fn mapping ->
          (mapping[:path] || mapping["path"]) == workspace_path
        end)
        |> Kernel.++([new_workspace_mapping])

      updated_config = Map.put(config, :workspace_mappings, updated_mappings)
      Config.save!(updated_config)
      Config.clear_pending_assignment!()

      IO.puts("")
      IO.puts("────────────────────────────────────────────")
      IO.puts("")
      IO.puts(IO.ANSI.green() <> "✓ Workspace initialized" <> IO.ANSI.reset())
      IO.puts("")

      Formatter.print_table(
        headers: ["TEAM", "PROJECT", "LOCAL DIR."],
        rows: [[team_data["name"], project_data["name"], workspace_path]]
      )

      IO.puts("")
      :ok
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
    config = Config.load() |> merge_cli_overrides(opts)

    if is_nil(invite_token) do
      IO.puts(:stderr, "Error: Missing invite token. Usage: devpulse login --token <your_token>")
      System.halt(1)
    end

    case authenticate_machine(config.server_url, invite_token) do
      {:ok, %{token: token, team: team, project: project, assignment: assignment}} ->
        current_config = Config.load()

        current_config
        |> Map.put(:token, token)
        |> Map.put(:team, team)
        |> Map.put(:default_team, team["slug"] || team[:slug])
        |> Config.save!()

        Config.save_pending_assignment!(%{
          "team" => team,
          "project" => project,
          "assignment" => assignment
        })

        IO.puts(
          "🎉 You have successfully logged in for team '#{team["name"]}' and project '#{project["name"]}'! Run `devpulse init` inside the assigned repository."
        )

      {:ok, :retrigger, %{"verification_url" => url, "pairing_code" => code}} ->
        base_url = config.server_url

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
          {:ok,
           %{"token" => token, "team" => team, "project" => project, "assignment" => assignment}} ->
            config_to_save =
              Config.load()
              |> Map.put(:token, token)
              |> Map.put(:team, team)
              |> Map.put(:default_team, team["slug"] || team[:slug])

            Config.save!(config_to_save)

            Config.save_pending_assignment!(%{
              "team" => team,
              "project" => project,
              "assignment" => assignment
            })

            IO.puts("""

            \e[32m\e[1m🎉 Successfully re-authenticated!\e[0m
            Team: #{team["name"]}
            Project: #{project["name"]}
            Run `devpulse init` inside the assigned repository.
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

  # defp run_team_link(args) do
  #   {opts, positional, _} =
  #     OptionParser.parse(args, switches: [workspace: :string], aliases: [w: :workspace])
  #   case positional do
  #     [team_slug] ->
  #       workspace = Path.expand(Keyword.get(opts, :workspace, File.cwd!()))
  #       remote_url = Git.remote_url(workspace)
  #       case Workspace.link_team(workspace, team_slug, remote_url) do
  #         {:ok, :linked, _path} ->
  #           IO.puts("Linked team #{team_slug} to #{workspace}")
  #           :ok
  #         {:ok, :already_linked, _path} ->
  #           IO.puts("Workspace #{workspace} is already linked to team #{team_slug}")
  #           :ok
  #         {:error, reason} ->
  #           {:error, reason}
  #       end
  #     _ ->
  #       {:error, :team_link_requires_a_team_slug}
  #   end
  # end

  defp run_whoami(args) do
    {opts, _, _} =
      OptionParser.parse(args, switches: common_switches(), aliases: common_aliases())

    workspace = workspace_root(opts)
    config = Config.load() |> merge_cli_overrides(opts)

    with {:ok, team_slug} <- resolve_team_choice(workspace, opts, config),
         {:ok, project_info} <- Workspace.resolve_project(workspace) do
      session_file = Config.state_file(workspace, project_info.project_id, "session.json")
      session = Session.load(session_file)

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

    with {:ok, team_slug} <- resolve_team_choice(workspace, opts, config),
         {:ok, project_info} <- Workspace.resolve_project(workspace) do
      session_file = Config.state_file(workspace, project_info.project_id, "session.json")
      buffer_file = Config.state_file(workspace, project_info.project_id, "buffer.ndjson")
      lock_file = Lifecycle.lock_file(workspace, project_info.project_id)
      session = Session.load(session_file)
      buffered = Buffer.load(buffer_file)
      lifecycle = Lifecycle.status(lock_file)

      Formatter.print_table(
        title: "DevPulse Status",
        headers: ["PROPERTY", "VALUE"],
        rows: [
          ["Server URL", config.server_url],
          ["Workspace", workspace],
          ["Team", team_slug],
          ["Agent Lock", format_lifecycle(lifecycle)],
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

  defp format_lifecycle({:running, pid}), do: "running (PID #{pid})"
  defp format_lifecycle(:not_running), do: "not running"
  defp format_lifecycle(:stale), do: Formatter.warning("stale lock")
  defp format_lifecycle(:invalid), do: Formatter.warning("invalid lock")

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

    config =
      Config.load()
      |> merge_cli_overrides(opts)

    with {:ok, repo_metadata} <- Git.metadata(workspace),
         {:ok, team_slug} <-
           resolve_team_choice(workspace, repo_metadata, opts, config) do
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

  defp run_stop(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: common_switches(),
        aliases: common_aliases()
      )

    workspace = workspace_root(opts)

    with {:ok, project_info} <- Workspace.resolve_project(workspace),
         {:ok, result} <- Lifecycle.stop(workspace, project_info.project_id) do
      case result do
        :stopping -> IO.puts("Stopping DevPulse agent")
        :stale_lock_removed -> IO.puts("Removed stale DevPulse agent lock")
      end

      :ok
    else
      {:error, :not_running} ->
        IO.puts("DevPulse agent is not running")
        :ok

      {:error, :project_not_initialized} ->
        {:error, :project_not_initialized}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp authenticate_machine(base_url, invite_token) do
    if is_nil(invite_token) do
      {:error, "token is required, pass the invite token using the token flag"}
    else
      case Client.exchange_invite(base_url, invite_token) do
        {:ok,
         %{
           "status" => "success",
           "token" => pat,
           "team" => team,
           "project" => project,
           "assignment" => assignment
         }} ->
          {:ok, %{token: pat, team: team, project: project, assignment: assignment}}

        {:error, :unauthorized} ->
          Client.retrigger_auth(base_url, invite_token)

        {:error, {:http_error, 404, _body}} ->
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

      is_nil(config.token) or config.token == "" ->
        {:error, :missing_master_api_token}

      true ->
        :ok
    end
  end

  defp resolve_team_choice(workspace, opts, config) do
    with {:ok, repo_metadata} <- Git.metadata(workspace),
         {:ok, team_slug, _source} <-
           Workspace.resolve_team(
             workspace,
             repo_metadata,
             [team: Keyword.get(opts, :team)],
             config
           ) do
      {:ok, team_slug}
    end
  end

  defp resolve_team_choice(workspace, repo_metadata, opts, config) do
    case Workspace.resolve_team(
           workspace,
           repo_metadata,
           [team: Keyword.get(opts, :team)],
           config
         ) do
      {:ok, team_slug, _source} ->
        {:ok, team_slug}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp workspace_root(opts),
    do: Path.expand(Keyword.get(opts, :workspace, Keyword.get(opts, :path, File.cwd!())))

  defp scoped_state_files(workspace) do
    case Workspace.resolve_project(workspace) do
      {:ok, project_info} ->
        {
          Config.state_file(workspace, project_info.project_id, "session.json"),
          Config.state_file(workspace, project_info.project_id, "buffer.ndjson")
        }

      _ ->
        {nil, nil}
    end
  end

  defp merge_cli_overrides(config, opts) do
    config
    |> maybe_put(:server_url, Keyword.get(opts, :server))
    |> maybe_put(:token, Keyword.get(opts, :token))
    |> maybe_put(:heartbeat_interval_ms, Keyword.get(opts, :heartbeat_interval_ms))
    |> maybe_put(:offline_retention_ms, Keyword.get(opts, :offline_retention_ms))
    |> maybe_put(:max_buffer_events, Keyword.get(opts, :max_buffer_events))
    |> maybe_put(:max_buffer_bytes, Keyword.get(opts, :max_buffer_bytes))
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
      max_buffer_events: :integer,
      max_buffer_bytes: :integer,
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

  defp format_value(nil), do: ""
  defp format_value(value), do: to_string(value)

  defp cast_config_value(:heartbeat_interval_ms, value), do: Config.parse_integer(value) || value
  defp cast_config_value(:offline_retention_ms, value), do: Config.parse_integer(value) || value
  defp cast_config_value(:max_buffer_events, value), do: Config.parse_integer(value) || value
  defp cast_config_value(:max_buffer_bytes, value), do: Config.parse_integer(value) || value
  defp cast_config_value(_key, value), do: value

  defp format_datetime(nil), do: "unknown"
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  # defp format_datetime(value) when is_binary(value), do: value

  defp format_reason({:not_git_repo, workspace}), do: "#{workspace} is not a git repository"
  defp format_reason(:team_required), do: "workspace team selection is required"

  defp format_reason(:already_running),
    do: "a DevPulse agent is already running for this workspace"

  defp format_reason(:project_not_initialized),
    do: "workspace is not initialized; run devpulse init"

  defp format_reason({:ambiguous_team, teams}),
    do: "ambiguous team mapping: #{Enum.join(teams, ", ")}"

  defp format_reason({:workspace_team_conflict, existing_team, requested_team}),
    do: "workspace is already linked to #{existing_team}; cannot link #{requested_team}"

  defp format_reason(:missing_master_api_token), do: "master API token is missing"

  defp format_reason(:team_not_available),
    do: "no authenticated team is available; run login again"

  defp format_reason({:no_projects, team}), do: "no repositories found for team: #{team}"

  defp format_reason({:project_fetch_failed, reason}),
    do: "failed to fetch repositories: #{format_reason(reason)}"

  defp format_reason(:invalid_project_selection),
    do: "the selected repository is no longer available"

  defp format_reason(:invalid_project_response), do: "server returned incomplete repository data"

  defp format_reason(:invalid_project_assignment),
    do: "login did not return a complete project assignment"

  defp format_reason({:repository_remote_missing, expected_remote}),
    do: "the current repository has no origin remote; expected #{expected_remote}"

  defp format_reason({:repository_mismatch, expected_remote, actual_remote}),
    do:
      "the current repository does not match the repository in the invitation\nInvited repository: #{expected_remote}\nCurrent repository: #{actual_remote}"

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

  # defp persist_team_link(workspace, team_slug) do
  #   remote_url = Git.remote_url(workspace)
  #   case Workspace.link_team(workspace, team_slug, remote_url) do
  #     {:ok, _status, _path} -> :ok
  #     {:error, reason} -> {:error, reason}
  #   end
  # end

  defp config_key_atom(key) do
    case String.trim(key) do
      "server_url" -> :server_url
      "token" -> :token
      "default_team" -> :default_team
      "heartbeat_interval_ms" -> :heartbeat_interval_ms
      "offline_retention_ms" -> :offline_retention_ms
      "max_buffer_events" -> :max_buffer_events
      "max_buffer_bytes" -> :max_buffer_bytes
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