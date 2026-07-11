defmodule DevpulseAgent.Session do
  @moduledoc """
  Persistent short-lived session credential management.
  """

  alias DevpulseAgent.Config

  defstruct [
    :session_id,
    :session_token,
    :team_slug,
    :expires_at,
    :handshake_at,
    :hostname,
    :operating_system,
    :hardware_fingerprint,
    :server_url
  ]

  def load do
    case Config.load_session() do
      nil -> nil
      attrs -> from_map(attrs)
    end
  end

  def save!(%__MODULE__{} = session) do
    session
    |> to_map()
    |> Config.save_session!()
  end

  def clear!, do: Config.clear_session!()

  def expired?(nil), do: true
  def expired?(%__MODULE__{expires_at: nil}), do: false

  def expired?(%__MODULE__{expires_at: expires_at}) do
    DateTime.compare(DateTime.utc_now(), expires_at) != :lt
  end

  def expiring_soon?(%__MODULE__{} = session, threshold_ms \\ 60_000) do
    case remaining_ms(session) do
      nil -> false
      ms -> ms <= threshold_ms
    end
  end

  def remaining_ms(nil), do: nil

  def remaining_ms(%__MODULE__{expires_at: nil}), do: nil

  def remaining_ms(%__MODULE__{expires_at: expires_at}) do
    DateTime.diff(expires_at, DateTime.utc_now(), :millisecond)
  end

  def from_handshake_response(body, attrs) when is_map(body) do
    session_token =
      pick(body, [
        :session_token,
        :session_credential,
        :token,
        "session_token",
        "session_credential",
        "token"
      ])

    expires_at =
      parse_datetime(
        pick(body, [:expires_at, :session_expires_at, "expires_at", "session_expires_at"])
      )

    %__MODULE__{
      session_id: pick(body, [:session_id, "session_id"]) || attrs[:session_id],
      session_token: session_token,
      team_slug: attrs[:team_slug],
      expires_at: expires_at || expires_from_body(body),
      handshake_at: DateTime.utc_now(),
      hostname: attrs[:hostname],
      operating_system: attrs[:operating_system],
      hardware_fingerprint: attrs[:hardware_fingerprint],
      server_url: attrs[:server_url]
    }
  end

  def to_map(%__MODULE__{} = session) do
    %{
      session_id: session.session_id,
      session_token: session.session_token,
      team_slug: session.team_slug,
      expires_at: encode_datetime(session.expires_at),
      handshake_at: encode_datetime(session.handshake_at),
      hostname: session.hostname,
      operating_system: session.operating_system,
      hardware_fingerprint: session.hardware_fingerprint,
      server_url: session.server_url
    }
  end

  def from_map(attrs) when is_map(attrs) do
    %__MODULE__{
      session_id: pick(attrs, [:session_id, "session_id"]),
      session_token: pick(attrs, [:session_token, "session_token"]),
      team_slug: pick(attrs, [:team_slug, "team_slug"]),
      expires_at: parse_datetime(pick(attrs, [:expires_at, "expires_at"])),
      handshake_at: parse_datetime(pick(attrs, [:handshake_at, "handshake_at"])),
      hostname: pick(attrs, [:hostname, "hostname"]),
      operating_system: pick(attrs, [:operating_system, "operating_system"]),
      hardware_fingerprint: pick(attrs, [:hardware_fingerprint, "hardware_fingerprint"]),
      server_url: pick(attrs, [:server_url, "server_url"])
    }
  end

  defp expires_from_body(body) do
    case pick(body, [:expires_in, "expires_in"]) do
      nil ->
        nil

      seconds when is_integer(seconds) ->
        DateTime.add(DateTime.utc_now(), seconds, :second)

      seconds when is_binary(seconds) ->
        case Integer.parse(seconds) do
          {int, ""} -> DateTime.add(DateTime.utc_now(), int, :second)
          _ -> nil
        end
    end
  end

  defp parse_datetime(nil), do: nil
  defp parse_datetime(%DateTime{} = dt), do: dt

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(value) when is_integer(value) do
    DateTime.from_unix!(value, :second)
  end

  defp encode_datetime(nil), do: nil
  defp encode_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp pick(map, keys) do
    Enum.find_value(keys, fn key -> Map.get(map, key) end)
  end
end
