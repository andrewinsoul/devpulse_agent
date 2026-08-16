defmodule DevpulseAgent.Agent do
  use GenServer

  require Logger

  alias DevpulseAgent.{Buffer, Client, Config, Git, Session, Workspace}

  @max_backoff_ms 60_000

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  end

  def stop(server \\ __MODULE__) do
    GenServer.stop(server, :normal)
  end

  def force_handshake(server \\ __MODULE__) do
    GenServer.cast(server, :force_handshake)
  end

  @impl true
  def init(opts) do
    workspace_root = Path.expand(Keyword.get(opts, :workspace, File.cwd!()))
    config = Keyword.get(opts, :config, Config.load())
    client = Keyword.get(opts, :client, Client)
    git = Keyword.get(opts, :git, Git)

    with {:ok, repo_metadata} <- git.metadata(workspace_root),
         {:ok, team_slug, team_source} <-
           Workspace.resolve_team(workspace_root, repo_metadata, opts, config),
         {:ok, project_info} <- Workspace.resolve_project(workspace_root) do
      state = %{
        workspace_root: workspace_root,
        repo_metadata: repo_metadata,
        team_slug: team_slug,
        project_id: project_info[:project_id],
        project_name: project_info[:project_name],
        team_source: team_source,
        config: config,
        client: client,
        git: git,
        session: nil,
        supervisor: Keyword.get(opts, :supervisor),
        offline: false,
        backoff_ms: config.heartbeat_interval_ms,
        force_handshake?: true
      }

      IO.puts("DevPulse agent ready for team #{team_slug}")

      send(self(), :tick)

      {:ok, state}
    else
      {:error, :not_git_repo} ->
        Logger.error("DevPulse requires a Git workspace")
        {:stop, {:not_git_repo, workspace_root}}

      {:error, :team_required} ->
        Logger.error("DevPulse needs an explicit team selection for #{workspace_root}")
        {:stop, :team_required}

      {:error, {:ambiguous_team, teams}} ->
        Logger.error("DevPulse workspace maps to multiple teams: #{Enum.join(teams, ", ")}")

        {:stop, {:ambiguous_team, teams}}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, status_snapshot(state), state}
  end

  @impl true
  def handle_cast(:force_handshake, state) do
    {:noreply, %{state | force_handshake?: true}}
  end

  @impl true
  def handle_info(:tick, state) do
    case ensure_session(state) do
      {:ok, state} ->
        send_heartbeat_cycle(state)

      {:error, reason, state} ->
        handle_tick_error(state, reason)
    end
  end

  defp send_heartbeat_cycle(state) do
    repo_metadata = refresh_repo_metadata(state)

    heartbeat_event = heartbeat_event(state, repo_metadata)

    retention_ms = state.config.offline_retention_ms

    buffered_events =
      Buffer.load()
      |> Buffer.prune(retention_ms)

    case flush_buffer(buffered_events, state) do
      {:ok, remaining_events, updated_state} ->
        case send_event(updated_state, heartbeat_event) do
          {:ok, final_state} ->
            finalize_success(final_state, remaining_events)

          {:error, reason, failed_state} ->
            handle_cycle_error(
              failed_state,
              reason,
              heartbeat_event,
              remaining_events
            )
        end

      {:error, reason, remaining_events, failed_state} ->
        handle_cycle_error(
          failed_state,
          reason,
          heartbeat_event,
          remaining_events
        )
    end
  end

  defp finalize_success(state, remaining_events) do
    if remaining_events == [] do
      Buffer.clear!()
    else
      Buffer.replace!(remaining_events)
    end

    Logger.debug("Heartbeat flowing for team #{state.team_slug}")

    next_state = %{
      state
      | offline: false,
        backoff_ms: state.config.heartbeat_interval_ms,
        force_handshake?: false
    }

    schedule_next_tick(next_state)
  end

  defp buffer_failure(heartbeat_event, remaining_events, state, reason) do
    Buffer.replace!(remaining_events ++ [heartbeat_event])

    Logger.warning("Heartbeat buffered because #{format_reason(reason)}")

    next_backoff =
      min(
        max(state.backoff_ms * 2, state.config.heartbeat_interval_ms),
        @max_backoff_ms
      )

    schedule_next_tick(%{
      state
      | offline: true,
        backoff_ms: next_backoff
    })
  end

  defp handle_cycle_error(
         state,
         reason,
         heartbeat_event,
         remaining_events
       ) do
    if retryable_error?(reason) do
      buffer_failure(
        heartbeat_event,
        remaining_events,
        state,
        reason
      )
    else
      Logger.error("Heartbeat stopped because #{format_reason(reason)}")

      fatal_shutdown(state, reason)
    end
  end

  defp handle_tick_error(state, reason) do
    if retryable_error?(reason) do
      Logger.error("Session unavailable: #{format_reason(reason)}")

      next_backoff =
        min(
          max(state.backoff_ms * 2, state.config.heartbeat_interval_ms),
          @max_backoff_ms
        )

      schedule_next_tick(%{
        state
        | offline: true,
          backoff_ms: next_backoff
      })
    else
      Logger.error("Session stopped because #{format_reason(reason)}")

      fatal_shutdown(state, reason)
    end
  end

  defp flush_buffer([], state), do: {:ok, [], state}

  defp flush_buffer([event | rest], state) do
    case send_event(state, event) do
      {:ok, new_state} ->
        case flush_buffer(rest, new_state) do
          {:ok, remaining, final_state} ->
            {:ok, remaining, final_state}

          {:error, reason, remaining, final_state} ->
            {:error, reason, remaining, final_state}
        end

      {:error, reason, new_state} ->
        {:error, reason, [event | rest], new_state}
    end
  end

  defp send_event(state, event) do
    send_event(state, event, false)
  end

  defp send_event(state, event, retried_handshake?) do
    case state.client.heartbeat(
           state.config.server_url,
           state.config.token,
           event
         ) do
      {:ok, _response} ->
        {:ok, state}

      {:error, :unauthorized} when not retried_handshake? ->
        case handshake(state) do
          {:ok, refreshed_state} ->
            send_event(refreshed_state, event, true)

          {:error, reason, failed_state} ->
            {:error, reason, failed_state}
        end

      {:error, :unauthorized} ->
        {:error, :unauthorized, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp ensure_session(%{force_handshake?: true} = state) do
    handshake(state)
  end

  defp ensure_session(%{session: %Session{} = session} = state) do
    if Session.expired?(session) do
      handshake(state)
    else
      {:ok, state}
    end
  end

  defp ensure_session(state) do
    handshake(state)
  end

  defp handshake(state) do
    token = state.config.token

    if is_nil(token) or token == "" do
      {:error, :missing_master_api_token, state}
    else
      context = handshake_context(state)

      case state.client.handshake(
             state.config.server_url,
             token,
             context
           ) do
        {:ok, %{"session" => session_data}} ->
          case normalize_session(session_data, context) do
            {:ok, session} ->
              Session.save!(session)

              Logger.info("Handshake succeeded for team #{state.team_slug}")

              {:ok,
               %{
                 state
                 | session: session,
                   offline: false,
                   force_handshake?: false
               }}

            {:error, reason} ->
              {:error, reason, state}
          end

        {:error, reason} ->
          {:error, reason, state}
      end
    end
  end

  defp normalize_session(session_data, context) do
    case session_data["session_id"] do
      nil ->
        {:error, :invalid_session_response}

      _session_id ->
        {:ok, Session.from_handshake_response(session_data, context)}
    end
  end

  defp retryable_error?({:transport_error, reason})
       when reason in [:timeout, :econnrefused, :closed] do
    true
  end

  defp retryable_error?({:http_error, status, _body})
       when status in [408, 429] or status >= 500 do
    true
  end

  defp retryable_error?(_), do: false

  defp fatal_shutdown(state, reason) do
    maybe_shutdown_supervisor(state.supervisor)

    {:stop, {:shutdown, reason}, state}
  end

  defp maybe_shutdown_supervisor(nil), do: :ok

  defp maybe_shutdown_supervisor(supervisor) when is_atom(supervisor) do
    case Process.whereis(supervisor) do
      nil ->
        :ok

      pid ->
        Process.exit(pid, :shutdown)
    end
  end

  defp maybe_shutdown_supervisor(supervisor) when is_pid(supervisor) do
    if Process.alive?(supervisor) do
      Process.exit(supervisor, :shutdown)
    end

    :ok
  end

  defp handshake_context(state) do
    hostname = hostname()
    operating_system = operating_system()

    %{
      project_id: state.project_id,
      hardware_fingerprint:
        hardware_fingerprint(
          hostname,
          operating_system,
          state.repo_metadata.repo_path
        ),
      hostname: hostname,
      operating_system: operating_system
    }
  end

  defp heartbeat_event(state, repo_metadata) do
    %{
      team_slug: state.team_slug,
      session_id: state.session.session_id,
      project_id: state.project_id,
      project_name: repo_metadata.project_name,
      git_branch: repo_metadata.branch,
      repo_path: repo_metadata.repo_path,
      has_uncommitted_changes: repo_metadata.has_uncommitted_changes,
      captured_at:
        DateTime.utc_now()
        |> DateTime.to_iso8601()
    }
  end

  defp refresh_repo_metadata(state) do
    case state.git.metadata(state.workspace_root) do
      {:ok, metadata} ->
        metadata

      {:error, _} ->
        state.repo_metadata
    end
  end

  defp schedule_next_tick(state) do
    Process.send_after(
      self(),
      :tick,
      state.backoff_ms
    )

    {:noreply, state}
  end

  defp status_snapshot(state) do
    session = state.session || Session.load()
    buffered = Buffer.load()

    %{
      workspace_root: state.workspace_root,
      team_slug: state.team_slug,
      team_source: state.team_source,
      server_url: state.config.server_url,
      session_active: not is_nil(session) and not Session.expired?(session),
      session_expires_at: session && session.expires_at,
      session_remaining_ms: Session.remaining_ms(session),
      offline: state.offline,
      buffered_heartbeats: length(buffered),
      heartbeat_interval_ms: state.config.heartbeat_interval_ms,
      next_backoff_ms: state.backoff_ms
    }
  end

  defp operating_system do
    {family, name} = :os.type()
    "#{family}/#{name}"
  end

  defp hostname do
    {:ok, host} = :inet.gethostname()
    List.to_string(host)
  end

  defp hardware_fingerprint(
         hostname,
         operating_system,
         repo_path
       ) do
    :crypto.hash(
      :sha256,
      Enum.join(
        [hostname, operating_system, repo_path],
        "|"
      )
    )
    |> Base.encode16(case: :lower)
  end

  defp format_reason({:http_error, status, _body}) do
    "HTTP #{status}"
  end

  defp format_reason({:ambiguous_team, teams}) do
    "multiple teams matched: #{Enum.join(teams, ", ")}"
  end

  defp format_reason(reason) do
    inspect(reason)
  end
end
