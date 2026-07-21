defmodule DevpulseAgent.Config do
  @moduledoc """
  Local configuration and persistence helpers for the CLI.
  """

  @config_filename "config.toml"
  @session_filename "session.json"
  @buffer_filename "buffer.ndjson"

  @default_heartbeat_interval_ms 5_000
  @default_offline_retention_ms 24 * 60 * 60 * 1000

  def default_config do
    %{
      server_url: System.get_env("api_base_url", "http://localhost:4000"),
      token: empty_to_nil(System.get_env("DEVPULSE_TOKEN")),
      default_team: empty_to_nil(System.get_env("DEVPULSE_TEAM")),
      heartbeat_interval_ms:
        env_int("DEVPULSE_HEARTBEAT_INTERVAL_MS", @default_heartbeat_interval_ms),
      offline_retention_ms:
        env_int("DEVPULSE_OFFLINE_RETENTION_MS", @default_offline_retention_ms),
      log_level: System.get_env("DEVPULSE_LOG_LEVEL", "info"),
      workspace_mappings: []
    }
  end

  def config_dir do
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

  def workspace_config_file(workspace_root), do: Path.join(workspace_root, ".devpulse.toml")

  def load do
    if File.exists?(config_file()) do
      config_file() |> File.read!() |> parse_config()
    else
      default_config()
    end
    |> merge_defaults()
  end

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

  def load_workspace_config(workspace_root) do
    file = workspace_config_file(workspace_root)

    if File.exists?(file) do
      File.read!(file) |> parse_config()
    else
      %{}
    end
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
      updated = Map.merge(current, Map.take(attrs, [:team_slug, :remote_url, :workspace_path]))

      case File.write(file, encode_workspace_config(updated)) do
        :ok ->
          secure_file!(file)
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

  def load_session do
    file = session_file()

    if File.exists?(file) do
      File.read!(file) |> Jason.decode!() |> stringify_keys()
    else
      nil
    end
  end

  def save_session!(session) when is_map(session) do
    ensure_config_dir!()

    session
    |> stringify_keys()
    |> Jason.encode!(pretty: true)
    |> write_secure!(session_file())
  end

  def clear_session! do
    File.rm(session_file())
    :ok
  end

  def load_buffer do
    file = buffer_file()

    if File.exists?(file) do
      file
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.flat_map(fn line ->
        case Jason.decode(line) do
          {:ok, event} -> [stringify_keys(event)]
          _ -> []
        end
      end)
    else
      []
    end
  end

  def save_buffer!(events) when is_list(events) do
    ensure_config_dir!()

    serialized =
      events
      |> Enum.map(&Jason.encode!/1)
      |> Enum.join("\n")

    contents =
      case serialized do
        "" -> ""
        _ -> serialized <> "\n"
      end

    write_secure!(buffer_file(), contents)
  end

  def append_buffer_event!(event) when is_map(event) do
    ensure_config_dir!()

    payload = Jason.encode!(stringify_keys(event)) <> "\n"
    File.write!(buffer_file(), payload, [:append])
    secure_file!(buffer_file())
  end

  def delete_buffer! do
    File.rm(buffer_file())
    :ok
  end

  def parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  def parse_integer(value) when is_integer(value), do: value

  defp parse_config(content) do
    {root, workspace_entries} =
      content
      |> String.split("\n")
      |> Enum.reduce({%{}, [], nil}, fn raw_line, {root, workspaces, current_workspace} ->
        line = String.trim(raw_line)

        cond do
          line == "" or String.starts_with?(line, "#") ->
            {root, workspaces, current_workspace}

          line == "[[workspace]]" ->
            workspaces = maybe_push_workspace(workspaces, current_workspace)
            {root, workspaces, %{}}

          String.starts_with?(line, "[") and String.ends_with?(line, "]") ->
            {root, maybe_push_workspace(workspaces, current_workspace), nil}

          String.contains?(line, "=") ->
            {key, value} = parse_assignment(line)
            parsed_value = parse_value(value)

            case current_workspace do
              nil -> {Map.put(root, key_to_atom(key), parsed_value), workspaces, nil}
              workspace -> {root, workspaces, Map.put(workspace, key_to_atom(key), parsed_value)}
            end

          true ->
            {root, workspaces, current_workspace}
        end
      end)
      |> then(fn {root, workspaces, current_workspace} ->
        {root, maybe_push_workspace(workspaces, current_workspace)}
      end)

    root
    |> Map.merge(%{
      workspace_mappings: Enum.map(workspace_entries, &normalize_workspace_mapping/1)
    })
    |> merge_defaults()
  end

  defp encode_config(config) do
    top_level_keys = [
      :server_url,
      :token,
      :default_team,
      :heartbeat_interval_ms,
      :offline_retention_ms,
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

    workspace_blocks =
      config.workspace_mappings
      |> Enum.flat_map(fn mapping ->
        [
          "",
          "[[workspace]]",
          "path = #{encode_value(mapping.path)}",
          "team_slug = #{encode_value(mapping.team_slug)}"
        ] ++
          case mapping.remote_url do
            nil -> []
            remote_url -> ["remote_url = #{encode_value(remote_url)}"]
          end
      end)

    ([top_level] ++ [workspace_blocks])
    |> List.flatten()
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp encode_workspace_config(config) do
    lines =
      []
      |> maybe_add_kv("team_slug", config[:team_slug])
      |> maybe_add_kv("remote_url", config[:remote_url])
      |> maybe_add_kv("workspace_path", config[:workspace_path] || config[:path])

    Enum.join(lines, "\n") <> "\n"
  end

  defp maybe_add_kv(lines, _key, nil), do: lines

  defp maybe_add_kv(lines, key, value) do
    lines ++ ["#{key} = #{encode_value(value)}"]
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

      _key, nil, default ->
        default

      _key, value, _default ->
        value
    end)
    |> Map.put_new(:workspace_mappings, [])
    |> Map.update!(:workspace_mappings, &normalize_workspace_mappings/1)
  end

  defp normalize_workspace_mappings(entries) when is_list(entries) do
    entries
    |> List.wrap()
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&normalize_workspace_mapping/1)
  end

  defp normalize_workspace_mapping(mapping) when is_map(mapping) do
    %{
      path: mapping[:path] || mapping["path"],
      team_slug: mapping[:team_slug] || mapping["team_slug"],
      remote_url: mapping[:remote_url] || mapping["remote_url"]
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
      "team_slug" -> :team_slug
      "remote_url" -> :remote_url
      "path" -> :path
      "workspace_path" -> :workspace_path
      other -> String.to_atom(other)
    end
  end

  defp maybe_push_workspace(workspaces, nil), do: workspaces
  defp maybe_push_workspace(workspaces, %{} = workspace), do: [workspace | workspaces]

  defp ensure_config_dir! do
    File.mkdir_p!(config_dir())
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
    File.write!(path, contents)
    secure_file!(path)
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
