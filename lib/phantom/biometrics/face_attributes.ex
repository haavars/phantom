defmodule Phantom.Biometrics.FaceAttributes do
  @moduledoc """
  Samples the appearance of a synthetic person from a seed.

  The same seed always gives the same attributes, so a subject (and every prompt
  built from it) can be regenerated exactly. `describe/1` turns the attributes
  into the sentence the prompt templates in `Phantom.Biometrics.FacePrompts` use.

  Ancestry is sampled uniformly by default so a test gallery covers a broad range
  of appearances; pass `:ancestry_weights` / `:female_share` to `sample/2` to match
  a specific population instead, or fix any attribute (`:sex`, `:ancestry`,
  `:skin_tone`, ...) to give every subject of a run the same one (see
  `Phantom.Biometrics.Traits`).

  The option lists (`ancestries/0`, `skin_tones/1`, `hair_styles/0`, ...) are
  what attributes can be fixed to.
  """

  @derive Jason.Encoder
  defstruct [
    :seed,
    :sex,
    :age,
    :ancestry,
    :skin_tone,
    :eye_color,
    :hair_color,
    :hair,
    :facial_hair,
    :face_shape,
    :build,
    :clothing,
    marks: []
  ]

  @type t :: %__MODULE__{}

  # Per-ancestry appearance ranges. Deliberately broad descriptors: the model
  # fills in natural variation, and the seed makes each draw reproducible.
  @ancestries %{
    "Northern European" => %{
      skin: ["very fair", "fair", "light"],
      eyes: ["blue", "grey-blue", "green", "hazel", "light brown"],
      hair: ["blond", "light brown", "dark blond", "brown", "red", "auburn"],
      texture: ["straight", "wavy"]
    },
    "Southern European" => %{
      skin: ["light olive", "olive", "light"],
      eyes: ["brown", "dark brown", "hazel", "green"],
      hair: ["dark brown", "black", "brown"],
      texture: ["straight", "wavy", "curly"]
    },
    "Eastern European" => %{
      skin: ["fair", "light"],
      eyes: ["blue", "grey", "green", "brown", "hazel"],
      hair: ["light brown", "brown", "dark blond", "dark brown"],
      texture: ["straight", "wavy"]
    },
    "West African" => %{
      skin: ["deep brown", "dark brown", "brown"],
      eyes: ["dark brown", "brown"],
      hair: ["black"],
      texture: ["tightly coiled", "coily"]
    },
    "East African" => %{
      skin: ["dark brown", "brown", "deep brown"],
      eyes: ["dark brown", "brown"],
      hair: ["black"],
      texture: ["tightly coiled", "curly", "coily"]
    },
    "North African" => %{
      skin: ["light olive", "olive", "light brown"],
      eyes: ["brown", "dark brown", "hazel"],
      hair: ["black", "dark brown"],
      texture: ["wavy", "curly", "straight"]
    },
    "Middle Eastern" => %{
      skin: ["light olive", "olive", "light brown"],
      eyes: ["brown", "dark brown", "hazel", "green"],
      hair: ["black", "dark brown"],
      texture: ["straight", "wavy", "curly"]
    },
    "South Asian" => %{
      skin: ["light brown", "brown", "medium brown", "dark brown"],
      eyes: ["dark brown", "brown"],
      hair: ["black", "dark brown"],
      texture: ["straight", "wavy"]
    },
    "East Asian" => %{
      skin: ["light", "fair", "light beige"],
      eyes: ["dark brown", "brown"],
      hair: ["black", "dark brown"],
      texture: ["straight"]
    },
    "Southeast Asian" => %{
      skin: ["light brown", "tan", "medium brown"],
      eyes: ["dark brown", "brown"],
      hair: ["black", "dark brown"],
      texture: ["straight", "wavy"]
    },
    "Latin American" => %{
      skin: ["light tan", "tan", "light brown", "medium brown"],
      eyes: ["brown", "dark brown", "hazel"],
      hair: ["black", "dark brown", "brown"],
      texture: ["straight", "wavy", "curly"]
    }
  }

  # Hair styles: `{id, label, template}`. Sampling picks from the list for the
  # subject's sex (and a receding hairline or shaved head for some men); a
  # fixed style applies to anyone.
  @male_hair [
    {"short", "Short", "short {texture} {color} hair"},
    {"buzz_cut", "Buzz cut", "a {color} buzz cut"},
    {"short_sides", "Short sides, longer on top",
     "{texture} {color} hair, short on the sides and longer on top"},
    {"medium", "Medium length", "medium-length {texture} {color} hair"},
    {"side_parting", "Side parting", "short {texture} {color} hair with a side parting"}
  ]

  @receding {"receding", "Receding hairline", "a receding hairline with short {color} hair"}
  @shaved {"shaved", "Shaved head", "a shaved head"}

  @female_hair [
    {"long_loose", "Long, worn loose", "long {texture} {color} hair worn loose"},
    {"ponytail", "Ponytail", "{texture} {color} hair tied back in a ponytail"},
    {"shoulder_length", "Shoulder length", "shoulder-length {texture} {color} hair"},
    {"bob", "Short bob", "a short {texture} {color} bob"},
    {"bun", "Bun", "{texture} {color} hair pulled back into a bun"},
    {"pixie", "Pixie cut", "a short {color} pixie cut"}
  ]

  @hair_styles @male_hair ++ [@receding, @shaved] ++ @female_hair

  # Display order for the colours and textures the ancestries use, light to dark.
  @skin_tones [
    "very fair",
    "fair",
    "light",
    "light beige",
    "light olive",
    "olive",
    "light tan",
    "tan",
    "light brown",
    "medium brown",
    "brown",
    "dark brown",
    "deep brown"
  ]

  @eye_colors [
    "blue",
    "grey-blue",
    "grey",
    "green",
    "hazel",
    "light brown",
    "brown",
    "dark brown"
  ]

  @hair_colors [
    "blond",
    "dark blond",
    "red",
    "auburn",
    "light brown",
    "brown",
    "dark brown",
    "black"
  ]

  @grey_hair ["grey", "white", "salt-and-pepper"]

  @hair_textures ["straight", "wavy", "curly", "coily", "tightly coiled"]

  @facial_hair [
    {"clean-shaven", 40},
    {"a few days of stubble", 25},
    {"a short full beard", 15},
    {"a moustache", 7},
    {"a goatee", 7},
    {"a long full beard", 6}
  ]

  @face_shapes ["oval", "round", "square", "long", "heart-shaped", "diamond-shaped"]

  @builds [{"slim", 25}, {"average", 45}, {"stocky", 15}, {"heavy-set", 15}]

  @marks [
    "freckles across the nose and cheeks",
    "a small mole on the left cheek",
    "a small mole on the right side of the chin",
    "faint acne scars on the cheeks",
    "a thin healed scar through the right eyebrow",
    "a small scar above the left eyebrow",
    "a slightly crooked nose",
    "prominent dark circles under the eyes"
  ]

  # Kept clearly distinct in colour and type, because probe prompts swap in a
  # different item from this list and near-duplicates read as "no change".
  @clothing [
    "a plain grey crew-neck t-shirt",
    "a plain black t-shirt",
    "a plain white t-shirt",
    "a dark blue hooded sweatshirt",
    "a red and black checked flannel shirt",
    "an olive green bomber jacket over a black t-shirt",
    "a mustard-yellow knitted jumper",
    "a denim jacket over a white t-shirt",
    "a burgundy sweatshirt",
    "a light blue button-up shirt"
  ]

  def clothing, do: @clothing

  def ancestries, do: @ancestries |> Map.keys() |> Enum.sort()

  @doc "Skin tones `ancestry` is sampled from, or every skin tone for `nil`."
  def skin_tones(ancestry \\ nil), do: palette(@skin_tones, :skin, ancestry)

  @doc "Eye colours `ancestry` is sampled from, or every eye colour for `nil`."
  def eye_colors(ancestry \\ nil), do: palette(@eye_colors, :eyes, ancestry)

  @doc "Hair colours `ancestry` is sampled from, or all of them for `nil`, then grey and white."
  def hair_colors(ancestry \\ nil), do: palette(@hair_colors, :hair, ancestry) ++ @grey_hair

  @doc "Hair textures `ancestry` is sampled from, or all of them for `nil`."
  def hair_textures(ancestry \\ nil), do: palette(@hair_textures, :texture, ancestry)

  defp palette(all, _key, nil), do: all

  defp palette(all, key, ancestry) do
    case @ancestries do
      %{^ancestry => palette} -> Enum.filter(all, &(&1 in Map.fetch!(palette, key)))
      _unknown -> all
    end
  end

  @doc "Hair styles as `{label, id}`, men's first."
  def hair_styles, do: for({id, label, _template} <- @hair_styles, do: {label, id})

  @doc "The hair styles subjects of `sex` are sampled from, as `{label, id}`."
  def hair_styles(:male),
    do: for({id, label, _} <- @male_hair ++ [@receding, @shaved], do: {label, id})

  def hair_styles(:female), do: for({id, label, _} <- @female_hair, do: {label, id})

  def facial_hair_options, do: Enum.map(@facial_hair, &elem(&1, 0))
  def face_shapes, do: @face_shapes
  def builds, do: Enum.map(@builds, &elem(&1, 0))
  def marks, do: @marks

  @doc """
  Samples attributes for `seed`.

  Options:

    * `:female_share` - probability of a female subject, defaults to 0.5
    * `:age_range` - inclusive `min..max`, defaults to `18..75`
    * `:ancestry_weights` - map of ancestry name to weight, defaults to uniform over `ancestries/0`

  Fixed attributes, instead of sampling them:

    * `:sex` (`:female` / `:male`), `:ancestry`
    * `:skin_tone`, `:eye_color`, `:hair_color` (not greyed with age) and
      `:hair_texture`, from the option lists
    * `:hair_style` - an id from `hair_styles/0`
    * `:facial_hair` - for men; women have none
    * `:face_shape`, `:build`, `:clothing`
    * `:marks` - a list, `[]` for none

  A fixed attribute still takes its random draw, so the attributes left
  random come from the same draws whatever is fixed.
  """
  def sample(seed, opts \\ []) when is_integer(seed) do
    rng = :rand.seed_s(:exsss, {seed, 0x5EED, 0xFACE})

    {sex, rng} =
      [
        {:female, Keyword.get(opts, :female_share, 0.5)},
        {:male, 1.0 - Keyword.get(opts, :female_share, 0.5)}
      ]
      |> weighted(rng)
      |> fixed(opts[:sex])

    {age, rng} = pick(Enum.to_list(Keyword.get(opts, :age_range, 18..75)), rng)

    {ancestry, rng} =
      opts
      |> Keyword.get(:ancestry_weights, Map.new(ancestries(), &{&1, 1}))
      |> Enum.sort()
      |> weighted(rng)
      |> fixed(opts[:ancestry])

    palette = Map.fetch!(@ancestries, ancestry)
    {skin_tone, rng} = palette.skin |> pick(rng) |> fixed(opts[:skin_tone])
    {eye_color, rng} = palette.eyes |> pick(rng) |> fixed(opts[:eye_color])
    {base_hair_color, rng} = pick(palette.hair, rng)
    {texture, rng} = palette.texture |> pick(rng) |> fixed(opts[:hair_texture])
    {hair_color, rng} = base_hair_color |> age_hair_color(age, rng) |> fixed(opts[:hair_color])
    {hair_style, rng} = sex |> hair_style(age, rng) |> fixed(opts[:hair_style])
    {facial_hair, rng} = sex |> facial_hair(rng) |> fixed(sex == :male && opts[:facial_hair])
    {face_shape, rng} = @face_shapes |> pick(rng) |> fixed(opts[:face_shape])
    {build, rng} = @builds |> weighted(rng) |> fixed(opts[:build])
    {clothing, rng} = @clothing |> pick(rng) |> fixed(opts[:clothing])
    {marks, _rng} = rng |> marks() |> fixed(opts[:marks])
    hair = fill_hair(hair_style, texture, hair_color)

    %__MODULE__{
      seed: seed,
      sex: sex,
      age: age,
      ancestry: ancestry,
      skin_tone: skin_tone,
      eye_color: eye_color,
      hair_color: hair_color,
      hair: hair,
      facial_hair: facial_hair,
      face_shape: face_shape,
      build: build,
      clothing: clothing,
      marks: marks
    }
  end

  @doc "The attributes as a subject stores them: a JSON map with string keys."
  def to_map(%__MODULE__{} = attrs), do: attrs |> Jason.encode!() |> Jason.decode!()

  @doc "Attributes stored with `to_map/1`, back as a struct. Unknown keys are ignored."
  def from_map(%{} = map) do
    fields =
      for key <- Map.keys(Map.from_struct(%__MODULE__{})),
          Map.has_key?(map, Atom.to_string(key)),
          do: {key, Map.fetch!(map, Atom.to_string(key))}

    attrs = struct!(__MODULE__, fields)
    %{attrs | sex: sex(attrs.sex), marks: attrs.marks || []}
  end

  defp sex("female"), do: :female
  defp sex("male"), do: :male
  defp sex(sex), do: sex

  @doc """
  Describes the person in one or two sentences, e.g. "a 34-year-old man of West
  African descent with dark brown skin, ...".
  """
  def describe(%__MODULE__{} = attrs) do
    noun = if attrs.sex == :female, do: "woman", else: "man"
    pronoun = if attrs.sex == :female, do: "She", else: "He"

    features =
      [
        "#{attrs.skin_tone} skin",
        "#{attrs.eye_color} eyes",
        "#{article(attrs.face_shape)} #{attrs.face_shape} face",
        "#{article(attrs.build)} #{attrs.build} build",
        attrs.hair
      ] ++ List.wrap(attrs.facial_hair)

    first =
      "#{article(attrs.age)} #{attrs.age}-year-old #{noun} of #{attrs.ancestry} descent with " <>
        to_sentence(features)

    case attrs.marks do
      [] -> first <> "."
      marks -> first <> ". #{pronoun} has #{to_sentence(marks)}."
    end
  end

  defp age_hair_color(color, age, rng) do
    {roll, rng} = :rand.uniform_s(rng)

    cond do
      age >= 60 and roll < 0.7 -> pick(["grey", "white", "salt-and-pepper"], rng)
      age >= 45 and roll < 0.4 -> {"greying #{color}", rng}
      true -> {color, rng}
    end
  end

  defp hair_style(:male, age, rng) do
    {roll, rng} = :rand.uniform_s(rng)

    cond do
      age >= 40 and roll < 0.3 -> {elem(@receding, 0), rng}
      roll < 0.08 -> {elem(@shaved, 0), rng}
      true -> pick_style(@male_hair, rng)
    end
  end

  defp hair_style(:female, _age, rng), do: pick_style(@female_hair, rng)

  defp pick_style(styles, rng) do
    {{id, _label, _template}, rng} = pick(styles, rng)
    {id, rng}
  end

  defp fill_hair(style, texture, color) do
    {_id, _label, template} = List.keyfind!(@hair_styles, style, 0)

    template
    |> String.replace("{texture}", texture)
    |> String.replace("{color}", color)
  end

  # Takes a fixed value over the drawn one, keeping the draw.
  defp fixed(drawn, fixed) when fixed in [nil, false], do: drawn
  defp fixed({_drawn, rng}, fixed), do: {fixed, rng}

  defp facial_hair(:female, rng), do: {nil, rng}
  defp facial_hair(:male, rng), do: weighted(@facial_hair, rng)

  defp marks(rng) do
    {roll, rng} = :rand.uniform_s(rng)

    if roll < 0.35 do
      {mark, rng} = pick(@marks, rng)
      {[mark], rng}
    else
      {[], rng}
    end
  end

  defp pick(list, rng) do
    {index, rng} = :rand.uniform_s(length(list), rng)
    {Enum.at(list, index - 1), rng}
  end

  defp weighted(pairs, rng) do
    total = pairs |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    {roll, rng} = :rand.uniform_s(rng)
    target = roll * total

    value =
      Enum.reduce_while(pairs, 0, fn {value, weight}, acc ->
        if acc + weight >= target, do: {:halt, {:found, value}}, else: {:cont, acc + weight}
      end)

    case value do
      {:found, value} -> {value, rng}
      # Float rounding can leave `target` a hair above the running sum.
      _sum -> {pairs |> List.last() |> elem(0), rng}
    end
  end

  defp article(age) when is_integer(age) do
    if age in [8, 11, 18] or age in 80..89, do: "an", else: "a"
  end

  defp article(<<first, _::binary>>) when first in ~c"aeiouAEIOU", do: "an"
  defp article(_word), do: "a"

  defp to_sentence([one]), do: one
  defp to_sentence([one, two]), do: "#{one} and #{two}"

  defp to_sentence(items) do
    {init, [last]} = Enum.split(items, -1)
    Enum.join(init, ", ") <> " and " <> last
  end
end
