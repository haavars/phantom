defmodule Bilder.Biometrics.RunRequest do
  @moduledoc """
  Validates a request to start a run from the web UI. `shots` holds face shot
  ids and friction-ridge group names (`"rolled"`, `"slaps"`, `"palms"`,
  `"card"`), see `Bilder.Biometrics.Shots.expand/2`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Bilder.Biometrics.{FacePrompts, Runs, Shots}

  @max_subjects 100
  @steps [20, 30, 40, 50]

  @primary_key false
  embedded_schema do
    field :subjects, :integer, default: 3
    field :seed, :integer
    field :steps, :integer, default: 40

    field :shots, {:array, :string},
      default: FacePrompts.default_shots() ++ ~w(rolled slaps palms card)

    field :captures, :integer, default: 1
    field :run, :string
  end

  def max_subjects, do: @max_subjects
  def steps_options, do: @steps

  def changeset(request \\ %__MODULE__{}, attrs) do
    request
    |> cast(attrs, [:subjects, :seed, :steps, :shots, :captures, :run])
    # The form sends an empty value so unticking every box still submits `shots`.
    |> update_change(:shots, fn shots -> Enum.reject(shots, &(&1 == "")) end)
    |> validate_required([:subjects, :steps])
    |> validate_number(:subjects,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: @max_subjects
    )
    |> validate_number(:seed, greater_than_or_equal_to: 0, less_than: 2_147_483_647)
    |> validate_inclusion(:steps, @steps)
    |> validate_subset(
      :shots,
      FacePrompts.shots() ++ Enum.map(Shots.ridge_groups(), &elem(&1, 0))
    )
    |> validate_length(:shots, min: 1, message: "pick at least one shot")
    |> validate_number(:captures,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: Shots.max_captures()
    )
    |> validate_length(:run, max: 80)
    |> validate_format(:run, ~r/\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/,
      message: "use letters, digits, dots, dashes and underscores"
    )
    |> validate_change(:run, fn :run, run ->
      if Runs.exists?(run), do: [run: "already exists"], else: []
    end)
  end

  @doc "Harness options for a valid request."
  def to_opts(%__MODULE__{} = request) do
    [
      subjects: request.subjects,
      steps: request.steps,
      shots: request.shots,
      captures: request.captures,
      seed: request.seed,
      run: request.run
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end
end
