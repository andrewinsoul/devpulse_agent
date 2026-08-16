defmodule DevpulseAgent.Utils.Prompt do
  @moduledoc """
  Interactive terminal prompt for selecting an item from a list.

  Navigation:
    • ↑ / k  - Move up
    • ↓ / j  - Move down
    • Enter  - Select
  """

  alias DevpulseAgent.Utils.Terminal

  @spec select(String.t(), [String.t()]) :: String.t()
  def select(_label, []),
    do: raise(ArgumentError, "Prompt requires at least one item")

  def select(label, items) do
    Terminal.with_raw_mode(fn ->
      IO.puts(IO.ANSI.bright() <> label <> IO.ANSI.reset())
      IO.write("\n")

      render_items(items, 0)
      loop(items, 0)
    end)
  end

  defp loop(items, selected) do
    case Terminal.read_key() do
      "ctrl_c" ->
        System.halt(130)

      "up" ->
        redraw(items, max(selected - 1, 0))

      "down" ->
        redraw(items, min(selected + 1, length(items) - 1))

      {"char", "k"} ->
        redraw(items, max(selected - 1, 0))

      {"char", "j"} ->
        redraw(items, min(selected + 1, length(items) - 1))

      "enter" ->
        Enum.at(items, selected)

      _ ->
        loop(items, selected)
    end
  end

  defp redraw(items, selected) do
    {:ok, _} = Terminal.move_up(length(items))
    render_items(items, selected)
    loop(items, selected)
  end

  defp render_items(items, selected) do
    Enum.with_index(items)
    |> Enum.each(fn {item, index} ->
      IO.write(IO.ANSI.clear_line())
      IO.write("\r")

      if index == selected do
        IO.write(IO.ANSI.green() <> "❯ " <> item <> IO.ANSI.reset())
      else
        IO.write("  " <> item)
      end

      IO.write("\n")
    end)
  end
end
