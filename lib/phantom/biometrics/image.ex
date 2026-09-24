defmodule Phantom.Biometrics.Image do
  @moduledoc """
  One shot of a subject (see `Phantom.Biometrics.Shots`): whether it was
  rendered, how, and where the file is (`storage_key`, see
  `Phantom.Biometrics.Storage`).

  Face shots keep their prompt and the anchor image they were conditioned on
  (`reference`). Friction-ridge shots keep a summary of their ground truth in
  `meta` (pattern classes, counts, verification scores) and the full ground
  truth (minutiae, singular points, detected minutiae) in `ground_truth`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Phantom.Biometrics.Subject

  @statuses ~w(ok error skipped)

  schema "images" do
    field :shot, :string
    field :modality, :string
    field :capture, :integer, default: 0
    field :pos, :string
    field :status, :string
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
    field :duration_ms, :integer
    field :error, :string

    belongs_to :subject, Subject
    belongs_to :reference, __MODULE__

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
    :duration_ms,
    :error
  ]

  @doc "The result of rendering (or trying to render) a shot."
  def changeset(image, attrs) do
    image
    |> cast(attrs, @fields)
    |> validate_required([:shot, :modality, :status])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:modality, ["face", "ridge"])
    |> unique_constraint([:subject_id, :shot])
  end

  @doc "True when the image was rendered and has a file."
  def rendered?(%__MODULE__{status: "ok", storage_key: key}), do: is_binary(key)
  def rendered?(_image), do: false
end
