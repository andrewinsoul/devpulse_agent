defmodule DevpulseAgent.Buffer do
  @moduledoc """
  Persistent offline heartbeat buffer.
  """

  alias DevpulseAgent.Config

  def load, do: Config.load_buffer()

  def append!(event) when is_map(event), do: Config.append_buffer_event!(event)

  def replace!(events) when is_list(events), do: Config.save_buffer!(events)

  def clear!, do: Config.delete_buffer!()

  def prune(events, retention_ms) when is_list(events) do
    now = DateTime.utc_now()

    Enum.filter(events, fn event ->
      case DateTime.from_iso8601(event["captured_at"] || event[:captured_at] || "") do
        {:ok, captured_at, _offset} ->
          DateTime.diff(now, captured_at, :millisecond) <= retention_ms

        _ ->
          true
      end
    end)
  end
end
