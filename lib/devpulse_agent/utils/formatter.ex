defmodule DevpulseAgent.Utils.Formatter do
  @moduledoc """
  Helpers for formatting terminal output.
  """

  @doc """
  Prints a table with automatically sized columns.

  Example:

      print_table(
        ["TEAM", "PROJECT", "REMOTE"],
        [
          ["backend", "devpulse_server", "..."],
          ["platform", "nature_whistle", "..."]
        ]
      )

  """
  def print_table(opts) when is_list(opts) do
    headers = Keyword.fetch!(opts, :headers)
    rows = Keyword.fetch!(opts, :rows)
    title = Keyword.get(opts, :title)

    if title do
      IO.puts(title)
      IO.puts("")
    end

    widths = column_widths(headers, rows)

    print_row(headers, widths)

    IO.puts(
      widths
      |> Enum.map(&String.duplicate("-", &1))
      |> Enum.join("  ")
    )

    Enum.each(rows, &print_row(&1, widths))
  end

  defp column_widths(headers, rows) do
    columns =
      [headers | rows]
      |> Enum.zip()
      |> Enum.map(&Tuple.to_list/1)

    Enum.map(columns, fn column ->
      column
      |> Enum.map(&(to_string(&1) |> String.length()))
      |> Enum.max()
    end)
  end

  defp print_row(values, widths) do
    values
    |> Enum.zip(widths)
    |> Enum.map(fn {value, width} ->
      value
      |> to_string()
      |> String.pad_trailing(width)
    end)
    |> Enum.join("  ")
    |> IO.puts()
  end

  def green(text), do: color(text, 32)
  def red(text), do: color(text, 31)
  def yellow(text), do: color(text, 33)
  def blue(text), do: color(text, 34)

  def success(text \\ ""), do: green("✔ " <> text)
  def error(text \\ ""), do: red("✖ " <> text)
  def warning(text \\ ""), do: yellow("! " <> text)
  def info(text \\ ""), do: blue("ℹ " <> text)

  defp color(text, ansi_code) do
    "\e[#{ansi_code}m#{text}\e[0m"
  end
end
