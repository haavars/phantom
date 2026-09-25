defmodule Phantom.Biometrics.Generator.Faces do
  @moduledoc """
  Renders face shots with `Phantom.Services.Qwen`: the anchor from its
  prompt alone, every other face shot from its prompt and the anchor image,
  so all of them show the same person.
  """

  alias Phantom.Biometrics.{FacePrompts, Generator, Storage}
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
    {width, height} = inputs(previous, :size) || spec.size

    fields = %{
      shot: spec.id,
      modality: :face,
      pos: spec.code,
      capture: 0,
      width: width,
      height: height,
      seed: inputs(previous, :seed) || Generator.derive_seed(subject.seed, spec.id),
      prompt: inputs(previous, :prompt) || FacePrompts.prompt(spec.id, attributes),
      reference_id: anchor && anchor.id
    }

    result =
      with {:ok, references} <- references(spec, anchor),
           {:ok, %{image: png}} <-
             Qwen.render(fields.prompt,
               width: width * spec.downscale,
               height: height * spec.downscale,
               steps: run.steps,
               seed: fields.seed,
               images: references
             ),
           {:ok, png} <- downscale(png, spec.downscale) do
        {:ok, png, %{}}
      end

    {fields, result}
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
