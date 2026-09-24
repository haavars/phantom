defmodule Phantom.Biometrics.Generator.Faces do
  @moduledoc """
  Renders face shots with `Phantom.Services.Qwen`: the anchor from its
  prompt alone, every other face shot from its prompt and the anchor image,
  so all of them show the same person.
  """

  alias Phantom.Biometrics.{FacePrompts, Generator, Storage}
  alias Phantom.Services.Qwen

  @doc """
  Renders the face shot `spec` of `subject`. Returns `{fields, result}`: the
  image's fields, and `{:ok, png, %{}}`, `{:error, message}`, or
  `{:skipped, message}` when the anchor it needs failed.
  """
  def render(spec, run, subject, attributes, anchor) do
    {width, height} = spec.size

    fields = %{
      shot: spec.id,
      modality: :face,
      pos: spec.code,
      capture: 0,
      width: width,
      height: height,
      seed: Generator.derive_seed(subject.seed, spec.id),
      prompt: FacePrompts.prompt(spec.id, attributes),
      reference_id: anchor && anchor.id
    }

    result =
      with {:ok, references} <- references(spec, anchor),
           {:ok, %{image: png}} <-
             Qwen.render(fields.prompt,
               width: width,
               height: height,
               steps: run.steps,
               seed: fields.seed,
               images: references
             ) do
        {:ok, png, %{}}
      end

    {fields, result}
  end

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
