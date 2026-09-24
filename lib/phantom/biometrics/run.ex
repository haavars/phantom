defmodule Phantom.Biometrics.Run do
  @moduledoc """
  A batch of synthetic subjects: its settings, where it is in its lifecycle
  and its friction-ridge quality report (`Phantom.Biometrics.Report`).

  A run is `:queued` when created, with one `GenerateSubject` job per subject.
  It turns `:running` when its first subject starts and `:finished` when its
  last one is done. `:cancelled` and `:failed` runs can be resumed.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Phantom.Biometrics.Subject

  @renderers ~w(diffusion procedural)

  schema "runs" do
    field :name, :string
    field :seed, :integer

    field :status, Ecto.Enum,
      values: [:queued, :running, :finished, :cancelled, :failed],
      default: :queued

    field :shots, {:array, :string}, default: []
    field :captures, :integer, default: 1
    field :renderer, :string, default: "diffusion"
    field :steps, :integer
    field :prompt_version, :string
    # Appearance every subject shares (`Phantom.Biometrics.Traits.to_map/1`).
    field :traits, :map, default: %{}
    field :subject_count, :integer
    field :report, :map
    field :error, :string
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec

    # Set by `Phantom.Biometrics` when listing or loading runs.
    field :completed_subjects, :integer, virtual: true, default: 0
    field :cover, :any, virtual: true

    has_many :subjects, Subject, preload_order: [asc: :position]

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Friction-ridge renderers, the default first: realistic (GPU) or a fast CPU draft."
  def renderers, do: @renderers

  @doc "A new run, or an existing one being queued again (resumed)."
  def queue_changeset(run, attrs) do
    run
    |> cast(attrs, [
      :name,
      :seed,
      :shots,
      :captures,
      :renderer,
      :steps,
      :prompt_version,
      :traits,
      :subject_count
    ])
    |> validate_required([:name, :seed, :shots, :subject_count])
    |> validate_inclusion(:renderer, @renderers)
    |> put_change(:status, :queued)
    |> put_change(:error, nil)
    |> put_change(:finished_at, nil)
    |> unique_constraint(:name)
  end

  @doc "Moves a run to `status`; finished, cancelled and failed runs get a finish time."
  def status_changeset(run, status, error \\ nil) do
    now = DateTime.utc_now()

    run
    |> change(status: status, error: error)
    |> then(fn changeset ->
      case status do
        :running -> put_change(changeset, :started_at, run.started_at || now)
        :queued -> changeset
        _done -> put_change(changeset, :finished_at, now)
      end
    end)
  end

  def active?(%__MODULE__{status: status}), do: status in [:queued, :running]
end
