defmodule Phantom.Biometrics.FaceAttributesTest do
  use ExUnit.Case, async: true

  alias Phantom.Biometrics.FaceAttributes

  test "the same seed always gives the same attributes" do
    assert FaceAttributes.sample(1234) == FaceAttributes.sample(1234)
    refute FaceAttributes.sample(1234) == FaceAttributes.sample(1235)
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

  test "describe/1 mentions the core attributes" do
    attrs = FaceAttributes.sample(7)
    description = FaceAttributes.describe(attrs)

    assert description =~ "#{attrs.age}-year-old"
    assert description =~ attrs.ancestry
    assert description =~ attrs.skin_tone
    assert String.ends_with?(description, ".")
  end
end
