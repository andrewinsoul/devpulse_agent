defmodule DevpulseAgent.Buffer do
  @moduledoc """
  Persistent offline heartbeat buffer.
  """

  alias DevpulseAgent.Config

  def load(file \\ Config.buffer_file()), do: Config.load_buffer(file)

  def append!(event, file \\ Config.buffer_file()) when is_map(event) do
    Config.append_buffer_event!(event, file)
  end

  def replace!(events, file \\ Config.buffer_file()) when is_list(events) do
    Config.save_buffer!(events, file)
  end

  def clear!(file \\ Config.buffer_file()), do: Config.delete_buffer!(file)

  def prune(events, retention_ms) when is_list(events) do
    now = DateTime.utc_now()

    Enum.filter(events, fn event ->
      case DateTime.from_iso8601(event["captured_at"] || event[:captured_at] || "") do
        {:ok, captured_at, _offset} ->
          age_ms = DateTime.diff(now, captured_at, :millisecond)
          age_ms >= 0 and age_ms <= retention_ms

        _ ->
          false
      end
    end)
  end

  @doc """
  Keeps the newest events while enforcing both event-count and serialized-byte limits.
  Returns the bounded events and the number of dropped events.
  """
  def bound(events, max_events, max_bytes)
      when is_list(events) and is_integer(max_events) and is_integer(max_bytes) do
    events
    |> drop_oldest_until_count(max(max_events, 0), 0)
    |> drop_oldest_until_bytes(max(max_bytes, 0), 0)
  end

  defp drop_oldest_until_count(events, max_events, dropped) do
    if length(events) > max_events do
      [_oldest | rest] = events
      drop_oldest_until_count(rest, max_events, dropped + 1)
    else
      {events, dropped}
    end
  end

  defp drop_oldest_until_bytes({events, dropped}, max_bytes, extra_dropped) do
    if serialized_bytes(events) > max_bytes and events != [] do
      [_oldest | rest] = events
      drop_oldest_until_bytes({rest, dropped + 1}, max_bytes, extra_dropped)
    else
      {events, dropped + extra_dropped}
    end
  end

  defp serialized_bytes(events) do
    events
    |> Enum.map(&(Jason.encode!(&1) <> "\n"))
    |> IO.iodata_length()
  end
end
