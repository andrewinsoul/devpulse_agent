defmodule DevpulseAgent.Client do
  @moduledoc """
  Server HTTP client for handshakes and heartbeats.
  """

  def handshake(base_url, master_api_token, attrs) do
    request(
      base_url,
      "/api/agent/handshake",
      master_api_token,
      handshake_payload(attrs),
      :master
    )
    |> case do
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:error, reason}
    end
  end

  def heartbeat(base_url, session_token, attrs) do
    request(
      base_url,
      "/api/agent/heartbeat",
      session_token,
      heartbeat_payload(attrs),
      :session
    )
    |> case do
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:error, reason}
    end
  end

  defp request(base_url, path, token, payload, auth_type) do
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

      {:ok, %Req.Response{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %Req.Response{status: 403}} ->
        {:error, :forbidden}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_error, status, normalize_body(body)}}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, {:transport_error, reason}}

      {:error, reason} ->
        {:error, normalize_error(reason)}
    end
  end

  defp auth_headers(token, :master), do: [{"authorization", "Bearer #{token}"}]
  defp auth_headers(token, :session), do: [{"authorization", "Bearer #{token}"}]

  defp handshake_payload(attrs) do
    %{
      team_slug: attrs[:team_slug],
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
