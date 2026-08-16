defmodule DevpulseAgent.Utils.Terminal do
  use Rustler,
    otp_app: :devpulse_agent,
    crate: "terminal"

  def with_raw_mode(fun) when is_function(fun, 0) do
    case enable_raw_mode() do
      {:ok, _} ->
        try do
          fun.()
        after
          disable_raw_mode()
        end

      {:error, reason} ->
        raise "Failed to enable raw mode: #{reason}"
    end
  end

  defp error do
    :erlang.nif_error(:nif_not_loaded)
  end

  def ping(), do: error()
  def enable_raw_mode(), do: error()
  def disable_raw_mode(), do: error()
  def read_key(), do: error()

  def move_up(_lines), do: error()
  def clear_screen(), do: error()
  def move_to(_x, _y), do: error()
  def hide_cursor(), do: error()
  def show_cursor(), do: error()
end
