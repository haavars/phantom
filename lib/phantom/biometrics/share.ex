defmodule Phantom.Biometrics.Share do
  @moduledoc """
  One export of a subject uploaded to the S3 bucket and shared as a link
  (see `Phantom.Biometrics.Shares`).

  `kind` is `:zip` (`Phantom.Biometrics.Export`, `options` `include`) or
  `:nist` (`Phantom.Biometrics.NistExport`, `options` `content`,
  `compression` and `search`). A share is `:queued`, `:uploading`, `:ready`
  (with `url` until `link_expires_at`) or `:failed` (with `error`). The file
  is deleted from the bucket at `expires_at` by the bucket's lifecycle rule.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Phantom.Biometrics.Subject

  @primary_key {:id, Ecto.UUID, autogenerate: [version: 7, precision: :monotonic]}

  schema "shares" do
    field :kind, Ecto.Enum, values: [:zip, :nist]
    field :options, :map, default: %{}
    field :status, Ecto.Enum, values: [:queued, :uploading, :ready, :failed], default: :queued
    field :filename, :string
    field :key, :string
    field :content_type, :string
    field :byte_size, :integer
    field :sha256, :string
    field :url, :string, redact: true
    field :link_expires_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :error, :string

    belongs_to :subject, Subject

    timestamps(type: :utc_datetime_usec)
  end

  @fields [
    :kind,
    :options,
    :status,
    :filename,
    :key,
    :content_type,
    :byte_size,
    :sha256,
    :url,
    :link_expires_at,
    :expires_at,
    :error
  ]

  def changeset(share, attrs) do
    share
    |> cast(attrs, @fields)
    |> validate_required([:kind, :status, :filename])
  end

  @doc "Whether the file is still in the bucket (the lifecycle rule hasn't deleted it)."
  def stored?(%__MODULE__{status: :ready, expires_at: %DateTime{} = at}),
    do: DateTime.after?(at, DateTime.utc_now())

  def stored?(_share), do: false

  @doc "Whether the share's link works now."
  def link_valid?(%__MODULE__{link_expires_at: %DateTime{} = at} = share),
    do: stored?(share) and DateTime.after?(at, DateTime.utc_now())

  def link_valid?(_share), do: false
end
