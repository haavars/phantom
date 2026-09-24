defmodule Phantom.Biometrics.Subject do
  @moduledoc """
  One synthetic person in a run: the seed that defines them, their sampled
  attributes (`Phantom.Biometrics.FaceAttributes`) and their images.

  `name` (`subject_001`) is unique within the run and used in URLs.
  `completed_at` is set once every shot has been attempted.
  """

  use Ecto.Schema

  alias Phantom.Biometrics.{Image, Run}

  schema "subjects" do
    field :position, :integer
    field :name, :string
    field :seed, :integer
    field :description, :string
    field :attributes, :map, default: %{}
    field :completed_at, :utc_datetime_usec

    belongs_to :run, Run
    has_many :images, Image, preload_order: [asc: :id]

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The subject name for a 1-based position: `subject_001`."
  def name(position), do: "subject_" <> String.pad_leading(Integer.to_string(position), 3, "0")
end
