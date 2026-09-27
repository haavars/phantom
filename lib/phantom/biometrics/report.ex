defmodule Phantom.Biometrics.Report do
  @moduledoc """
  The quality report for a run's images, stored on the run
  (`Phantom.Biometrics.Run`, `report`) when it finishes.

  Faces, under `"faces"` (see `Phantom.Biometrics.FaceGate`):

    * ArcFace similarity between the anchors of different people: its
      distribution, how many pairs reach 0.3 and the gate's threshold, and
      the most similar pairs above the threshold.
    * The gate: how many anchors passed first time, passed after a re-roll,
      or kept their best attempt without passing, and how many were unchecked.

  Friction ridges:

    * `"verification"`: how many fingers and slaps were verified, and how many
      were accepted first time, accepted after a retry, or rejected. Also the
      NFIQ 2, minutiae recall and spurious-rate distributions per impression
      type (`"rolled"`, `"plain"`). See `python_biometrics/verify.py`.
    * `"matching"`: NBIS bozorth3 scores between rolled fingers. Mated pairs
      (two captures of one finger) should score high and non-mated pairs (the
      same finger of two subjects) low. Pairs on the wrong side of the
      threshold are listed, since they point to weak captures or to colliding
      synthetic identities.

  Runs with neither anchors nor verified friction-ridge images get no report.
  """

  alias Phantom.Biometrics.{FaceGate, FacePrompts, Shots}
  alias Phantom.Services.Ridgegen

  # bozorth3's customary match threshold.
  @threshold 40
  # Non-mated pairs grow quadratically with subjects; beyond this, sample evenly.
  @max_non_mated 3000
  @max_listed 20

  # Anchor pairs grow quadratically too; beyond this, sample evenly.
  @max_face_pairs 20_000
  @look_alike 0.3

  @doc "The report for `subjects` (with their images) of a run, or nil."
  def build(subjects) do
    checks =
      for subject <- subjects,
          %{status: :ok, meta: %{"verification" => %{} = check} = meta} <- subject.images,
          do: Map.put(check, "impression", meta["impression"])

    ridges =
      if checks != [] do
        %{
          "threshold" => @threshold,
          "verification" => verification(checks),
          "matching" => matching(subjects)
        }
      end

    faces = faces(subjects)

    case {ridges, faces} do
      {nil, nil} -> nil
      {ridges, nil} -> ridges
      {ridges, faces} -> Map.put(ridges || %{}, "faces", faces)
    end
  end

  defp faces(subjects) do
    anchors =
      for subject <- subjects,
          %{status: :ok, shot: shot} = image <- subject.images,
          shot == FacePrompts.anchor_shot(),
          do: {subject.name, image}

    templates =
      for {name, %{template: template}} <- anchors,
          is_binary(template),
          do: {name, FaceGate.decode(template)}

    if anchors == [] do
      nil
    else
      pairs =
        for [{a, x} | rest] <- tails(templates), {b, y} <- rest do
          {a, b, Float.round(FaceGate.dot(x, y), 3)}
        end

      scores = pairs |> sample(@max_face_pairs) |> Enum.map(&elem(&1, 2))
      threshold = FaceGate.threshold()

      %{
        "threshold" => threshold,
        "anchors" => length(anchors),
        "gate" => gate(Enum.map(anchors, fn {_name, image} -> (image.meta || %{})["gate"] end)),
        "similarity" => similarity_stats(scores),
        "pairs" => length(pairs),
        "look_alike_threshold" => @look_alike,
        "look_alikes" => Enum.count(pairs, &(elem(&1, 2) >= @look_alike)),
        "above_threshold" => Enum.count(pairs, &(elem(&1, 2) >= threshold)),
        "closest" =>
          pairs
          |> Enum.filter(&(elem(&1, 2) >= threshold))
          |> Enum.sort_by(&elem(&1, 2), :desc)
          |> Enum.take(@max_listed)
          |> Enum.map(fn {a, b, score} -> %{"a" => a, "b" => b, "score" => score} end)
      }
    end
  end

  defp gate(gates) do
    checked = Enum.filter(gates, &(is_map(&1) and Map.has_key?(&1, "passed")))
    {passed, failed} = Enum.split_with(checked, & &1["passed"])

    %{
      "checked" => length(checked),
      "unchecked" => length(gates) - length(checked),
      "passed_first" => Enum.count(passed, &((&1["attempts"] || 1) == 1)),
      "rerolled" => Enum.count(passed, &((&1["attempts"] || 1) > 1)),
      "failed" => length(failed),
      "renders" => checked |> Enum.map(&(&1["attempts"] || 1)) |> Enum.sum()
    }
  end

  # Similarity is better low, so the upper tail matters: mean, median, p90 and max.
  defp similarity_stats([]), do: %{"count" => 0}

  defp similarity_stats(scores) do
    sorted = Enum.sort(scores)
    count = length(sorted)

    %{
      "count" => count,
      "mean" => Float.round(Enum.sum(sorted) / count, 3),
      "median" => percentile(sorted, count, 0.5),
      "p90" => percentile(sorted, count, 0.9),
      "max" => List.last(sorted)
    }
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
          %{status: :ok, ground_truth: %{} = truth, capture: capture, shot: shot} <-
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

    case Ridgegen.match(Enum.map(templates, & &1.detected), pairs) do
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
