defmodule Phantom.Biometrics.RunRequest do
  @moduledoc """
  The parameters of a new run, as `Phantom.Biometrics.create_run/1` takes
  them from the web form or from IEx. `shots` holds shot ids and group
  names (`"faces"`, `"rolled"`, `"slaps"`, `"palms"`, `"card"`), see
  `Phantom.Biometrics.Shots.expand/2`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Phantom.Biometrics
  alias Phantom.Biometrics.{FacePrompts, Run, Shots}

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
    field :renderer, :string, default: "diffusion"
    field :run, :string
  end

  def max_subjects, do: @max_subjects
  def steps_options, do: @steps

  def changeset(request \\ %__MODULE__{}, attrs) do
    request
    |> cast(attrs, [:subjects, :seed, :steps, :shots, :captures, :renderer, :run])
    # The form sends an empty value so unticking every box still submits `shots`.
    |> update_change(:shots, fn shots -> Enum.reject(shots, &(&1 == "")) end)
    |> validate_required([:subjects, :steps])
    |> validate_number(:subjects,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: @max_subjects
    )
    |> validate_number(:seed, greater_than_or_equal_to: 0, less_than: 2_147_483_647)
    |> validate_inclusion(:steps, @steps)
    |> validate_length(:shots, min: 1, message: "pick at least one shot")
    |> validate_change(:shots, fn :shots, shots ->
      case Shots.expand(shots) do
        {:ok, _ids} -> []
        {:error, message} -> [shots: message]
      end
    end)
    |> validate_number(:captures,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: Shots.max_captures()
    )
    |> validate_inclusion(:renderer, Run.renderers())
    |> validate_length(:run, max: 80)
    |> validate_format(:run, ~r/\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/,
      message: "use letters, digits, dots, dashes and underscores"
    )
    |> validate_change(:run, fn :run, run ->
      if Biometrics.run_exists?(run), do: [run: "already exists"], else: []
    end)
  end
end
