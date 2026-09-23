defmodule Bilder.Biometrics.FaceAttributes do
  @moduledoc """
  Samples the appearance of a synthetic person from a seed.

  The same seed always gives the same attributes, so a subject (and every prompt
  built from it) can be regenerated exactly. `describe/1` turns the attributes
  into the sentence the prompt templates in `Bilder.Biometrics.FacePrompts` use.

  Ancestry is sampled uniformly by default so a test gallery covers a broad range
  of appearances; pass `:ancestry_weights` / `:female_share` to `sample/2` to match
  a specific population instead.
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

  @male_hair [
    "short {texture} {color} hair",
    "a {color} buzz cut",
    "{texture} {color} hair, short on the sides and longer on top",
    "medium-length {texture} {color} hair",
    "short {texture} {color} hair with a side parting"
  ]

  @female_hair [
    "long {texture} {color} hair worn loose",
    "{texture} {color} hair tied back in a ponytail",
    "shoulder-length {texture} {color} hair",
    "a short {texture} {color} bob",
    "{texture} {color} hair pulled back into a bun",
    "a short {color} pixie cut"
  ]

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

  @doc """
  Samples attributes for `seed`.

  Options:

    * `:female_share` - probability of a female subject, defaults to 0.5
    * `:age_range` - inclusive `min..max`, defaults to `18..75`
    * `:ancestry_weights` - map of ancestry name to weight, defaults to uniform over `ancestries/0`
  """
  def sample(seed, opts \\ []) when is_integer(seed) do
    rng = :rand.seed_s(:exsss, {seed, 0x5EED, 0xFACE})

    {sex, rng} =
      weighted(
        [
          {:female, Keyword.get(opts, :female_share, 0.5)},
          {:male, 1.0 - Keyword.get(opts, :female_share, 0.5)}
        ],
        rng
      )

    {age, rng} = pick(Enum.to_list(Keyword.get(opts, :age_range, 18..75)), rng)

    {ancestry, rng} =
      opts
      |> Keyword.get(:ancestry_weights, Map.new(ancestries(), &{&1, 1}))
      |> Enum.sort()
      |> weighted(rng)

    palette = Map.fetch!(@ancestries, ancestry)
    {skin_tone, rng} = pick(palette.skin, rng)
    {eye_color, rng} = pick(palette.eyes, rng)
    {base_hair_color, rng} = pick(palette.hair, rng)
    {texture, rng} = pick(palette.texture, rng)
    {hair_color, rng} = age_hair_color(base_hair_color, age, rng)
    {hair, rng} = hair(sex, age, texture, hair_color, rng)
    {facial_hair, rng} = facial_hair(sex, rng)
    {face_shape, rng} = pick(@face_shapes, rng)
    {build, rng} = weighted(@builds, rng)
    {clothing, rng} = pick(@clothing, rng)
    {marks, _rng} = marks(rng)

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

  defp hair(:male, age, texture, color, rng) do
    {roll, rng} = :rand.uniform_s(rng)

    cond do
      age >= 40 and roll < 0.3 -> {"a receding hairline with short #{color} hair", rng}
      roll < 0.08 -> {"a shaved head", rng}
      true -> fill_hair(@male_hair, texture, color, rng)
    end
  end

  defp hair(:female, _age, texture, color, rng), do: fill_hair(@female_hair, texture, color, rng)

  defp fill_hair(templates, texture, color, rng) do
    {template, rng} = pick(templates, rng)

    hair =
      template
      |> String.replace("{texture}", texture)
      |> String.replace("{color}", color)

    {hair, rng}
  end

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
