defmodule DevpulseAgent.Utils.Suggestion do
  @moduledoc """
  Suggests the closest CLI command using Levenshtein distance.
  """

  @default_threshold 3

  @spec suggest(String.t(), [String.t()], keyword()) ::
          {:ok, String.t()} | {:error, :no_match}
  def suggest(input, candidates, opts \\ []) do
    threshold = Keyword.get(opts, :threshold, @default_threshold)

    case candidates do
      [] ->
        {:error, :no_match}

      _ ->
        {candidate, distance} =
          candidates
          |> Enum.map(fn candidate ->
            {candidate, levenshtein(input, candidate)}
          end)
          |> Enum.min_by(fn {_candidate, distance} -> distance end)

        if distance <= threshold do
          {:ok, candidate}
        else
          {:error, :no_match}
        end
    end
  end

  defp levenshtein(a, b) do
    a = String.graphemes(a)
    b = String.graphemes(b)

    matrix =
      for i <- 0..length(a) do
        for j <- 0..length(b) do
          cond do
            i == 0 -> j
            j == 0 -> i
            true -> 0
          end
        end
      end

    matrix =
      Enum.reduce(1..length(a), matrix, fn i, matrix ->
        Enum.reduce(1..length(b), matrix, fn j, matrix ->
          cost =
            if Enum.at(a, i - 1) == Enum.at(b, j - 1),
              do: 0,
              else: 1

          value =
            Enum.min([
              get(matrix, i - 1, j) + 1,
              get(matrix, i, j - 1) + 1,
              get(matrix, i - 1, j - 1) + cost
            ])

          put(matrix, i, j, value)
        end)
      end)

    get(matrix, length(a), length(b))
  end

  defp get(matrix, row, col) do
    matrix
    |> Enum.at(row)
    |> Enum.at(col)
  end

  defp put(matrix, row, col, value) do
    List.update_at(matrix, row, fn r ->
      List.replace_at(r, col, value)
    end)
  end
end
