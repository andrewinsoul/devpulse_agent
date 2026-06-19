defmodule DevpulseAgent.Agent do
  use GenServer
  require Logger

  @check_interval 5_000
  @force_heartbeat_interval 30_000

  def start_link(target_dir) do
    GenServer.start_link(__MODULE__, target_dir, name: __MODULE__)
  end

  @impl true
  def init(target_dir) do
    File.cd!(target_dir)

    # Generate a unique session ID for this specific terminal instance
    session_id = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)

    Logger.debug("DevPulse bound to: #{target_dir}")
    Logger.debug("Session ID: #{session_id}")

    state = %{
      target_dir: target_dir,
      session_id: session_id,
      last_sent_data: nil,
      last_sent_time: 0
    }

    send(self(), :check_git)
    {:ok, state}
  end

  defp resolve_api_token() do
    get_cli_token() || get_env_token() || read_token_from_config()
  end

  defp read_token_from_config do
    config_file = Path.expand("~/.config/devpulse/config.toml")

    if File.exists?(config_file) do
      case File.read(config_file) do
        {:ok, content} ->
          regex = ~r/api_token\s*=\s*"([^"]+)"/

          case Regex.run(regex, content) do
            [_, token] -> token
            _ -> nil
          end

        {:error, _} ->
          nil
      end
    else
      nil
    end
  end

  defp get_cli_token do
    case Application.get_env(:devpulse_agent, :cli_token) do
      token when is_binary(token) and token != "" ->
        Logger.debug("Using token from CLI flag")

        token

      _ ->
        nil
    end
  end

  defp get_env_token, do: System.get_env("DEVPULSE_TOKEN")

  @impl true
  def handle_info(:check_git, state) do
    File.cd!(state.target_dir)

    server_url = Application.fetch_env!(:devpulse_agent, :server_url)
    api_token = resolve_api_token()

    case DevpulseAgent.Git.get_metadata() do
      nil ->
        IO.puts("❌ Not in a Git repository: #{state.target_dir}")
        IO.puts("   Please cd into a Git repository and run again.")
        {:stop, :not_a_git_repo}

      metadata ->
        last_sent = Map.get(state, :last_sent_data, %{})
        last_sent_time = Map.get(state, :last_sent_time, 0)

        if metadata != last_sent or
             System.monotonic_time(:millisecond) - last_sent_time > @force_heartbeat_interval do
          case send_heartbeat(server_url, api_token, state.session_id, metadata) do
            {:ok, _response} ->
              Logger.debug("Heartbeat sent: #{inspect(metadata)}")

              new_state = %{
                state
                | last_sent_data: metadata,
                  last_sent_time: System.monotonic_time(:millisecond)
              }

              {:noreply, new_state}

            {:error, reason} ->
              Logger.error("Failed to send heartbeat: #{reason}")

              {:noreply, state}
          end
        else
          {:noreply, state}
        end
    end
  after
    schedule_checks()
  end

  defp send_heartbeat(server_url, token, session_id, metadata) do
    url = "#{server_url}/api/agent/heartbeat"

    payload = %{
      session_id: session_id,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      metadata: metadata
    }

    Req.post(url,
      json: payload,
      headers: [
        {"authorization", "Bearer #{token}"},
        {"content-type", "application/json"}
      ]
    )
    |> case do
      {:ok, %Req.Response{status: 200}} -> {:ok, :sent}
      {:ok, %Req.Response{status: status}} -> {:error, "HTTP #{status}"}
      {:error, error} -> {:error, inspect(error)}
    end
  end

  defp schedule_checks do
    Process.send_after(self(), :check_git, @check_interval)
  end
end
