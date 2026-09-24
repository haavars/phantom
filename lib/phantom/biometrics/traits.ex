defmodule Phantom.Biometrics.Traits do
  @moduledoc """
  The appearance a run gives all of its subjects. Every trait left `nil` is
  random: sampled for each subject by `Phantom.Biometrics.FaceAttributes`,
  except the distinguishing mark, which is the exception rather than the
  rule: nobody has one unless the run asks for it.

  A run stores its traits (`to_map/1`) and each subject is sampled with them
  (`sample_opts/1`), so ten Northern European women in their thirties with
  blue eyes are:

      Phantom.Biometrics.create_run(%{
        subjects: 10,
        traits: %{sex: "female", ancestry: "Northern European", age_min: 30, age_max: 39,
                  eye_color: "blue"}
      })

  `mark` is one of `FaceAttributes.marks/0` for everyone, `"random"` for a
  random mark on some subjects (about one in three), or `nil` / `"none"` for
  no marks. `facial_hair` only applies to men.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Phantom.Biometrics.FaceAttributes

  @min_age 18
  @max_age 90
  @default_ages 18..75

  @primary_key false
  embedded_schema do
    field :sex, :string
    field :age_min, :integer
    field :age_max, :integer
    field :ancestry, :string
    field :skin_tone, :string
    field :eye_color, :string
    field :hair_color, :string
    field :hair_texture, :string
    field :hair_style, :string
    field :facial_hair, :string
    field :face_shape, :string
    field :build, :string
    field :clothing, :string
    field :mark, :string
  end

  @fields [
    :sex,
    :age_min,
    :age_max,
    :ancestry,
    :skin_tone,
    :eye_color,
    :hair_color,
    :hair_texture,
    :hair_style,
    :facial_hair,
    :face_shape,
    :build,
    :clothing,
    :mark
  ]

  @doc "Every trait, in display order."
  def fields, do: @fields

  def min_age, do: @min_age
  def max_age, do: @max_age
  def default_ages, do: @default_ages

  @doc "The values a trait can be fixed to (all of them, whatever the ancestry)."
  def options(:sex), do: ["female", "male"]
  def options(:ancestry), do: FaceAttributes.ancestries()
  def options(:skin_tone), do: FaceAttributes.skin_tones()
  def options(:eye_color), do: FaceAttributes.eye_colors()
  def options(:hair_color), do: FaceAttributes.hair_colors()
  def options(:hair_texture), do: FaceAttributes.hair_textures()
  def options(:hair_style), do: Enum.map(FaceAttributes.hair_styles(), &elem(&1, 1))
  def options(:facial_hair), do: FaceAttributes.facial_hair_options()
  def options(:face_shape), do: FaceAttributes.face_shapes()
  def options(:build), do: FaceAttributes.builds()
  def options(:clothing), do: FaceAttributes.clothing()
  def options(:mark), do: ["none", "random" | FaceAttributes.marks()]

  def changeset(traits \\ %__MODULE__{}, attrs) do
    traits
    |> cast(attrs, @fields)
    |> validate_number(:age_min,
      greater_than_or_equal_to: @min_age,
      less_than_or_equal_to: @max_age
    )
    |> validate_number(:age_max,
      greater_than_or_equal_to: @min_age,
      less_than_or_equal_to: @max_age
    )
    |> validate_age_range()
    |> then(fn changeset ->
      Enum.reduce(@fields -- [:age_min, :age_max], changeset, fn field, changeset ->
        validate_inclusion(changeset, field, options(field), message: "isn't an option")
      end)
    end)
  end

  defp validate_age_range(changeset) do
    first..last//_ = ages(get_field(changeset, :age_min), get_field(changeset, :age_max))

    if first > last,
      do: add_error(changeset, :age_max, "must be at least the minimum age"),
      else: changeset
  end

  # An open end of the range is the default one.
  defp ages(nil, nil), do: @default_ages
  defp ages(min, max), do: (min || @default_ages.first)..(max || @default_ages.last)//1

  @doc "The traits that are set, as a run stores them: a map with string keys."
  def to_map(nil), do: %{}

  def to_map(%__MODULE__{} = traits) do
    for field <- @fields, value = Map.fetch!(traits, field), !is_nil(value), into: %{} do
      {Atom.to_string(field), value}
    end
  end

  @doc "Stored traits (`to_map/1`) as `FaceAttributes.sample/2` options."
  def sample_opts(stored) when is_map(stored) do
    traits = for field <- @fields, into: %{}, do: {field, stored[Atom.to_string(field)]}

    [
      sex: traits.sex && String.to_existing_atom(traits.sex),
      age_range: (traits.age_min || traits.age_max) && ages(traits.age_min, traits.age_max),
      ancestry: traits.ancestry,
      skin_tone: traits.skin_tone,
      eye_color: traits.eye_color,
      hair_color: traits.hair_color,
      hair_texture: traits.hair_texture,
      hair_style: traits.hair_style,
      facial_hair: traits.facial_hair,
      face_shape: traits.face_shape,
      build: traits.build,
      clothing: traits.clothing,
      marks:
        case traits.mark do
          "random" -> nil
          none when none in [nil, "none"] -> []
          mark -> [mark]
        end
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  @doc """
  Short phrases for the traits that are set, for display:
  `["Female", "Northern European", "30–39 years", "blue eyes"]`.
  """
  def describe(stored) when is_map(stored) do
    get = &stored[Atom.to_string(&1)]

    [
      get.(:sex) && String.capitalize(get.(:sex)),
      get.(:ancestry),
      age_phrase(get.(:age_min), get.(:age_max)),
      get.(:skin_tone) && "#{get.(:skin_tone)} skin",
      get.(:eye_color) && "#{get.(:eye_color)} eyes",
      get.(:hair_color) && "#{get.(:hair_color)} hair",
      get.(:hair_texture) && "#{get.(:hair_texture)} hair",
      get.(:hair_style) && hair_style_label(get.(:hair_style)),
      get.(:facial_hair),
      get.(:face_shape) && "#{get.(:face_shape)} face",
      get.(:build) && "#{get.(:build)} build",
      get.(:clothing),
      case get.(:mark) do
        none when none in [nil, "none"] -> nil
        "random" -> "a mark on some"
        mark -> mark
      end
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp age_phrase(nil, nil), do: nil

  defp age_phrase(min, max) do
    case ages(min, max) do
      age..age//_ -> "#{age} years"
      first..last//_ -> "#{first}–#{last} years"
    end
  end

  @doc "The label of a hair style id."
  def hair_style_label(id) do
    case List.keyfind(FaceAttributes.hair_styles(), id, 1) do
      {label, _id} -> "hair: " <> String.downcase(label)
      nil -> id
    end
  end
end
