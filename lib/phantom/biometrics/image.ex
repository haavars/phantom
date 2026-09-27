defmodule Phantom.Biometrics.Image do
  @moduledoc """
  One shot of a subject (see `Phantom.Biometrics.Shots`): whether it was
  rendered, how, and where the file is (`storage_key`, see
  `Phantom.Biometrics.Storage`).

  Face shots keep their prompt and the anchor image they were conditioned on
  (`reference`). The anchor also keeps its ArcFace `template` and, in `meta`,
  how it did against the other anchors of its run (`"gate"`, see
  `Phantom.Biometrics.FaceGate`). Friction-ridge shots keep a summary of their ground truth in
  `meta` (pattern classes, counts, verification scores) and the full ground
  truth (minutiae, singular points, detected minutiae) in `ground_truth`.

  Ids are UUIDv7: they sort by creation time, like the old integer ids, but
  are never reused, so an image URL (`/images/<id>`) can't show a picture a
  browser cached for another image before a database reset.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Phantom.Biometrics.Subject

  @primary_key {:id, Ecto.UUID, autogenerate: [version: 7, precision: :monotonic]}

  schema "images" do
    field :shot, :string
    field :modality, Ecto.Enum, values: [:face, :ridge]
    field :capture, :integer, default: 0
    field :pos, :string
    field :status, Ecto.Enum, values: [:ok, :error, :skipped]
    field :width, :integer
    field :height, :integer
    field :seed, :integer
    field :prompt, :string
    field :storage_key, :string
    field :content_type, :string
    field :byte_size, :integer
    field :sha256, :string
    field :meta, :map
    field :ground_truth, :map
    field :template, :binary, redact: true
    field :duration_ms, :integer
    field :error, :string

    belongs_to :subject, Subject
    belongs_to :reference, __MODULE__, type: Ecto.UUID

    timestamps(type: :utc_datetime_usec)
  end

  @fields [
    :shot,
    :modality,
    :capture,
    :pos,
    :status,
    :width,
    :height,
    :seed,
    :prompt,
    :reference_id,
    :storage_key,
    :content_type,
    :byte_size,
    :sha256,
    :meta,
    :ground_truth,
    :template,
    :duration_ms,
    :error
  ]

  @doc "The result of rendering (or trying to render) a shot."
  def changeset(image, attrs) do
    image
    |> cast(attrs, @fields)
    |> validate_required([:shot, :modality, :status])
    |> unique_constraint([:subject_id, :shot])
  end

  @doc "True when the image was rendered and has a file."
  def rendered?(%__MODULE__{status: :ok, storage_key: key}), do: is_binary(key)
  def rendered?(_image), do: false
end
