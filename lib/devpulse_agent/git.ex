defmodule DevpulseAgent.Git do
  @moduledoc """
  Git metadata helpers for the current workspace.
  """

  def metadata(path \\ File.cwd!()) do
    with {:ok, root} <- repo_root(path) do
      {:ok,
       %{
         project_name: Path.basename(root),
         repo_path: root,
         branch: current_branch(root),
         remote_url: remote_url(root),
         has_uncommitted_changes: has_uncommitted_changes?(root)
       }}
    end
  end

  def ensure_git_exclude(workspace_root, pattern \\ ".devpulse.toml") do
    exclude_file =
      Path.join([workspace_root, ".git", "info", "exclude"])

    with :ok <- File.mkdir_p(Path.dirname(exclude_file)) do
      contents =
        case File.read(exclude_file) do
          {:ok, data} -> data
          {:error, :enoent} -> ""
          {:error, reason} -> return_error(reason)
        end

      entries =
        contents
        |> String.split("\n", trim: true)

      unless pattern in entries do
        new_contents =
          contents
          |> String.trim_trailing()
          |> Kernel.<>("\n")
          |> Kernel.<>(pattern)
          |> Kernel.<>("\n")

        File.write!(exclude_file, new_contents)
      end

      :ok
    end
  end

  defp return_error(reason), do: {:error, reason}

  def repo_root(path \\ File.cwd!()) do
    run_git(path, ["rev-parse", "--show-toplevel"])
  end

  def current_branch(path \\ File.cwd!()) do
    case run_git(path, ["branch", "--show-current"]) do
      {:ok, branch} -> branch
      _ -> nil
    end
  end

  def remote_url(path \\ File.cwd!()) do
    case run_git(path, ["remote", "get-url", "origin"]) do
      {:ok, url} ->
        url

      _ ->
        case run_git(path, ["config", "--get", "remote.origin.url"]) do
          {:ok, url} -> url
          _ -> nil
        end
    end
  end

  def has_uncommitted_changes?(path \\ File.cwd!()) do
    case System.cmd("git", ["status", "--porcelain"], cd: path, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output) != ""
      _ -> false
    end
  end

  defp run_git(path, args) do
    case System.cmd("git", args, cd: path, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, String.trim(output)}

      _ ->
        {:error, :not_git_repo}
    end
  end
end
