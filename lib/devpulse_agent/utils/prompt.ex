defmodule DevpulseAgent.Utils.Prompt do
  @moduledoc """
  Interactive terminal prompt for selecting an item from a list.

  Navigation:
    • ↑ / k  - Move up
    • ↓ / j  - Move down
    • Enter  - Select
  """

  @spec select(String.t(), [String.t()]) :: String.t()
  def select(_label, []), do: raise(ArgumentError, "Prompt requires at least one item")

  def select(label, items) do
    count = length(items)

    IO.puts("\n")
    IO.puts("#{IO.ANSI.cyan()}?#{IO.ANSI.reset()} #{IO.ANSI.bright()}#{label}#{IO.ANSI.reset()}")

    enable_raw_mode()

    try do
      index = loop(items, count, 0)
      IO.puts("\n")
      Enum.at(items, index)
    after
      disable_raw_mode()
    end
  end

  defp loop(items, count, current_idx, first_render? \\ true)

  defp loop(items, count, current_idx, first_render?) do
    render(items, count, current_idx, first_render?)

    case read_key() do
      :up ->
        loop(items, count, max(current_idx - 1, 0), false)

      :down ->
        loop(items, count, min(current_idx + 1, count - 1), false)

      :enter ->
        unless first_render? do
          IO.write(IO.ANSI.cursor_up(count) <> "\e[J")
        end

        current_idx

      _ ->
        loop(items, count, current_idx, false)
    end
  end

  defp render(items, count, current_idx, first_render?) do
    unless first_render? do
      IO.write(IO.ANSI.cursor_up(count) <> "\e[J")
    end

    Enum.with_index(items)
    |> Enum.each(fn {item, idx} ->
      if idx == current_idx do
        IO.puts("  #{IO.ANSI.cyan()}➔ #{item}#{IO.ANSI.reset()}")
      else
        IO.puts("    #{item}")
      end
    end)
  end

  defp enable_raw_mode do
    System.cmd("stty", ["raw", "-echo"])
  end

  defp disable_raw_mode do
    System.cmd("stty", ["-raw", "echo"])
  end

  defp read_key do
    case IO.binread(:stdio, 1) do
      "\e" ->
        case IO.binread(:stdio, 2) do
          "[A" -> :up
          "[B" -> :down
          _ -> :unknown
        end

      "k" ->
        :up

      "j" ->
        :down

      "\r" ->
        :enter

      "\n" ->
        :enter

      _ ->
        :unknown
    end
  end
end
