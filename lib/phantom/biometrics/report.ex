defmodule Phantom.Biometrics.Report do
  @moduledoc """
  The quality report for a run's friction-ridge images, stored on the run
  (`Phantom.Biometrics.Run`, `report`) when it finishes.

    * `"verification"`: how many fingers and slaps were verified, and how many
      were accepted first time, accepted after a retry, or rejected. Also the
      NFIQ 2, minutiae recall and spurious-rate distributions per impression
      type (`"rolled"`, `"plain"`). See `python_biometrics/verify.py`.
    * `"matching"`: NBIS bozorth3 scores between rolled fingers. Mated pairs
      (two captures of one finger) should score high and non-mated pairs (the
      same finger of two subjects) low. Pairs on the wrong side of the
      threshold are listed, since they point to weak captures or to colliding
      synthetic identities.

  Runs without verified friction-ridge images get no report.
  """

  alias Phantom.Biometrics.{FrictionRidge, Shots}

  # bozorth3's customary match threshold.
  @threshold 40
  # Non-mated pairs grow quadratically with subjects; beyond this, sample evenly.
  @max_non_mated 3000
  @max_listed 20

  @doc "The report for `subjects` (with their images) of a run, or nil."
  def build(subjects) do
    checks =
      for subject <- subjects,
          %{status: "ok", meta: %{"verification" => %{} = check} = meta} <- subject.images,
          do: Map.put(check, "impression", meta["impression"])

    if checks == [] do
      nil
    else
      %{
        "threshold" => @threshold,
        "verification" => verification(checks),
        "matching" => matching(subjects)
      }
    end
  end

  defp verification(checks) do
    {accepted, rejected} = Enum.split_with(checks, & &1["accepted"])

    by_impression =
      checks
      |> Enum.group_by(&(&1["impression"] || "other"))
      |> Map.new(fn {impression, group} ->
        {impression,
         %{
           "count" => length(group),
           "nfiq2" => stats(Enum.map(group, & &1["nfiq2"])),
           "minutiae_recall" => stats(Enum.map(group, & &1["minutiae_recall"])),
           "minutiae_spurious" => stats(Enum.map(group, & &1["minutiae_spurious"]))
         }}
      end)

    %{
      "verified" => length(checks),
      "accepted" => Enum.count(accepted, &((&1["attempts"] || 1) == 1)),
      "retried" => Enum.count(accepted, &((&1["attempts"] || 1) > 1)),
      "rejected" => length(rejected),
      "by_impression" => by_impression
    }
  end

  defp matching(subjects) do
    templates =
      for subject <- subjects,
          %{status: "ok", ground_truth: %{} = truth, capture: capture, shot: shot} <-
            subject.images,
          %{group: "rolled", numeric_code: fgp} <- [Shots.spec(shot)],
          %{"verification" => %{"detected" => detected}} when is_list(detected) <- [truth],
          do: %{subject: subject.name, fgp: fgp, capture: capture, shot: shot, detected: detected}

    mated =
      for {_key, group} <- Enum.group_by(templates, &{&1.subject, &1.fgp}),
          [a | rest] <- tails(Enum.sort_by(group, & &1.capture)),
          b <- rest,
          do: {a, b}

    non_mated =
      for {_fgp, group} <- Enum.group_by(Enum.filter(templates, &(&1.capture == 0)), & &1.fgp),
          [a | rest] <- tails(Enum.sort_by(group, & &1.subject)),
          b <- rest,
          do: {a, b}

    non_mated = sample(non_mated, @max_non_mated)

    if mated == [] and non_mated == [] do
      nil
    else
      score(templates, mated, non_mated)
    end
  end

  defp score(templates, mated, non_mated) do
    index = templates |> Enum.with_index() |> Map.new()
    pairs = Enum.map(mated ++ non_mated, fn {a, b} -> {index[a], index[b]} end)

    case FrictionRidge.match(Enum.map(templates, & &1.detected), pairs) do
      {:ok, scores} ->
        {mated_scores, non_mated_scores} = Enum.split(scores, length(mated))
        mated = Enum.zip(mated, mated_scores)
        non_mated = Enum.zip(non_mated, non_mated_scores)

        %{
          "mated" => stats(mated_scores),
          "non_mated" => stats(non_mated_scores),
          "false_non_matches" => Enum.count(mated_scores, &(&1 < @threshold)),
          "false_matches" => Enum.count(non_mated_scores, &(&1 >= @threshold)),
          "weak_mates" => listed(mated, &(&1 < @threshold), :asc),
          "collisions" => listed(non_mated, &(&1 >= @threshold), :desc)
        }

      {:error, message} ->
        %{"error" => message}
    end
  end

  defp listed(scored, keep?, order) do
    scored
    |> Enum.filter(fn {_pair, score} -> keep?.(score) end)
    |> Enum.sort_by(fn {_pair, score} -> score end, order)
    |> Enum.take(@max_listed)
    |> Enum.map(fn {{a, b}, score} ->
      %{"a" => "#{a.subject}/#{a.shot}", "b" => "#{b.subject}/#{b.shot}", "score" => score}
    end)
  end

  # [1, 2, 3] -> [[1, 2, 3], [2, 3], [3]]
  defp tails([]), do: []
  defp tails([_ | rest] = list), do: [list | tails(rest)]

  defp sample(list, max) when length(list) <= max, do: list

  defp sample(list, max),
    do: list |> Enum.take_every(ceil(length(list) / max))

  @doc "count, mean, min, p10, median and max of the non-nil numbers in `values`."
  def stats(values) do
    case values |> Enum.filter(&is_number/1) |> Enum.sort() do
      [] ->
        %{"count" => 0}

      sorted ->
        count = length(sorted)

        %{
          "count" => count,
          "mean" => Float.round(Enum.sum(sorted) / count, 3),
          "min" => hd(sorted),
          "p10" => percentile(sorted, count, 0.1),
          "median" => percentile(sorted, count, 0.5),
          "max" => List.last(sorted)
        }
    end
  end

  # Nearest rank.
  defp percentile(sorted, count, p), do: Enum.at(sorted, max(ceil(p * count) - 1, 0))
end
