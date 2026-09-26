defmodule DevpulseAgent.Config do
  @moduledoc """
  Local configuration and persistence helpers for the CLI.
  """

  @config_filename "config.toml"
  @session_filename "session.json"
  @buffer_filename "buffer.ndjson"
  @pending_assignment_filename "pending_assignment.json"

  @default_heartbeat_interval_ms 5_000
  @default_offline_retention_ms 24 * 60 * 60 * 1000
  @default_max_buffer_events 10_000
  @default_max_buffer_bytes 10 * 1024 * 1024

  def default_config do
    %{
      server_url: System.get_env("DEVPULSE_SERVER_URL", "http://localhost:4000/api/v1"),
      token: empty_to_nil(System.get_env("DEVPULSE_TOKEN")),
      default_team: empty_to_nil(System.get_env("DEVPULSE_TEAM")),
      team: %{},
      heartbeat_interval_ms:
        env_int("DEVPULSE_HEARTBEAT_INTERVAL_MS", @default_heartbeat_interval_ms),
      offline_retention_ms:
        env_int("DEVPULSE_OFFLINE_RETENTION_MS", @default_offline_retention_ms),
      max_buffer_events: env_int("DEVPULSE_MAX_BUFFER_EVENTS", @default_max_buffer_events),
      max_buffer_bytes: env_int("DEVPULSE_MAX_BUFFER_BYTES", @default_max_buffer_bytes),
      log_level: System.get_env("DEVPULSE_LOG_LEVEL", "info"),
      workspace_mappings: [],
      team_mappings: []
    }
  end

  def config_dir do
    case Application.get_env(:devpulse_agent, :config_dir) do
      path when is_binary(path) ->
        Path.expand(path)

      _ ->
        default_config_dir()
    end
  end

  defp default_config_dir do
    case :os.type() do
      {:win32, _} ->
        Path.join(System.get_env("APPDATA", System.user_home!()), "DevPulse")

      {:unix, :darwin} ->
        Path.join(System.user_home!(), "Library/Application Support/DevPulse")

      _ ->
        Path.join(System.user_home!(), ".config/devpulse")
    end
  end

  def config_file, do: Path.join(config_dir(), @config_filename)
  def session_file, do: Path.join(config_dir(), @session_filename)
  def buffer_file, do: Path.join(config_dir(), @buffer_filename)
  def pending_assignment_file, do: Path.join(config_dir(), @pending_assignment_filename)

  def state_dir(workspace_root, project_id) do
    workspace_key =
      workspace_root
      |> Path.expand()
      |> then(fn value -> :crypto.hash(:sha256, value) end)
      |> Base.encode16(case: :lower)

    project_key =
      project_id
      |> to_string()
      |> then(fn value -> :crypto.hash(:sha256, value) end)
      |> Base.encode16(case: :lower)

    Path.join([config_dir(), "workspaces", workspace_key <> "-" <> project_key])
  end

  def state_file(workspace_root, project_id, filename) do
    Path.join(state_dir(workspace_root, project_id), filename)
  end

  def workspace_config_file(workspace_root), do: Path.join(workspace_root, ".devpulse.toml")

  def load do
    config =
      case File.read(config_file()) do
        {:ok, contents} -> parse_config(contents)
        {:error, :enoent} -> default_config()
        {:error, _reason} -> default_config()
      end

    merge_defaults(config)
  rescue
    _reason ->
      quarantine_corrupt_file(config_file())
      merge_defaults(default_config())
  end

  def normalize(config) when is_map(config), do: merge_defaults(config)

  def save!(config) when is_map(config) do
    ensure_config_dir!()

    config
    |> merge_defaults()
    |> encode_config()
    |> write_secure!(config_file())
  end

  def update!(fun) when is_function(fun, 1) do
    load()
    |> fun.()
    |> save!()
  end

  def set(key, value) when is_atom(key) do
    update!(fn config -> Map.put(config, key, value) end)
  end

  def get(key) when is_atom(key) do
    load() |> Map.get(key)
  end

  def ensure_gitignored(workspace_root) do
    gitignore_path = Path.join(workspace_root, ".gitignore")

    ignore_entries = [
      ".devpulse.toml",
      ".devpulse/"
    ]

    if File.exists?(gitignore_path) do
      content = File.read!(gitignore_path)

      missing_entries =
        Enum.reject(ignore_entries, fn entry ->
          String.contains?(content, entry)
        end)

      unless Enum.empty?(missing_entries) do
        appendix =
          "\n# DevPulse local configuration\n" <> Enum.join(missing_entries, "\n") <> "\n"

        File.write!(gitignore_path, content <> appendix)
      end
    else
      # Create .gitignore if none exists in the directory
      content = "# DevPulse local configuration\n" <> Enum.join(ignore_entries, "\n") <> "\n"
      File.write!(gitignore_path, content)
    end

    :ok
  end

  def load_workspace_config(workspace_root) do
    file = workspace_config_file(workspace_root)

    case File.read(file) do
      {:ok, contents} -> parse_config(contents)
      {:error, _reason} -> %{}
    end
  rescue
    _reason ->
      quarantine_corrupt_file(workspace_config_file(workspace_root))
      %{}
  end

  # def save_workspace_config!(workspace_root, attrs) when is_map(attrs) do
  #   case save_workspace_config(workspace_root, attrs) do
  #     {:ok, _path} -> :ok
  #     {:error, reason} -> raise "failed to save workspace config: #{inspect(reason)}"
  #   end
  # end

  def save_workspace_config(workspace_root, attrs) when is_map(attrs) do
    with :ok <- ensure_workspace_dir(workspace_root) do
      file = workspace_config_file(workspace_root)
      current = load_workspace_config(workspace_root)

      updated =
        current
        |> Map.merge(Map.take(attrs, [:workspace_path, :remote_url]))
        |> Map.put(:team, attrs[:team] || %{})
        |> Map.put(:project, attrs[:project] || %{})

      case File.write(file, encode_workspace_config(updated)) do
        :ok ->
          secure_file!(file)
          ensure_gitignored(workspace_root)
          {:ok, file}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def put_workspace_mapping(workspace_root, team_slug, remote_url \\ nil) do
    update!(fn config ->
      mapping = %{
        path: Path.expand(workspace_root),
        team_slug: team_slug,
        remote_url: remote_url
      }

      mappings =
        config.workspace_mappings
        |> Enum.reject(fn existing ->
          existing.path == mapping.path or
            (remote_url && existing.remote_url == remote_url)
        end)

      Map.put(config, :workspace_mappings, mappings ++ [mapping])
    end)

    :ok
  end

  def load_session(file \\ session_file()) do
    case File.read(file) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, session} when is_map(session) -> stringify_keys(session)
          _ -> quarantine_corrupt_file(file)
        end

      {:error, :enoent} ->
        nil

      {:error, _reason} ->
        nil
    end
  end

  def save_session!(session, file \\ session_file()) when is_map(session) do
    session
    |> stringify_keys()
    |> Jason.encode!(pretty: true)
    |> write_secure!(file)
  end

  def clear_session!(file \\ session_file()) do
    remove_file(file)
  end

  def load_pending_assignment(file \\ pending_assignment_file()) do
    case File.read(file) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, assignment} when is_map(assignment) -> assignment
          _ -> quarantine_corrupt_file(file)
        end

      {:error, :enoent} ->
        nil

      {:error, _reason} ->
        nil
    end
  end

  def save_pending_assignment!(assignment, file \\ pending_assignment_file())
      when is_map(assignment) do
    assignment
    |> stringify_keys()
    |> Jason.encode!(pretty: true)
    |> write_secure!(file)
  end

  def clear_pending_assignment!(file \\ pending_assignment_file()) do
    remove_file(file)
  end

  def load_buffer(file \\ buffer_file()) do
    case File.read(file) do
      {:ok, contents} ->
        {events, malformed?} =
          contents
          |> String.split("\\n", trim: true)
          |> Enum.reduce({[], false}, fn line, {events, malformed?} ->
            case Jason.decode(line) do
              {:ok, event} when is_map(event) ->
                {[stringify_keys(event) | events], malformed?}

              _ ->
                {events, true}
            end
          end)

        if malformed? do
          quarantine_corrupt_file(file)
        end

        Enum.reverse(events)

      {:error, :enoent} ->
        []

      {:error, _reason} ->
        []
    end
  end

  def save_buffer!(events, file \\ buffer_file()) when is_list(events) do
    serialized =
      events
      |> Enum.map(&Jason.encode!/1)
      |> Enum.join("\\n")

    contents =
      case serialized do
        "" -> ""
        _ -> serialized <> "\\n"
      end

    write_secure!(file, contents)
  end

  def append_buffer_event!(event, file \\ buffer_file()) when is_map(event) do
    ensure_parent_dir!(file)

    payload = Jason.encode!(stringify_keys(event)) <> "\\n"

    case File.write(file, payload, [:append]) do
      :ok ->
        secure_file!(file)
        :ok

      {:error, reason} ->
        raise File.Error, reason: reason, action: "write", path: file
    end
  end

  def delete_buffer!(file \\ buffer_file()) do
    remove_file(file)
  end

  def parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  def parse_integer(value) when is_integer(value), do: value

  defp maybe_push_workspace(workspaces, nil), do: workspaces
  defp maybe_push_workspace(workspaces, %{} = workspace), do: [workspace | workspaces]

  defp parse_config(content) do
    {root, team, workspace_entries} =
      content
      |> String.split("\n")
      |> Enum.reduce({%{}, %{}, [], :root, nil}, fn raw_line,
                                                    {root, team, workspaces, section, current_ws} ->
        line = String.trim(raw_line)

        cond do
          line == "" or String.starts_with?(line, "#") ->
            {root, team, workspaces, section, current_ws}

          line == "[[team]]" or line == "[team]" ->
            workspaces = maybe_push_workspace(workspaces, current_ws)
            {root, team, workspaces, :team, nil}

          line == "[[workspace]]" ->
            workspaces = maybe_push_workspace(workspaces, current_ws)
            {root, team, workspaces, :workspace, %{}}

          String.starts_with?(line, "[") and String.ends_with?(line, "]") ->
            workspaces = maybe_push_workspace(workspaces, current_ws)
            {root, team, workspaces, :other, nil}

          String.contains?(line, "=") ->
            {key, value} = parse_assignment(line)
            parsed_value = parse_value(value)
            atom_key = key_to_atom(key)

            case section do
              :root ->
                {Map.put(root, atom_key, parsed_value), team, workspaces, section, nil}

              :team ->
                updated_team = Map.put(team, atom_key, parsed_value)
                {root, updated_team, workspaces, section, nil}

              :workspace ->
                updated_ws = Map.put(current_ws || %{}, atom_key, parsed_value)
                {root, team, workspaces, section, updated_ws}

              _ ->
                {root, team, workspaces, section, nil}
            end

          true ->
            {root, team, workspaces, section, current_ws}
        end
      end)
      |> then(fn {root, team, workspaces, _section, current_ws} ->
        {root, team, maybe_push_workspace(workspaces, current_ws)}
      end)

    root
    |> Map.put(:team, team)
    |> Map.merge(%{
      workspace_mappings: Enum.map(workspace_entries, &normalize_workspace_mapping/1)
    })
    |> merge_defaults()
  end

  defp encode_config(config) do
    team = config[:team] || config["team"] || %{}

    top_level_keys = [
      :server_url,
      :token,
      :default_team,
      :heartbeat_interval_ms,
      :offline_retention_ms,
      :max_buffer_events,
      :max_buffer_bytes,
      :log_level
    ]

    top_level =
      top_level_keys
      |> Enum.flat_map(fn key ->
        case Map.get(config, key) do
          nil -> []
          value -> ["#{Atom.to_string(key)} = #{encode_value(value)}"]
        end
      end)

    # Encode user's authenticated team block
    team_block =
      if team != %{} do
        [
          "",
          "[[team]]",
          "id = #{encode_value(team[:id] || team["id"])}",
          "name = #{encode_value(team[:name] || team["name"])}",
          "slug = #{encode_value(team[:slug] || team["slug"])}"
        ]
      else
        []
      end

    workspace_blocks =
      (config[:workspace_mappings] || [])
      |> Enum.flat_map(fn mapping ->
        [
          "",
          "[[workspace]]",
          "path = #{encode_value(mapping[:path] || mapping["path"])}"
        ] ++
          optional_config_lines([
            {"team_slug", mapping[:team_slug] || mapping["team_slug"]},
            {"project_slug", mapping[:project_slug] || mapping["project_slug"]},
            {"remote_url", mapping[:remote_url] || mapping["remote_url"]}
          ])
      end)

    ([top_level] ++ [team_block] ++ [workspace_blocks])
    |> List.flatten()
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp optional_config_lines(entries) do
    Enum.flat_map(entries, fn {key, value} ->
      case value do
        nil -> []
        value -> ["#{key} = #{encode_value(value)}"]
      end
    end)
  end

  defp encode_workspace_config(config) do
    team = config[:team] || config["team"] || %{}
    project = config[:project] || config["project"] || %{}

    lines = [
      "workspace_path = #{encode_value(config[:workspace_path] || config["workspace_path"])}",
      "",
      "team_id = #{encode_value(team[:id] || team["id"])}",
      "team_name = #{encode_value(team[:name] || team["name"])}",
      "team_slug = #{encode_value(team[:slug] || team["slug"])}",
      "",
      "project_id = #{encode_value(project[:id] || project["id"])}",
      "project_name = #{encode_value(project[:name] || project["name"])}",
      "project_remote_url = #{encode_value(project[:git_remote_url] || project["git_remote_url"])}"
    ]

    Enum.join(lines, "\n") <> "\n"
  end

  defp parse_assignment(line) do
    [key, value] = String.split(line, "=", parts: 2)
    {String.trim(key), String.trim(value)}
  end

  defp parse_value(value) do
    cond do
      String.starts_with?(value, "\"") and String.ends_with?(value, "\"") ->
        value
        |> String.trim_leading("\"")
        |> String.trim_trailing("\"")
        |> String.replace("\\\"", "\"")
        |> String.replace("\\\\", "\\")

      value in ["true", "false"] ->
        value == "true"

      true ->
        case Integer.parse(value) do
          {integer, ""} -> integer
          _ -> value
        end
    end
  end

  defp encode_value(value) when is_binary(value) do
    "\"" <> escape_string(value) <> "\""
  end

  defp encode_value(value) when is_integer(value), do: Integer.to_string(value)
  defp encode_value(value) when is_boolean(value), do: to_string(value)
  defp encode_value(value), do: encode_value(to_string(value))

  defp escape_string(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp merge_defaults(config) do
    defaults = default_config()

    config
    |> Map.merge(defaults, fn
      :workspace_mappings, left, right ->
        normalize_workspace_mappings(List.wrap(left) ++ List.wrap(right))

      :team_mappings, left, right ->
        normalize_team_mappings(List.wrap(left) ++ List.wrap(right))

      _key, nil, default ->
        default

      _key, value, _default ->
        value
    end)
    |> Map.put_new(:workspace_mappings, [])
    |> Map.update!(:workspace_mappings, &normalize_workspace_mappings/1)
    |> Map.put_new(:team_mappings, [])
    |> Map.update!(:team_mappings, &normalize_team_mappings/1)
  end

  defp normalize_workspace_mappings(entries) when is_list(entries) do
    entries
    |> List.wrap()
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&normalize_workspace_mapping/1)
  end

  defp normalize_team_mappings(entries) when is_list(entries) do
    entries
    |> List.wrap()
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&normalize_team_mapping/1)
  end

  defp normalize_workspace_mapping(mapping) when is_map(mapping) do
    %{
      path: mapping[:path] || mapping["path"],
      team_slug: mapping[:team_slug] || mapping["team_slug"],
      project_slug: mapping[:project_slug] || mapping["project_slug"],
      remote_url: mapping[:remote_url] || mapping["remote_url"]
    }
  end

  defp normalize_team_mapping(mapping) when is_map(mapping) do
    %{
      team_id: mapping[:team_id] || mapping["team_id"],
      team_slug: mapping[:team_slug] || mapping["team_slug"],
      name: mapping[:name] || mapping["name"]
    }
  end

  defp key_to_atom(key) do
    case String.trim(key) do
      "server_url" -> :server_url
      "token" -> :token
      "default_team" -> :default_team
      "heartbeat_interval_ms" -> :heartbeat_interval_ms
      "offline_retention_ms" -> :offline_retention_ms
      "log_level" -> :log_level
      "project_slug" -> :project_slug
      "project_id" -> :project_id
      "team_slug" -> :team_slug
      "team_id" -> :team_id
      "team" -> :team
      "name" -> :name
      "slug" -> :slug
      "id" -> :id
      "remote_url" -> :remote_url
      "path" -> :path
      "workspace_path" -> :workspace_path
      other -> String.to_atom(other)
    end
  end

  defp ensure_config_dir! do
    File.mkdir_p!(config_dir())
  end

  defp ensure_parent_dir!(path) do
    path
    |> Path.dirname()
    |> File.mkdir_p!()
  end

  defp remove_file(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> raise File.Error, reason: reason, action: "delete", path: path
    end
  end

  defp quarantine_corrupt_file(path) do
    quarantine = path <> ".corrupt-" <> Integer.to_string(System.system_time(:second))

    case File.rename(path, quarantine) do
      :ok -> nil
      {:error, _reason} -> nil
    end
  end

  defp ensure_workspace_dir(workspace_root) do
    Path.expand(workspace_root)
    |> File.mkdir_p()
  end

  defp secure_file!(path) do
    if File.exists?(path) do
      File.chmod(path, 0o600)
    end
  end

  defp write_secure!(contents, path) do
    ensure_parent_dir!(path)
    temporary = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

    try do
      File.write!(temporary, contents)
      secure_file!(temporary)
      File.rename!(temporary, path)
      secure_file!(path)
    after
      File.rm(temporary)
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      Map.put(acc, to_string(key), stringify_value(value))
    end)
  end

  defp stringify_value(value) when is_map(value), do: stringify_keys(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value

  defp env_int(name, default) do
    case System.get_env(name) do
      nil ->
        default

      value ->
        case Integer.parse(value) do
          {integer, ""} -> integer
          _ -> default
        end
    end
  end
end