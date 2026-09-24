defmodule Phantom.Biometrics.Run do
  @moduledoc """
  One harness run: its settings, status and friction-ridge quality report.
  Its subjects and their images are `Phantom.Biometrics.Subject` and
  `Phantom.Biometrics.Image`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Phantom.Biometrics.Subject

  @statuses ~w(running finished cancelled failed)

  schema "runs" do
    field :name, :string
    field :seed, :integer
    field :status, :string, default: "running"
    field :shots, {:array, :string}, default: []
    field :captures, :integer, default: 1
    field :renderer, :string
    field :steps, :integer
    field :prompt_version, :string
    field :subject_count, :integer
    field :report, :map
    field :error, :string
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec

    # Set by `Phantom.Biometrics.Runs` when listing or loading runs.
    field :completed_subjects, :integer, virtual: true, default: 0
    field :cover, :any, virtual: true

    has_many :subjects, Subject, preload_order: [asc: :position]

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses

  @doc "Settings of a run being started or resumed."
  def start_changeset(run, attrs) do
    run
    |> cast(attrs, [
      :name,
      :seed,
      :shots,
      :captures,
      :renderer,
      :steps,
      :prompt_version,
      :subject_count
    ])
    |> validate_required([:name, :seed, :subject_count])
    |> put_change(:status, "running")
    |> put_change(:error, nil)
    |> put_change(:started_at, DateTime.utc_now())
    |> put_change(:finished_at, nil)
    |> unique_constraint(:name)
  end

  @doc "A run reaching `status`, with an error message for failed runs."
  def finish_changeset(run, status, error \\ nil) when status in @statuses do
    change(run,
      status: status,
      error: error,
      finished_at: if(status != "running", do: DateTime.utc_now())
    )
  end
end
