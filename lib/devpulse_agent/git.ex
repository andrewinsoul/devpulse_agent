defmodule DevpulseAgent.Git do
  @moduledoc "Reads local Git repository metadata."

  defp repo_root do
    case System.cmd("git", ["rev-parse", "--show-toplevel"], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {_, _} -> nil
    end
  end

  defp current_branch do
    case System.cmd("git", ["branch", "--show-current"], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {_, _} -> nil
    end
  end

  def has_uncommitted_changes? do
    case System.cmd("git", ["status", "--porcelain"], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output) != ""
      {_, _} -> false
    end
  end

  @doc "Fetches all metadata as a map."
  def get_metadata do
    root = repo_root()

    if root do
      %{
        project_name: Path.basename(root),
        repo_path: root,
        branch: current_branch(),
        has_changes: has_uncommitted_changes?()
      }
    else
      nil
    end
  end
end
