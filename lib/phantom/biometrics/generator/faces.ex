defmodule Phantom.Biometrics.Generator.Faces do
  @moduledoc """
  Renders face shots with `Phantom.Services.Qwen`: the anchor from its
  prompt alone, every other face shot from its prompt and the anchor image,
  so all of them show the same person.

  The anchor goes through `Phantom.Biometrics.FaceGate` (`render_anchor/6`):
  one too like another person of the run is rendered again with the next
  seed and facial features.
  """

  alias Phantom.Biometrics.{FaceAttributes, FaceGate, FacePrompts, Generator, Storage}
  alias Phantom.Services.Qwen
  alias Vix.Vips.{Image, Operation}

  @doc """
  Renders the face shot `spec` of `subject`. Returns `{fields, result}`: the
  image's fields, and `{:ok, png, %{}}`, `{:error, message}`, or
  `{:skipped, message}` when the anchor it needs failed.

  A shot rendered before (`previous`, its image record) is rendered again
  from its stored prompt, seed and size rather than today's templates.

  A shot with a `:downscale` above 1 (the low-resolution probe) is rendered
  that many times larger than its size, then scaled down to it.
  """
  def render(spec, run, subject, attributes, anchor, previous) do
    fields = fields(spec, subject, attributes, anchor, previous, 0)
    {fields, draw(spec, run, fields, anchor)}
  end

  @doc """
  Renders the anchor `spec` of `subject`, checked against `others`, the
  `{subject_name, template}` of the run's other anchors (`FaceGate`).

  Attempt 0 is the shot as `render/6` renders it; a later attempt `n` has the
  features of `FaceAttributes.reroll_features(attributes, n)` and a seed
  derived from `{shot, n}`. Returns `{fields, result, attributes}`: as
  `render/6`, for the attempt kept, with its `:template` and
  `meta["gate"]` in the result's extra fields, and its attributes.

  An anchor rendered before (`previous`) is rendered again once, from its
  stored prompt and seed, and only checked; its gate keeps the attempts
  recorded then.
  """
  def render_anchor(spec, run, subject, attributes, previous, others) do
    render = fn n ->
      attempt_attributes = FaceAttributes.reroll_features(attributes, n)
      fields = fields(spec, subject, attempt_attributes, nil, previous, n)

      case draw(spec, run, fields, nil) do
        {:ok, png, extra} ->
          {:ok, png, %{fields: fields, attributes: attempt_attributes, extra: extra}}

        error ->
          {:error, {fields, error}}
      end
    end

    attempts = if previous, do: 1, else: FaceGate.attempts()

    case FaceGate.run(others, render, attempts) do
      {:ok, png, %{fields: fields, attributes: kept, extra: extra}, template, gate} ->
        gate = Map.merge(gate, recorded_attempts(previous))
        extra = Map.merge(extra, %{template: template, meta: %{"gate" => gate}})
        {fields, {:ok, png, extra}, kept}

      {:error, {fields, error}} ->
        {fields, error, attributes}
    end
  end

  defp recorded_attempts(%{meta: %{"gate" => %{} = gate}}),
    do: Map.take(gate, ["attempts", "attempt", "scores"])

  defp recorded_attempts(_previous), do: %{}

  defp fields(spec, subject, attributes, anchor, previous, attempt) do
    {width, height} = inputs(previous, :size) || spec.size

    %{
      shot: spec.id,
      modality: :face,
      pos: spec.code,
      capture: 0,
      width: width,
      height: height,
      seed: inputs(previous, :seed) || seed(subject, spec, attempt),
      prompt: inputs(previous, :prompt) || FacePrompts.prompt(spec.id, attributes),
      reference_id: anchor && anchor.id
    }
  end

  defp seed(subject, spec, 0), do: Generator.derive_seed(subject.seed, spec.id)
  defp seed(subject, spec, attempt), do: Generator.derive_seed(subject.seed, {spec.id, attempt})

  defp draw(spec, run, fields, anchor) do
    with {:ok, references} <- references(spec, anchor),
         {:ok, %{image: png}} <-
           Qwen.render(fields.prompt,
             width: fields.width * spec.downscale,
             height: fields.height * spec.downscale,
             steps: run.steps,
             seed: fields.seed,
             images: references
           ),
         {:ok, png} <- downscale(png, spec.downscale) do
      {:ok, png, %{}}
    end
  end

  # By `factor`, with libvips' default Lanczos kernel.
  defp downscale(png, 1), do: {:ok, png}

  defp downscale(png, factor) do
    with {:ok, image} <- Image.new_from_buffer(png),
         {:ok, small} <- Operation.resize(image, 1 / factor),
         {:ok, data} <- Image.write_to_buffer(small, ".png") do
      {:ok, data}
    else
      {:error, reason} -> {:error, "couldn't scale the image down: #{inspect(reason)}"}
    end
  end

  defp inputs(%{width: width, height: height}, :size)
       when is_integer(width) and is_integer(height),
       do: {width, height}

  defp inputs(%{} = previous, key) when key in [:seed, :prompt], do: Map.get(previous, key)
  defp inputs(_previous, _key), do: nil

  defp references(%{anchor?: true}, _anchor), do: {:ok, []}
  defp references(_spec, nil), do: {:skipped, "anchor shot failed"}

  defp references(_spec, anchor) do
    case Storage.read(anchor.storage_key) do
      {:ok, data} ->
        {:ok, [%{data: data, filename: anchor.shot <> ".png", content_type: "image/png"}]}

      {:error, reason} ->
        {:error, "couldn't read the anchor image: #{inspect(reason)}"}
    end
  end
end
