defmodule DevpulseAgent.Client do
  @moduledoc """
  Unified HTTP client for all DevPulse CLI agent backend communications.
  """

  @doc """
  Exchanges a temporary invitation token for a permanent Personal Access Token (PAT).
  Used globally during `devpulse login`.
  """
  def exchange_invite(base_url, invite_token) do
    request(
      base_url,
      "/cli/auth/exchange",
      nil,
      %{invite_token: invite_token},
      :none,
      :post
    )
  end

  def retrigger_auth(base_url, invite_token) do
    case request(
           base_url,
           "/cli/auth/retrigger",
           nil,
           %{invite_token: invite_token},
           :none,
           :post
         ) do
      {:ok, body} ->
        {:ok, :retrigger, normalize_body(body)}

      error ->
        {:error, normalize_error(error)}
    end
  end

  def check_pairing_status(base_url, pairing_code) do
    path = "/cli/auth/status/#{pairing_code}"
    url = join_url(base_url, path)

    case Req.get(url,
           retry: false,
           headers: [{"content-type", "application/json"}],
           receive_timeout: 5_000,
           connect_options: [timeout: 5_000]
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, normalize_body(body)}

      {:ok, %Req.Response{status: 404, body: body}} ->
        normalized = normalize_body(body)
        message = extract_error_message(normalized, "Pairing session expired or not found.")
        {:error, message}

      {:ok, %Req.Response{status: status, body: body}} ->
        normalized = normalize_body(body)
        message = extract_error_message(normalized, "Server returned status #{status}")
        {:error, message}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, "Network error: #{inspect(reason)}"}

      {:error, reason} ->
        {:error, "Failed to check status: #{inspect(reason)}"}
    end
  end

  defp extract_error_message(%{} = map, fallback), do: Map.get(map, "error", fallback)
  defp extract_error_message(_raw_body, fallback), do: fallback

  @doc """
  Fetches all teams that the authenticated developer has access to.
  """
  def get_teams(base_url, token) do
    request(base_url, "/cli/teams", token, :personal_access_token, :get)
  end

  @doc """
  Fetches all projects under a specific team scope.
  """
  def get_projects(base_url, token, team_id) do
    request(
      base_url,
      "/cli/teams/#{team_id}/projects",
      token,
      :personal_access_token,
      :get
    )
  end

  @doc """
  Validates a session context or exchanges project definitions against a workspace setup.
  """
  def handshake(base_url, token, attrs) do
    request(
      base_url,
      "/api/agent/handshake",
      token,
      handshake_payload(attrs),
      :personal_access_token,
      :post
    )
  end

  @doc """
  Initializes an operational telemetry tracking session stream.
  """
  def init_session(base_url, token) do
    request(base_url, "/init", token, :personal_access_token, :get)
  end

  @doc """
  Streams telemetry state payloads back to the ingestion loops.
  """
  def heartbeat(base_url, session_token, attrs) do
    request(
      base_url,
      "/api/agent/heartbeat",
      session_token,
      heartbeat_payload(attrs),
      :session,
      :post
    )
  end

  defp request(base_url, path, token, payload, auth_type, :post) do
    headers = auth_headers(token, auth_type)
    url = join_url(base_url, path)

    case Req.post(url,
           json: payload,
           headers: headers,
           retry: false,
           receive_timeout: 10_000,
           connect_options: [timeout: 5_000]
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, normalize_body(body)}

      # Pass the normalized body along with status-specific tags
      {:ok, %Req.Response{status: 401, body: body}} ->
        {:error, {:unauthorized, normalize_body(body)}}

      {:ok, %Req.Response{status: 403, body: body}} ->
        {:error, {:forbidden, normalize_body(body)}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_error, status, normalize_body(body)}}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, {:transport_error, reason}}

      {:error, reason} ->
        {:error, normalize_error(reason)}
    end
  end

  defp request(base_url, path, token, auth_type, :get) do
    headers = auth_headers(token, auth_type)
    url = join_url(base_url, path)

    case Req.get(url,
           headers: headers,
           retry: false,
           receive_timeout: 10_000,
           connect_options: [timeout: 5_000]
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, normalize_body(body)}

      {:ok, %Req.Response{status: 401, body: body}} ->
        {:error, {:unauthorized, normalize_body(body)}}

      {:ok, %Req.Response{status: 403, body: body}} ->
        {:error, {:forbidden, normalize_body(body)}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_error, status, normalize_body(body)}}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, {:transport_error, reason}}

      {:error, reason} ->
        {:error, normalize_error(reason)}
    end
  end

  defp auth_headers(_token, :none), do: [{"content-type", "application/json"}]

  defp auth_headers(token, type) when type in [:personal_access_token, :session] do
    [
      {"authorization", "Bearer #{token}"},
      {"content-type", "application/json"}
    ]
  end

  defp handshake_payload(attrs) do
    %{
      team_slug: attrs[:team_slug],
      project_slug: attrs[:project_slug],
      hostname: attrs[:hostname],
      operating_system: attrs[:operating_system],
      hardware_fingerprint: attrs[:hardware_fingerprint],
      project_name: attrs[:project_name],
      repo_path: attrs[:repo_path],
      git_remote_url: attrs[:git_remote_url]
    }
    |> drop_nils()
  end

  defp heartbeat_payload(attrs) do
    %{
      team_slug: attrs[:team_slug],
      session_id: attrs[:session_id],
      project_name: attrs[:project_name],
      git_branch: attrs[:git_branch],
      repo_path: attrs[:repo_path],
      has_uncommitted_changes: attrs[:has_uncommitted_changes],
      captured_at: attrs[:captured_at] || DateTime.utc_now() |> DateTime.to_iso8601()
    }
    |> drop_nils()
  end

  defp drop_nils(map) do
    Enum.reject(map, fn {_key, value} -> is_nil(value) end) |> Map.new()
  end

  defp normalize_body(%{} = body), do: body

  defp normalize_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      _ -> body
    end
  end

  defp normalize_body(body), do: body

  defp normalize_error(%{reason: reason}), do: reason
  defp normalize_error(reason), do: reason

  defp join_url(base_url, path) do
    base = String.trim_trailing(base_url, "/")
    base <> path
  end
end
