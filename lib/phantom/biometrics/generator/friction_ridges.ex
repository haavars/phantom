defmodule Phantom.Biometrics.Generator.FrictionRidges do
  @moduledoc """
  Renders fingers, slaps, palms and the tenprint card with
  `Phantom.Services.Ridgegen`. They all come from the subject seed, so every
  image of one subject shows the same fingers and palms.
  """

  alias Phantom.Services.Ridgegen

  @doc """
  Renders the friction-ridge shot `spec` of `subject`. Returns `{fields,
  result}`: the image's fields, and `{:ok, png, %{meta:, ground_truth:}}` or
  `{:error, message}`.
  """
  def render(spec, run, subject) do
    {width, height} = spec.size

    fields = %{
      shot: spec.id,
      modality: :ridge,
      pos: spec.code,
      capture: spec.capture,
      width: width,
      height: height,
      seed: subject.seed
    }

    result =
      with {:ok, %{image: png, meta: meta, generator: generator}} <-
             Ridgegen.render(spec.kind, spec.numeric_code, subject.seed, spec.capture,
               label: subject.name,
               renderer: run.renderer
             ) do
        {:ok, png, %{meta: summarize(meta), ground_truth: Map.put(meta, "generator", generator)}}
      end

    {fields, result}
  end

  # `meta` keeps the small facts (pattern classes, counts, verification
  # scores) for pages and reports; minutiae and drift point lists stay in the
  # full ground truth.
  defp summarize(meta) do
    meta
    |> Map.drop(["minutiae", "generator"])
    |> Map.update("fingers", nil, fn fingers ->
      Enum.map(fingers, &Map.take(&1, ["fgp", "pattern"]))
    end)
    |> Map.update("verification", nil, fn check ->
      check
      |> Map.drop(["missed", "spurious", "detected"])
      |> Map.update("fingers", nil, fn fingers ->
        Enum.map(fingers, &Map.take(&1, ["fgp", "nfiq2", "minutiae_recall", "minutiae_spurious"]))
      end)
      |> Map.reject(fn {_key, value} -> is_nil(value) end)
    end)
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end
end
