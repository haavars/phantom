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
    marks: [],
    features: []
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

  # Facial structure, one draw from each group: what makes one face look unlike
  # another once hair, age and clothing are set aside. Without these the model
  # draws much the same features for everyone of a sex, age and ancestry. Mild
  # wording ("a hooked nose") barely moves it off that face, so they're strong.
  @features [
    nose: [
      "a noticeably long straight nose",
      "a very short upturned nose",
      "a very broad nose with a bulbous tip",
      "a very narrow pointed nose",
      "a very prominent hooked nose",
      "a nose with a clear bump on the bridge",
      "a very small snub nose",
      "a wide nose with a very flat bridge",
      "a very large fleshy nose"
    ],
    eyes: [
      "deeply set eyes",
      "very wide-set eyes",
      "noticeably close-set eyes",
      "heavily hooded eyes",
      "unusually large round eyes",
      "very small narrow eyes",
      "strongly downturned eyes",
      "strongly upturned almond-shaped eyes",
      "very heavy-lidded eyes"
    ],
    eyebrows: [
      "very thick straight eyebrows",
      "very thin arched eyebrows",
      "very bushy eyebrows",
      "very sparse eyebrows",
      "low heavy eyebrows set close to the eyes",
      "high rounded eyebrows far above the eyes",
      "angled eyebrows that slope down at the outer ends"
    ],
    mouth: [
      "very thin lips",
      "noticeably full lips",
      "a very wide mouth",
      "a small mouth with a pronounced Cupid's bow",
      "a very thin upper lip and a fuller lower lip",
      "a mouth with clearly downturned corners",
      "a small narrow mouth"
    ],
    jaw: [
      "a very strong square jaw",
      "a narrow sharply pointed chin",
      "a small clearly receding chin",
      "a deep cleft chin",
      "a prominent jutting chin",
      "a very wide jaw",
      "a soft rounded jawline with little definition",
      "a noticeably long chin"
    ],
    cheeks: [
      "very high prominent cheekbones",
      "flat barely visible cheekbones",
      "very full rounded cheeks",
      "deeply hollow cheeks",
      "very wide cheekbones",
      "sharply defined cheekbones"
    ],
    ears: [
      "ears set close to the head",
      "noticeably protruding ears",
      "very large ears",
      "very small ears",
      "ears with very long lobes"
    ]
  ]

  # Everyday clothes, as `{description, main colour}`: for anyone, then for
  # women and for men. A person is sampled from the ones for anyone and for
  # their sex. The colour is what shows most in a head-and-shoulders photo;
  # probe prompts swap in an item of another colour, since a near-duplicate
  # reads as "no change".
  @clothing_any [
    {"a plain grey crew-neck t-shirt", "grey"},
    {"a plain black t-shirt", "black"},
    {"a plain white t-shirt", "white"},
    {"a dark blue hooded sweatshirt", "navy"},
    {"a red and black checked flannel shirt", "red"},
    {"an olive green bomber jacket over a black t-shirt", "olive"},
    {"a mustard-yellow knitted jumper", "yellow"},
    {"a denim jacket over a white t-shirt", "denim"},
    {"a burgundy sweatshirt", "burgundy"},
    {"a light blue button-up shirt", "light blue"},
    {"a charcoal zip-up fleece", "charcoal"},
    {"a bright orange high-visibility work jacket", "orange"},
    {"a beige trench coat over a dark jumper", "beige"},
    {"a forest green rain jacket with the hood down", "green"}
  ]

  @clothing_female [
    {"a white blouse with a small rounded collar", "white"},
    {"a floral-print blouse with short sleeves and a round neck", "floral"},
    {"a fitted black V-neck top", "black"},
    {"a pale pink knitted cardigan over a white top", "pink"},
    {"a navy blazer over a cream silk blouse", "navy"},
    {"a red ribbed turtleneck jumper", "red"},
    {"a striped navy-and-white Breton top", "striped"},
    {"a lilac hooded sweatshirt", "lilac"},
    {"an emerald green satin blouse", "emerald"},
    {"a camel wool coat with the collar turned up", "camel"},
    {"a light denim shirt dress", "denim"},
    {"a teal crew-neck knit top", "teal"}
  ]

  @clothing_male [
    {"a navy polo shirt", "navy"},
    {"a white dress shirt with an open collar", "white"},
    {"a grey suit jacket over a white shirt and no tie", "grey"},
    {"a black leather biker jacket", "black"},
    {"a green and white football shirt", "green"},
    {"a brown corduroy jacket over a checked shirt", "brown"},
    {"a dark green quilted gilet over a grey t-shirt", "olive"},
    {"a maroon V-neck jumper over a collared shirt", "burgundy"},
    {"a blue work shirt with the sleeves rolled up", "blue"},
    {"a black tracksuit top with white stripes on the shoulders", "black"},
    {"a tan canvas work jacket", "tan"},
    {"a sky-blue pinstriped shirt", "light blue"}
  ]

  @all_clothing @clothing_any ++ @clothing_female ++ @clothing_male

  @doc "Every clothing item."
  def clothing, do: Enum.map(@all_clothing, &elem(&1, 0))

  @doc "The clothes a person of `sex` is sampled from: the ones for anyone, then theirs."
  def clothing(:female), do: Enum.map(@clothing_any ++ @clothing_female, &elem(&1, 0))
  def clothing(:male), do: Enum.map(@clothing_any ++ @clothing_male, &elem(&1, 0))

  @doc "Clothing as `{group, items}`: for anyone, women's and men's."
  def clothing_groups do
    [
      {"For anyone", Enum.map(@clothing_any, &elem(&1, 0))},
      {"Women's", Enum.map(@clothing_female, &elem(&1, 0))},
      {"Men's", Enum.map(@clothing_male, &elem(&1, 0))}
    ]
  end

  @doc "The main colour of a clothing item, or nil for one that isn't listed."
  def clothing_colour(item) do
    case List.keyfind(@all_clothing, item, 0) do
      {_item, colour} -> colour
      nil -> nil
    end
  end

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

  # Pulls the model off the idealised face it draws by default.
  @ordinary_face "an ordinary, unglamorous face with its own irregular proportions and " <>
                   "features, not a model's or an idealised face"

  @doc "The facial features sampled for everyone, as `{group, options}`: one of each group."
  def features, do: @features

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
    {clothing, rng} = sex |> clothing() |> pick(rng) |> fixed(opts[:clothing])
    {marks, rng} = rng |> marks() |> fixed(opts[:marks])
    # Drawn last, so the draws above are the same as before there were features.
    {features, _rng} = features(rng)
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
      marks: marks,
      features: features
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
    %{attrs | sex: sex(attrs.sex), marks: attrs.marks || [], features: attrs.features || []}
  end

  defp sex("female"), do: :female
  defp sex("male"), do: :male
  defp sex(sex), do: sex

  @doc """
  Describes the person in a few sentences, face first: "a 34-year-old man
  with an ordinary, unglamorous face ...: a very prominent hooked nose, deeply
  set eyes, ... The first things anyone notices about his face are ... He is of
  West African descent, with dark brown skin, ...".

  The face comes first, and two of its features are called out as the most
  noticeable, because that's what the model follows most: in test renders
  this spread faces further apart than the same features after age, hair and
  clothing. Attributes without features (subjects sampled before they
  existed) are described as they were then: who, then how they look.
  """
  def describe(%__MODULE__{features: []} = attrs) do
    "#{article(attrs.age)} #{attrs.age}-year-old #{noun(attrs)} of #{attrs.ancestry} descent with " <>
      to_sentence(appearance(attrs)) <> "." <> marks_sentence(attrs)
  end

  def describe(%__MODULE__{} = attrs) do
    {pronoun, possessive} = pronouns(attrs)
    [first, second] = noticeable(attrs)

    "#{article(attrs.age)} #{attrs.age}-year-old #{noun(attrs)} with #{@ordinary_face}: " <>
      "#{to_sentence(attrs.features)}. The first things anyone notices about #{possessive} " <>
      "face are #{first} and #{second}, and #{possessive} face is slightly asymmetric. " <>
      "#{pronoun} is of #{attrs.ancestry} descent, with #{to_sentence(appearance(attrs))}." <>
      marks_sentence(attrs)
  end

  defp noun(attrs), do: if(attrs.sex == :female, do: "woman", else: "man")
  defp pronouns(%{sex: :female}), do: {"She", "her"}
  defp pronouns(_attrs), do: {"He", "his"}

  defp appearance(attrs) do
    [
      "#{attrs.skin_tone} skin",
      "#{attrs.eye_color} eyes",
      "#{article(attrs.face_shape)} #{attrs.face_shape} face",
      "#{article(attrs.build)} #{attrs.build} build",
      attrs.hair
    ] ++ List.wrap(attrs.facial_hair)
  end

  defp marks_sentence(%{marks: []}), do: ""
  defp marks_sentence(attrs), do: " #{elem(pronouns(attrs), 0)} has #{to_sentence(attrs.marks)}."

  # Two different features, chosen by the seed so a person always gets the same two.
  defp noticeable(%{seed: seed, features: features}) do
    count = length(features)
    first = rem(seed, count)
    second = rem(div(seed, count), count - 1)
    second = if second >= first, do: second + 1, else: second
    [Enum.at(features, first), Enum.at(features, second)]
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

  defp features(rng),
    do: Enum.map_reduce(@features, rng, fn {_group, options}, rng -> pick(options, rng) end)

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
