defmodule Phantom.Biometrics.FaceGate do
  @moduledoc """
  Keeps the people of a run from looking alike.

  Anchors rendered from text alone can come out as near look-alikes: in test
  runs, some pairs of different people scored 0.46-0.51 with ArcFace, where
  about 0.4 is where a matcher starts to call two faces the same person
  (docs/synthetic-biometrics.md, "Face diversity"). So every new anchor is
  compared with the anchors of the run's other people, and one that scores
  `threshold/0` or more against any of them is rendered again with the next
  attempt's seed and facial features (`Generator.Faces`), up to
  `attempts/0` times. When none passes, the attempt least like anyone is kept.

  Templates come from the biometrics service (`Ridgegen.face_template/1`,
  InsightFace `buffalo_l`), are stored on the anchor image (`template`) and
  compared by cosine similarity. What happened is recorded in the anchor's
  `meta["gate"]`, see `check/2`.
  """

  alias Phantom.Services.Ridgegen

  @threshold 0.35
  @attempts 5

  @doc "Anchors this similar to another person of the run, or more, are rendered again."
  def threshold, do: @threshold

  @doc "How many times an anchor is rendered at most."
  def attempts, do: @attempts

  @doc """
  Renders an anchor with `render` (a function of the 0-based attempt that
  returns `{:ok, png, extra}` or `{:error, reason}`) until one scores below
  `threshold/0` against `others`, a list of `{subject_name, template}`, or
  `max` attempts (`attempts/0` by default) have been rendered.

  Returns `{:ok, png, extra, template, gate}` for the attempt kept, or the
  first error `render` returns. `template` is `nil` when no face was found.
  `gate` is what goes in `meta["gate"]`: see `check/2`, plus `"attempts"`
  (how many were rendered), `"attempt"` (the one kept) and `"scores"` (each
  attempt's similarity, `nil` for no face).

  When the service can't embed the image, the first attempt is kept with
  `"error"` in `gate`: the anchor itself is fine, only unchecked.
  """
  def run(others, render, max \\ @attempts), do: attempt(0, max, others, render, [], nil)

  defp attempt(n, max, others, render, scores, best) do
    with {:ok, png, extra} <- render.(n) do
      case check(png, others) do
        {:ok, template, gate} ->
          scores = scores ++ [gate["similarity"]]
          best = better(best, {n, png, extra, template, gate})

          if gate["passed"] or n + 1 >= max,
            do: finish(best, scores),
            else: attempt(n + 1, max, others, render, scores, best)

        {:error, message} ->
          {:ok, png, extra, nil, %{"error" => message, "threshold" => @threshold}}
      end
    end
  end

  defp finish({n, png, extra, template, gate}, scores) do
    gate = Map.merge(gate, %{"attempts" => length(scores), "attempt" => n, "scores" => scores})
    {:ok, png, extra, template, gate}
  end

  # A face beats no face, then the lower similarity wins; the earlier attempt on a tie.
  defp better(nil, candidate), do: candidate

  defp better({_, _, _, _, old} = kept, {_, _, _, _, new} = candidate) do
    if rank(new) < rank(old), do: candidate, else: kept
  end

  defp rank(%{"faces" => 0}), do: {1, 0}
  defp rank(gate), do: {0, gate["similarity"] || -1.0}

  @doc """
  Embeds `png` and compares it with `others` (`{subject_name, template}`).

  Returns `{:ok, template, gate}`, where `gate` has `"faces"` (how many the
  detector found), `"similarity"` (to the most similar other person, `nil`
  when there's nobody to compare with or no face), `"closest"` (their subject
  name), `"threshold"` and `"passed"`. With no face `template` is `nil` and
  the check fails. Or `{:error, message}` when the service fails.
  """
  def check(png, others) do
    case Ridgegen.face_template(png) do
      {:ok, %{faces: 0}} ->
        {:ok, nil,
         %{"faces" => 0, "similarity" => nil, "threshold" => @threshold, "passed" => false}}

      {:ok, %{faces: faces, template: template}} ->
        {closest, similarity} = nearest(template, others)

        {:ok, template,
         %{
           "faces" => faces,
           "similarity" => similarity,
           "closest" => closest,
           "threshold" => @threshold,
           "passed" => is_nil(similarity) or similarity < @threshold
         }}

      {:error, message} ->
        {:error, message}
    end
  end

  @doc "The most similar of `others` (`{name, template}`) to `template`: `{name, similarity}`, or `{nil, nil}`."
  def nearest(template, others) do
    vector = decode(template)

    others
    |> Enum.map(fn {name, other} -> {name, dot(vector, decode(other))} end)
    |> Enum.max_by(&elem(&1, 1), fn -> {nil, nil} end)
    |> then(fn {name, score} -> {name, score && Float.round(score, 3)} end)
  end

  @doc "Cosine similarity of two templates (L2-normalised, so their dot product)."
  def similarity(a, b), do: a |> decode() |> dot(decode(b)) |> Float.round(3)

  @doc "A template as a list of floats."
  def decode(template), do: for(<<x::little-float-32 <- template>>, do: x)

  @doc "The dot product of two decoded templates."
  def dot(a, b), do: Enum.zip_reduce(a, b, 0.0, fn x, y, acc -> acc + x * y end)
end
