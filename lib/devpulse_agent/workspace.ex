defmodule DevpulseAgent.Workspace do
  @moduledoc """
  Workspace discovery and team resolution.
  """

  alias DevpulseAgent.Config
  alias DevpulseAgent.Git

  def current_workspace(path \\ File.cwd!()) do
    case Git.metadata(path) do
      {:ok, metadata} -> {:ok, metadata}
      {:error, _} = error -> error
    end
  end

  def resolve_team(workspace_root, opts \\ [], config \\ Config.load()) do
    explicit_team = Keyword.get(opts, :team)
    local_config = Config.load_workspace_config(workspace_root)

    with {:ok, repo_metadata} <- Git.metadata(workspace_root) do
      if is_binary(explicit_team) and explicit_team != "" do
        case local_team(local_config) do
          nil ->
            {:ok, explicit_team, :explicit}

          ^explicit_team ->
            {:ok, explicit_team, :explicit}

          existing_team ->
            {:error, {:workspace_team_conflict, existing_team, explicit_team}}
        end
      else
        candidates =
          [
            local_team(local_config) && {:local_config, local_team(local_config)},
            path_mapped_team(workspace_root, config),
            remote_mapped_team({:ok, repo_metadata}, config)
          ]
          |> Enum.reject(&is_nil/1)

        case unique_team_choice(candidates) do
          {:ok, team_slug, source} ->
            {:ok, team_slug, source}

          {:error, :team_required} ->
            case default_team(config) do
              nil -> {:error, :team_required}
              {:default_config, team_slug} -> {:ok, team_slug, :default_config}
            end

          {:error, reason} ->
            {:error, reason}
        end
      end
    else
      {:error, :not_git_repo} ->
        {:error, {:not_git_repo, workspace_root}}
    end
  end

  def link_team(workspace_root, team_slug, remote_url \\ nil) do
    with {:ok, _repo_metadata} <- Git.metadata(workspace_root) do
      current_config = Config.load_workspace_config(workspace_root)
      current_team = local_team(current_config)
      resolved_remote_url = remote_url || current_remote_url(current_config)

      cond do
        is_nil(current_team) ->
          with {:ok, path} <-
                 Config.save_workspace_config(workspace_root, %{
                   team_slug: team_slug,
                   remote_url: resolved_remote_url,
                   workspace_path: Path.expand(workspace_root)
                 }),
               :ok <- Git.ensure_git_exclude(workspace_root),
               :ok <- Config.put_workspace_mapping(workspace_root, team_slug, resolved_remote_url) do
            {:ok, :linked, path}
          end

        current_team == team_slug ->
          {:ok, :already_linked, Config.workspace_config_file(workspace_root)}

        true ->
          {:error, {:workspace_team_conflict, current_team, team_slug}}
      end
    else
      {:error, :not_git_repo} ->
        {:error, {:not_git_repo, workspace_root}}
    end
  end

  def select_team(workspace_root, team_slug, remote_url \\ nil) do
    link_team(workspace_root, team_slug, remote_url)
  end

  def select_team!(workspace_root, team_slug, remote_url \\ nil) do
    case link_team(workspace_root, team_slug, remote_url) do
      {:ok, _status, _path} -> :ok
      {:error, reason} -> raise "failed to link team: #{inspect(reason)}"
    end
  end

  def workspace_mapping_summary(workspace_root) do
    local_config = Config.load_workspace_config(workspace_root)

    %{
      workspace_root: Path.expand(workspace_root),
      team_slug: local_team(local_config),
      remote_url: local_config[:remote_url] || local_config["remote_url"]
    }
  end

  defp local_team(config) do
    config[:team_slug] || config["team_slug"]
  end

  defp current_remote_url(config) do
    config[:remote_url] || config["remote_url"]
  end

  defp default_team(config) do
    case config.default_team do
      nil -> nil
      team -> {:default_config, team}
    end
  end

  defp path_mapped_team(workspace_root, config) do
    root = Path.expand(workspace_root)

    config.workspace_mappings
    |> Enum.filter(fn mapping -> mapping.path == root and mapping.team_slug end)
    |> Enum.map(&{:workspace_mapping, &1.team_slug})
    |> case do
      [] -> nil
      [single] -> single
      multiple -> {:ambiguous_workspace_mapping, Enum.map(multiple, fn {_, team} -> team end)}
    end
  end

  defp remote_mapped_team({:ok, metadata}, config) do
    remote_url = metadata.remote_url

    if is_binary(remote_url) and remote_url != "" do
      config.workspace_mappings
      |> Enum.filter(fn mapping -> mapping.remote_url == remote_url and mapping.team_slug end)
      |> Enum.map(&{:remote_mapping, &1.team_slug})
      |> case do
        [] -> nil
        [single] -> single
        multiple -> {:ambiguous_remote_mapping, Enum.map(multiple, fn {_, team} -> team end)}
      end
    end
  end

  defp unique_team_choice(candidates) do
    matches =
      candidates
      |> Enum.flat_map(fn
        {source, team} when is_binary(team) -> [{source, team}]
        {reason, teams} when is_list(teams) -> [{reason, teams}]
        _ -> []
      end)

    conflicts =
      matches
      |> Enum.filter(fn
        {_source, teams} when is_list(teams) -> true
        _ -> false
      end)

    cond do
      conflicts != [] ->
        {:error, {:ambiguous_team, Enum.flat_map(conflicts, fn {_source, teams} -> teams end)}}

      matches == [] ->
        {:error, :team_required}

      true ->
        teams = matches |> Enum.map(fn {_, team} -> team end) |> Enum.uniq()

        case teams do
          [team_slug] ->
            {:ok, team_slug,
             Enum.find_value(matches, fn {source, team} -> if team == team_slug, do: source end)}

          [] ->
            {:error, :team_required}

          multiple ->
            {:error, {:ambiguous_team, multiple}}
        end
    end
  end
end
