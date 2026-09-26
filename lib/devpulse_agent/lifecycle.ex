defmodule DevpulseAgent.Lifecycle do
  @moduledoc """
  Cross-process lifecycle and single-instance coordination for an agent workspace.
  """

  alias DevpulseAgent.Config

  @lock_filename "agent.lock"

  def lock_file(workspace_root, project_id) do
    Config.state_file(workspace_root, project_id, @lock_filename)
  end

  def acquire(workspace_root, project_id) do
    file = lock_file(workspace_root, project_id)
    ensure_parent_dir!(file)
    acquire_file(file)
  end

  def release(file) when is_binary(file) do
    case File.read(file) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, %{"os_pid" => pid}} ->
            if pid == os_pid() do
              File.rm(file)
            end

            :ok

          _ ->
            :ok
        end

      {:error, :enoent} ->
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  def status(file) when is_binary(file) do
    case read_lock(file) do
      {:ok, %{"os_pid" => pid}} ->
        if running?(pid), do: {:running, pid}, else: :stale

      {:error, :enoent} ->
        :not_running

      {:error, :invalid_lock} ->
        :invalid
    end
  end

  def stop(workspace_root, project_id) do
    file = lock_file(workspace_root, project_id)

    case read_lock(file) do
      {:ok, %{"os_pid" => pid}} ->
        if running?(pid) do
          terminate(pid)
          {:ok, :stopping}
        else
          File.rm(file)
          {:ok, :stale_lock_removed}
        end

      {:error, :enoent} ->
        {:error, :not_running}

      {:error, :invalid_lock} ->
        File.rm(file)
        {:error, :invalid_lock}
    end
  end

  def running?(pid) when is_binary(pid) do
    case :os.type() do
      {:win32, _} ->
        case System.cmd("tasklist", ["/FI", "PID eq #{pid}"], stderr_to_stdout: true) do
          {output, 0} -> String.contains?(output, pid)
          _ -> false
        end

      _ ->
        match?({_, 0}, System.cmd("kill", ["-0", pid], stderr_to_stdout: true))
    end
  rescue
    _ -> false
  end

  defp acquire_file(file) do
    payload =
      Jason.encode!(%{
        "os_pid" => os_pid(),
        "started_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      })

    case File.write(file, payload, [:write, :exclusive]) do
      :ok ->
        {:ok, file}

      {:error, :eexist} ->
        case read_lock(file) do
          {:ok, %{"os_pid" => pid}} ->
            if pid == os_pid() do
              {:error, :already_running}
            else
              if running?(pid) do
                {:error, :already_running}
              else
                File.rm(file)
                acquire_file(file)
              end
            end

          _ ->
            File.rm(file)
            acquire_file(file)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_lock(file) do
    case File.read(file) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, %{} = lock} -> {:ok, lock}
          _ -> {:error, :invalid_lock}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp terminate(pid) do
    case :os.type() do
      {:win32, _} ->
        System.cmd("taskkill", ["/PID", pid, "/T"], stderr_to_stdout: true)

      _ ->
        System.cmd("kill", ["-TERM", pid], stderr_to_stdout: true)
    end
  rescue
    _ -> :ok
  end

  defp os_pid, do: :os.getpid() |> List.to_string()

  defp ensure_parent_dir!(file) do
    file
    |> Path.dirname()
    |> File.mkdir_p!()
  end
end
