defmodule Phantom.Biometrics.FaceAttributesTest do
  use ExUnit.Case, async: true

  alias Phantom.Biometrics.FaceAttributes

  test "the same seed always gives the same attributes" do
    assert FaceAttributes.sample(1234) == FaceAttributes.sample(1234)
    refute FaceAttributes.sample(1234) == FaceAttributes.sample(1235)
  end

  test "the option lists cover everything the ancestries sample" do
    for ancestry <- FaceAttributes.ancestries() do
      # Filtering by ancestry only drops values, it never loses one.
      assert FaceAttributes.skin_tones(ancestry) != []
      assert FaceAttributes.eye_colors(ancestry) != []
      assert FaceAttributes.hair_textures(ancestry) != []
    end

    for seed <- 1..300 do
      attrs = FaceAttributes.sample(seed)
      assert attrs.skin_tone in FaceAttributes.skin_tones(attrs.ancestry)
      assert attrs.eye_color in FaceAttributes.eye_colors(attrs.ancestry)
      assert attrs.clothing in FaceAttributes.clothing()
      assert attrs.face_shape in FaceAttributes.face_shapes()
      assert attrs.build in FaceAttributes.builds()
      assert Enum.all?(attrs.marks, &(&1 in FaceAttributes.marks()))

      base_color = String.replace_prefix(attrs.hair_color, "greying ", "")
      assert base_color in FaceAttributes.hair_colors()
    end

    assert length(FaceAttributes.hair_styles(:male)) + length(FaceAttributes.hair_styles(:female)) ==
             length(FaceAttributes.hair_styles())
  end

  test "people wear clothes for anyone or for their sex" do
    groups = Map.new(FaceAttributes.clothing_groups())
    women_only = groups["Women's"]
    men_only = groups["Men's"]

    assert length(FaceAttributes.clothing()) >= 36
    assert Enum.sort(Enum.flat_map(groups, &elem(&1, 1))) == Enum.sort(FaceAttributes.clothing())

    assert FaceAttributes.clothing() |> Enum.uniq() |> length() ==
             length(FaceAttributes.clothing())

    assert Enum.all?(FaceAttributes.clothing(), &FaceAttributes.clothing_colour/1)

    people = for seed <- 1..400, do: FaceAttributes.sample(seed)

    for person <- people do
      assert person.clothing in FaceAttributes.clothing(person.sex)
      if person.sex == :female, do: refute(person.clothing in men_only)
      if person.sex == :male, do: refute(person.clothing in women_only)
    end

    # Both the shared and the sex-specific clothes get picked.
    worn = MapSet.new(people, & &1.clothing)
    assert Enum.any?(women_only, &(&1 in worn))
    assert Enum.any?(men_only, &(&1 in worn))
    assert Enum.any?(groups["For anyone"], &(&1 in worn))
  end

  test "attributes read back from how a subject stores them" do
    for seed <- 1..50 do
      attrs = FaceAttributes.sample(seed)
      stored = FaceAttributes.to_map(attrs)

      assert %{"sex" => sex} = stored
      assert is_binary(sex)
      assert FaceAttributes.from_map(stored) == attrs
    end
  end

  test "respects sex, age and ancestry options" do
    for seed <- 1..50 do
      attrs =
        FaceAttributes.sample(seed,
          female_share: 1.0,
          age_range: 20..30,
          ancestry_weights: %{"East Asian" => 1}
        )

      assert attrs.sex == :female
      assert attrs.age in 20..30
      assert attrs.ancestry == "East Asian"
      assert attrs.facial_hair == nil
    end
  end

  test "everyone gets one feature from each group of facial features" do
    for seed <- 1..200 do
      attrs = FaceAttributes.sample(seed)
      groups = FaceAttributes.features()

      assert length(attrs.features) == length(groups)

      for {feature, {_group, options}} <- Enum.zip(attrs.features, groups),
          do: assert(feature in options)
    end

    # Varied between people, not one face for everyone.
    noses = MapSet.new(1..200, &hd(FaceAttributes.sample(&1).features))
    assert MapSet.size(noses) > 5
  end

  test "features are drawn after the other attributes, which stay the same" do
    attrs = FaceAttributes.sample(1234)
    fixed = FaceAttributes.sample(1234, sex: :female, ancestry: "East Asian", marks: [])

    assert attrs.features == fixed.features
  end

  test "reroll_features/2 draws other features for the same person, the same for an attempt" do
    attrs = FaceAttributes.sample(1234)

    assert FaceAttributes.reroll_features(attrs, 0) == attrs

    first = FaceAttributes.reroll_features(attrs, 1)
    assert first == FaceAttributes.reroll_features(attrs, 1)
    assert %{first | features: attrs.features} == attrs
    assert first.features != attrs.features
    assert length(first.features) == length(attrs.features)
    assert FaceAttributes.reroll_features(attrs, 2).features != first.features
  end

  test "describe/1 puts the face first and calls out two of its features" do
    attrs = FaceAttributes.sample(7)
    description = FaceAttributes.describe(attrs)

    assert description =~ ~r/^an? \d+-year-old (wo)?man with an ordinary, unglamorous face/
    for feature <- attrs.features, do: assert(description =~ feature)

    [_, first, second] =
      Regex.run(
        ~r/first things anyone notices about \w+ face are (.+) and (.+), and/,
        description
      )

    assert first != second
    assert first in attrs.features and second in attrs.features

    # The face comes before who they are and how they look.
    {face_at, _} = :binary.match(description, hd(attrs.features))
    {ancestry_at, _} = :binary.match(description, attrs.ancestry)
    assert face_at < ancestry_at

    # The same person always gets the same two.
    assert FaceAttributes.describe(attrs) == description
  end

  test "describe/1 describes subjects stored without features as before" do
    attrs = FaceAttributes.sample(7)
    stored = attrs |> FaceAttributes.to_map() |> Map.delete("features")
    old = FaceAttributes.from_map(stored)

    assert old.features == []
    assert FaceAttributes.describe(old) =~ ~r/^an? \d+-year-old (wo)?man of .+ descent with /
    refute FaceAttributes.describe(old) =~ "unglamorous"
  end

  test "describe/1 mentions the core attributes" do
    attrs = FaceAttributes.sample(7)
    description = FaceAttributes.describe(attrs)

    assert description =~ "#{attrs.age}-year-old"
    assert description =~ attrs.ancestry
    assert description =~ attrs.skin_tone
    assert String.ends_with?(description, ".")
  end
end
