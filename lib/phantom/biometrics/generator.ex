defmodule Phantom.Biometrics.Generator do
  @moduledoc """
  Renders one subject of a run: every shot of the run, in order, each
  recorded through `Phantom.Biometrics` as it finishes.

  The subject's seed is derived from the run seed and its position, and
  everything else from that: its attributes (`FaceAttributes`), face prompts
  and seeds (`Generator.Faces`) and its fingers and palms
  (`Generator.FrictionRidges`). So rendering a subject again gives the same
  person, and images already stored are kept rather than rendered again.

  Face shots start with the anchor (the frontal mugshot) rendered from text;
  the other face shots are conditioned on it.
  """

  alias Phantom.Biometrics
  alias Phantom.Biometrics.{FaceAttributes, FacePrompts, Image, Run, Shots, Storage}
  alias Phantom.Biometrics.Generator.{Faces, FrictionRidges}

  @doc "Renders the subject at `position` (1-based) of `run`. Returns the completed subject."
  def generate_subject(%Run{} = run, position) do
    seed = derive_seed(run.seed, position)
    attributes = FaceAttributes.sample(seed)

    subject =
      Biometrics.start_subject(run, position, %{
        seed: seed,
        description: FaceAttributes.describe(attributes),
        # Stored as JSON: string keys, as it reads back.
        attributes: attributes |> Jason.encode!() |> Jason.decode!()
      })

    stored = Map.new(subject.images, &{&1.shot, &1})

    Enum.reduce(run.shots, nil, fn shot, anchor ->
      image = kept(stored[shot]) || render(Shots.spec(shot), run, subject, attributes, anchor)
      if shot == FacePrompts.anchor_shot() and Image.rendered?(image), do: image, else: anchor
    end)

    Biometrics.complete_subject(subject)
  end

  defp kept(image) do
    if Image.rendered?(image) and Storage.exists?(image.storage_key), do: image
  end

  defp render(spec, run, subject, attributes, anchor) do
    {duration_ms, {fields, result}} =
      :timer.tc(
        fn ->
          case spec.modality do
            :face -> Faces.render(spec, run, subject, attributes, anchor)
            :ridge -> FrictionRidges.render(spec, run, subject)
          end
        end,
        :millisecond
      )

    attrs =
      fields
      |> Map.merge(outcome(result, Storage.key(run.name, subject.name, spec.id)))
      |> Map.put(:duration_ms, duration_ms)

    {:ok, image} = Biometrics.save_image(subject, attrs)
    image
  end

  defp outcome({:ok, png, extra}, key) do
    case Storage.put(key, png) do
      {:ok, file} ->
        extra |> Map.merge(file) |> Map.merge(%{status: :ok, content_type: "image/png"})

      {:error, reason} ->
        failed(:error, "couldn't store the image: #{inspect(reason)}")
    end
  end

  defp outcome({status, message}, _key) when status in [:error, :skipped],
    do: failed(status, message)

  defp failed(status, message),
    do: %{status: status, error: message, storage_key: nil, byte_size: nil, sha256: nil}

  @doc "A deterministic 31-bit seed derived from a parent seed and a key."
  def derive_seed(parent, key), do: :erlang.phash2({parent, key}, 2_147_483_647)
end
