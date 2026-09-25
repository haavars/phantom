defmodule Phantom.Biometrics.FacePrompts do
  @moduledoc """
  Prompt templates for synthetic face images.

  Every subject starts from an *anchor* shot (the frontal mugshot), generated from
  text alone. Every other shot is image-conditioned on that anchor so the same
  identity carries across poses and probe images - the anchor is the only
  reference image ever sent, so this can't be pointed at a real person's photo.

  Sizes:

    * mugshots and probes are 3:4 (960×1280), the size and aspect of an
      ANSI/NIST-ITL level-40 mugshot (at least 768×1024)
    * ICAO portraits are 7:9 (896×1152), the 35×45 mm passport-photo aspect
    * the low-resolution probe is rendered as a mugshot and scaled down
      (`:downscale`) to 240×320, for an inter-eye distance of about 40 px,
      as in real search images that are much worse than the enrolment

  A shot rendered before keeps its stored size when it's rendered again.

  `pos` is the ANSI/NIST-ITL Type-10 subject pose code: `F` frontal, `L` left
  profile, `R` right profile, `A` angled. A left profile shows the subject's left
  side, so they face the *left* edge of the image.

  The mugshots (frontal, profiles, ¾ views) are one booking session, so they
  show scars as the anchor does. Every other shot is taken at another time,
  and any scar in it has healed.

  The probes (re-booking, aged, glasses, appearance, low resolution) are other photos than the
  reference, so each gets its own slight head angle and expression
  (`variation/2`), for testing face matching across pose and expression. The
  ICAO portrait stays compliant: frontal, neutral.

  Bump `@version` whenever a template changes, so harness runs record which
  prompts produced them.
  """

  alias Phantom.Biometrics.FaceAttributes

  @version "faces-v8"

  @mugshot {960, 1280}
  @icao {896, 1152}
  @low_res_scale 4
  @low_res {div(elem(@mugshot, 0), @low_res_scale), div(elem(@mugshot, 1), @low_res_scale)}

  @shots [
    %{id: "mugshot_frontal", pos: "F", size: @mugshot, anchor?: true},
    %{id: "mugshot_left_profile", pos: "L", size: @mugshot, anchor?: false},
    %{id: "mugshot_right_profile", pos: "R", size: @mugshot, anchor?: false},
    %{id: "mugshot_three_quarter_left", pos: "A", size: @mugshot, anchor?: false},
    %{id: "mugshot_three_quarter_right", pos: "A", size: @mugshot, anchor?: false},
    %{id: "icao_portrait", pos: "F", size: @icao, anchor?: false},
    %{id: "probe_rebooking", pos: "F", size: @mugshot, anchor?: false},
    %{id: "probe_aged", pos: "F", size: @mugshot, anchor?: false},
    %{id: "probe_glasses", pos: "F", size: @mugshot, anchor?: false},
    %{id: "probe_appearance", pos: "F", size: @mugshot, anchor?: false},
    %{id: "probe_low_res", pos: "F", size: @low_res, downscale: @low_res_scale, anchor?: false}
  ]

  @default_shots ~w(mugshot_frontal mugshot_left_profile mugshot_right_profile icao_portrait probe_rebooking probe_aged)

  @photo "Photorealistic, unretouched digital photograph with natural skin texture and sharp focus."

  @clean_frame "The image shows only the person against the background: no text, no placard, no height chart, no border."

  def version, do: @version
  def shots, do: Enum.map(@shots, & &1.id)
  def default_shots, do: @default_shots
  def anchor_shot, do: "mugshot_frontal"

  @doc """
  Returns the spec map for a shot id, or `nil`: `:id`, `:pos`, `:size` (of
  the stored image), `:anchor?`, and `:downscale`, how many times larger
  than `:size` it's rendered (1 for all but the low-resolution probe).
  """
  def spec(id) do
    with %{} = shot <- Enum.find(@shots, &(&1.id == id)), do: Map.put_new(shot, :downscale, 1)
  end

  @doc "Builds the prompt for shot `id` of the person described by `attrs`."
  def prompt("mugshot_frontal", attrs) do
    """
    Police booking photograph (mugshot) of #{FaceAttributes.describe(attrs)} \
    Frontal view: head and upper shoulders centred in the frame, facing the camera squarely \
    with the head level, both eyes open and looking straight into the lens, neutral expression, \
    mouth closed. #{pronoun(attrs)} is wearing #{attrs.clothing}. Plain, uniform mid-grey \
    background. Even, diffuse flash lighting from the front with no harsh shadows. Taken at eye \
    level. #{@photo} #{@clean_frame}\
    """
  end

  def prompt("mugshot_left_profile", attrs) do
    profile(attrs, """
    now photographed in a strict left profile: head and shoulders turned 90 degrees so the \
    person faces the left edge of the image, showing the left side of the face and the left ear, \
    with only the left eye visible and the nose pointing to the left of the frame.\
    """)
  end

  def prompt("mugshot_right_profile", attrs) do
    profile(attrs, """
    now photographed in a strict right profile: head and shoulders turned 90 degrees so the \
    person faces the right edge of the image, showing the right side of the face and the right \
    ear, with only the right eye visible and the nose pointing to the right of the frame.\
    """)
  end

  def prompt("mugshot_three_quarter_left", attrs) do
    profile(attrs, """
    now photographed in a three-quarter view: head and shoulders turned about 45 degrees so the \
    person faces towards the left side of the image, showing more of the left side of the face, \
    with both eyes still visible.\
    """)
  end

  def prompt("mugshot_three_quarter_right", attrs) do
    profile(attrs, """
    now photographed in a three-quarter view: head and shoulders turned about 45 degrees so the \
    person faces towards the right side of the image, showing more of the right side of the \
    face, with both eyes still visible.\
    """)
  end

  def prompt("icao_portrait", attrs) do
    edit(
      attrs,
      "Edit the reference photo into an ICAO 9303 compliant passport photograph of the same person.",
      [
        "zoom in and re-crop so the head is much larger: chin to top of the head fills about three quarters of the image height, with only the top of the shoulders visible",
        "replace the background with a plain, uniform, very light grey, almost white background",
        "the clothing is now #{alternate_clothing(attrs, 1)}",
        "soft, shadow-free studio lighting on both sides of the face with no reflections"
      ],
      "full-face frontal pose, head level, both eyes open looking into the camera, neutral expression, mouth closed, hair away from the eyes, no glasses, no head covering"
    )
  end

  def prompt("probe_rebooking", attrs) do
    edit(
      attrs,
      "Edit the reference photo into a different police booking photograph of the same person, taken a year later at another police station.",
      [
        "#{subject(attrs)} now wears #{alternate_clothing(attrs, 2)}",
        "harsh overhead fluorescent light casts shadows under the eyebrows, nose and chin, with a slight greenish-yellow colour cast",
        "the camera is a little higher and closer",
        "the hair is a little messier",
        "the background is a scuffed off-white painted wall"
      ] ++ varied("probe_rebooking", attrs),
      "head and upper shoulders in frame"
    )
  end

  # Qwen overdoes "15 years older" (18 to 33 came out looking 55), so the
  # ageing is spelled out for the age the person reaches, and capped.
  def prompt("probe_aged", attrs) do
    age = attrs.age + 15

    edit(
      attrs,
      "Edit the reference photo to show the same person 15 years later, now #{age} years old, at a later police booking.",
      [
        ageing(age),
        "the hair is #{aged_hair(attrs, age)}",
        "#{subject(attrs)} now wears #{alternate_clothing(attrs, 3)}"
      ] ++ varied("probe_aged", attrs),
      "head and upper shoulders, plain mid-grey background, even flash lighting. #{pronoun(attrs)} must look #{age}, no older"
    )
  end

  def prompt("probe_glasses", attrs) do
    edit(
      attrs,
      "Edit the reference photo into a casual indoor photograph of the same person wearing glasses.",
      [
        "#{subject(attrs)} now wears thin dark-rimmed rectangular prescription glasses",
        "#{subject(attrs)} now wears #{alternate_clothing(attrs, 4)}",
        "soft daylight from a window on the #{side(attrs)} side of the image, leaving the other side of the face in gentle shadow",
        "the background is a plain light-coloured wall"
      ] ++ varied("probe_glasses", attrs),
      "head and upper shoulders"
    )
  end

  def prompt("probe_appearance", attrs) do
    change =
      cond do
        attrs.sex == :female and attrs.hair =~ ~r/long|shoulder-length|ponytail|bun/ ->
          "the hair is now cut into a short, chin-length bob"

        attrs.sex == :female ->
          "the hair has grown out to shoulder length"

        attrs.facial_hair in [nil, "clean-shaven"] ->
          "#{subject(attrs)} has grown a short full beard; the hair on the head is unchanged"

        true ->
          "only the facial hair is shaved off, now clean-shaven; the hair on the head stays exactly as in the reference"
      end

    edit(
      attrs,
      "Edit the reference photo into a later police booking photograph of the same person with a changed appearance.",
      [change, "#{subject(attrs)} now wears #{alternate_clothing(attrs, 5)}"] ++
        varied("probe_appearance", attrs),
      "head and upper shoulders, plain mid-grey background, even flash lighting"
    )
  end

  # Rendered at mugshot size like the other probes, then scaled down: the
  # face model makes clean faces at any size, so the resolution comes from
  # the scaling, the ordinary snapshot from the prompt.
  def prompt("probe_low_res", attrs) do
    edit(
      attrs,
      "Edit the reference photo into an ordinary snapshot of the same person, taken indoors with a phone camera.",
      [
        "#{subject(attrs)} now wears #{alternate_clothing(attrs, 6)}",
        "dim, warm light from a ceiling lamp, a little uneven across the face",
        "the background is an ordinary room, slightly out of focus"
      ] ++ varied("probe_low_res", attrs),
      "head and upper shoulders in frame"
    )
  end

  # Expressions a probe can have. Qwen keeps the reference's expression unless
  # told otherwise, so each is a concrete target, never "a different expression".
  @expressions [
    "a relaxed, neutral expression with the lips slightly parted",
    "a slight, closed-mouth smile",
    "a broad smile showing the upper teeth",
    "a slight frown, with the eyebrows drawn together",
    "the eyebrows slightly raised, as if mildly surprised",
    "the eyes slightly narrowed, as if squinting in bright light",
    "the mouth slightly open, as if caught mid-sentence",
    "a tired look with heavy eyelids",
    "the lips pressed together in a tense, flat line"
  ]

  @doc """
  The head angle and expression of probe `shot` of the person `attrs`
  describes: the same for the same person and shot, different between shots
  and people. Slight on purpose, so the face stays clearly visible:

    * `:yaw` - degrees turned towards `:towards` (`"left"` / `"right"` of the image), 4-19
    * `:pitch` - `:level`, `:up` or `:down` (slightly)
    * `:roll` - `nil`, or the shoulder (`"left"` / `"right"`) the head leans towards
    * `:expression` - one of the expressions above
    * `:off_camera?` - whether the eyes look slightly past the camera
  """
  def variation(shot, attrs) do
    rng = :rand.seed_s(:exsss, {attrs.seed, :erlang.phash2(shot), 0x9E5})
    {yaw, rng} = :rand.uniform_s(16, rng)
    {towards, rng} = pick(["left", "right"], rng)
    {pitch, rng} = pick([:level, :up, :down], rng)
    {roll, rng} = pick([nil, nil, "left", "right"], rng)
    {expression, rng} = pick(@expressions, rng)
    {gaze, _rng} = :rand.uniform_s(rng)

    %{
      yaw: yaw + 3,
      towards: towards,
      pitch: pitch,
      roll: roll,
      expression: expression,
      off_camera?: gaze < 0.25
    }
  end

  defp varied(shot, attrs) do
    v = variation(shot, attrs)

    pitch =
      case v.pitch do
        :level -> "with the chin level"
        :up -> "with the chin raised slightly"
        :down -> "tilted slightly down"
      end

    roll = if v.roll, do: ", leaning slightly towards the #{v.roll} shoulder", else: ""

    gaze =
      if v.off_camera?, do: "looking slightly past the camera", else: "looking into the camera"

    [
      "unlike the reference, the head is turned about #{v.yaw} degrees towards the #{v.towards} of the image, #{pitch}#{roll}",
      "the expression changes to #{v.expression}, #{gaze}"
    ]
  end

  defp pick(list, rng) do
    {index, rng} = :rand.uniform_s(length(list), rng)
    {Enum.at(list, index - 1), rng}
  end

  defp profile(attrs, pose) do
    """
    Police booking photograph (mugshot) of the exact same person as in the reference image, \
    #{pose} #{keep_identity()} Same clothing (#{attrs.clothing}). Head level, neutral \
    expression, mouth closed. Head and upper shoulders in frame. Same plain, uniform mid-grey \
    background and even, diffuse lighting as the reference. #{@photo} #{@clean_frame}\
    """
  end

  # Image-conditioned edits: Qwen follows the reference closely, so vague asks like
  # "different clothing" get ignored. Spell each change out as a concrete target
  # state, and only ask it to keep the facial features.
  defp edit(attrs, intro, changes, pose) do
    healed = healed_scars(attrs)
    kept = if healed == [], do: "any scars, moles or freckles", else: "any moles or freckles"

    """
    #{intro} Changes: #{Enum.join(changes ++ healed, "; ")}. Keep the face shape, bone \
    structure, eyes, nose, mouth, ears, skin tone and #{kept} exactly the same, so it is \
    clearly the same individual. Pose: #{pose}. #{@photo} #{@clean_frame}\
    """
  end

  # How each scar in `FaceAttributes.marks/0` looks once it has healed: still
  # there, in the same place, but faded.
  @healed_scars %{
    "a thin healed scar through the right eyebrow" =>
      "the scar through the right eyebrow has fully healed into a thin, pale line in the same place, still leaving a narrow gap in the eyebrow hair",
    "a small scar above the left eyebrow" =>
      "the small scar above the left eyebrow has fully healed into a faint, flat, pale line in the same place, with no redness or scab",
    "faint acne scars on the cheeks" =>
      "the acne scars on the cheeks have fully healed and faded to a barely visible texture, with no redness or spots"
  }

  defp healed_scars(attrs) do
    for mark <- attrs.marks, mark =~ "scar" do
      Map.get_lazy(@healed_scars, mark, fn ->
        "#{String.replace_prefix(mark, "a ", "the ")} has fully healed and faded, still visible in the same place"
      end)
    end
  end

  # Another outfit for the person's sex, in another colour than the one
  # they wear in the mugshots, so the change is visible.
  defp alternate_clothing(attrs, n) do
    colour = FaceAttributes.clothing_colour(attrs.clothing)

    options =
      for item <- FaceAttributes.clothing(attrs.sex),
          item != attrs.clothing,
          is_nil(colour) or FaceAttributes.clothing_colour(item) != colour,
          do: item

    Enum.at(options, rem(attrs.seed + n, length(options)))
  end

  defp side(attrs), do: if(rem(attrs.seed, 2) == 0, do: "left", else: "right")

  defp ageing(age) when age <= 35 do
    "only subtle, natural maturing for someone of #{age}: the face is a little less round and youthful, with slightly more defined cheekbones and jaw, and at most very faint lines at the corners of the eyes; no wrinkles, no sagging skin, no age spots"
  end

  defp ageing(age) when age <= 49 do
    "moderate, realistic ageing for someone of #{age}: fine lines on the forehead and at the corners of the eyes, slightly deeper lines from nose to mouth and slightly less firm skin; no deep wrinkles, no sagging, no age spots"
  end

  defp ageing(age) when age <= 64 do
    "clear ageing for someone of #{age}: forehead lines, crow's feet around the eyes, deeper lines from nose to mouth, and slightly looser skin under the eyes and along the jaw"
  end

  defp ageing(age) do
    "strong ageing for someone of #{age}: deep forehead lines, crow's feet, deep lines from nose to mouth, looser skin under the eyes and jaw, thinner lips and a few age spots"
  end

  @grey ["grey", "white", "salt-and-pepper"]

  defp aged_hair(attrs, age) do
    grey? = attrs.hair_color in @grey

    cond do
      age <= 35 -> "the same colour as in the reference, with no grey"
      age <= 49 and grey? -> "a little whiter"
      age <= 49 -> "the same colour, with a few grey strands at the temples"
      age <= 64 and grey? -> "whiter"
      age <= 64 -> "noticeably greyer, especially at the temples, and a little thinner"
      grey? -> "whiter and thinner"
      true -> "mostly grey and thinner"
    end
  end

  defp subject(%{sex: :female}), do: "she"
  defp subject(_attrs), do: "he"

  defp keep_identity do
    "Keep the identity exactly the same: same face, nose, jawline, ears, skin tone, eye colour, " <>
      "hairstyle, facial hair, age and any scars, moles or freckles."
  end

  defp pronoun(%{sex: :female}), do: "She"
  defp pronoun(_attrs), do: "He"
end
