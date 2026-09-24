defmodule Phantom.Biometrics.FacePromptsTest do
  use ExUnit.Case, async: true

  alias Phantom.Biometrics.{FaceAttributes, FacePrompts}

  test "every shot has a spec and a fully filled-in prompt" do
    attrs = FaceAttributes.sample(99)

    for shot <- FacePrompts.shots() do
      assert %{pos: pos, size: {width, height}} = FacePrompts.spec(shot)
      assert pos in ~w(F L R A)
      assert rem(width, 32) == 0 and rem(height, 32) == 0

      prompt = FacePrompts.prompt(shot, attrs)
      refute prompt =~ ~r/[{}]|#\{/
      refute String.ends_with?(prompt, "\n")
    end
  end

  test "only the anchor shot is generated from text alone" do
    assert [anchor] = Enum.filter(FacePrompts.shots(), &FacePrompts.spec(&1).anchor?)
    assert anchor == FacePrompts.anchor_shot()
    assert FacePrompts.anchor_shot() in FacePrompts.default_shots()
  end

  test "scars look as on the anchor in the mugshots and have healed in every later shot" do
    later = ~w(icao_portrait probe_rebooking probe_aged probe_glasses probe_appearance)
    session = FacePrompts.shots() -- later

    for mark <- Enum.filter(FaceAttributes.marks(), &(&1 =~ "scar")) do
      attrs = FaceAttributes.sample(5, marks: [mark])

      for shot <- session do
        refute FacePrompts.prompt(shot, attrs) =~ "healed into"
        refute FacePrompts.prompt(shot, attrs) =~ "fully healed"
      end

      for shot <- later do
        prompt = FacePrompts.prompt(shot, attrs)
        assert prompt =~ "fully healed"

        assert prompt =~
                 "Keep the face shape, bone structure, eyes, nose, mouth, ears, skin tone and any moles or freckles exactly the same"
      end
    end

    # Moles and the like carry over unchanged.
    attrs = FaceAttributes.sample(5, marks: ["a small mole on the left cheek"])

    for shot <- later do
      refute FacePrompts.prompt(shot, attrs) =~ "healed"
      assert FacePrompts.prompt(shot, attrs) =~ "any scars, moles or freckles exactly the same"
    end
  end

  test "probes vary head angle and expression slightly, the mugshots and ICAO portrait don't" do
    probes = ~w(probe_rebooking probe_aged probe_glasses probe_appearance)
    attrs = FaceAttributes.sample(7)

    for shot <- probes do
      prompt = FacePrompts.prompt(shot, attrs)
      v = FacePrompts.variation(shot, attrs)
      assert v.yaw in 4..19
      assert prompt =~ "the head is turned about #{v.yaw} degrees towards the #{v.towards}"
      assert prompt =~ "the expression changes to #{v.expression}"
      refute prompt =~ "neutral expression"
    end

    for shot <- FacePrompts.shots() -- probes do
      refute FacePrompts.prompt(shot, attrs) =~ "the expression changes to"
    end

    assert FacePrompts.prompt("icao_portrait", attrs) =~ "neutral expression"
  end

  test "a probe's variation is fixed per person and shot and differs between them" do
    people = for seed <- 1..60, do: FaceAttributes.sample(seed)
    [first | _] = people

    assert FacePrompts.variation("probe_aged", first) ==
             FacePrompts.variation("probe_aged", first)

    refute FacePrompts.variation("probe_aged", first) ==
             FacePrompts.variation("probe_glasses", first)

    variations = Enum.map(people, &FacePrompts.variation("probe_aged", &1))
    assert variations |> Enum.map(& &1.expression) |> Enum.uniq() |> length() > 5
    assert variations |> Enum.map(& &1.towards) |> Enum.uniq() |> Enum.sort() == ["left", "right"]
    assert variations |> Enum.map(& &1.pitch) |> Enum.uniq() |> length() == 3
    assert Enum.any?(variations, & &1.off_camera?)
    refute Enum.all?(variations, & &1.off_camera?)
  end

  test "probes change into clothes for the person's sex, in another colour" do
    changes = %{
      "icao_portrait" => "the clothing is now ",
      "probe_rebooking" => "now wears ",
      "probe_aged" => "now wears ",
      "probe_glasses" => "now wears ",
      "probe_appearance" => "now wears "
    }

    for seed <- 1..80, {shot, lead} <- changes do
      attrs = FaceAttributes.sample(seed)
      prompt = FacePrompts.prompt(shot, attrs)

      # The item the probe changes into ends that change (";" or ".").
      assert [item] =
               Enum.filter(FaceAttributes.clothing(), fn item ->
                 String.contains?(prompt, lead <> item <> ";") or
                   String.contains?(prompt, lead <> item <> ".")
               end)

      assert item in FaceAttributes.clothing(attrs.sex)

      refute FaceAttributes.clothing_colour(item) ==
               FaceAttributes.clothing_colour(attrs.clothing)
    end
  end

  test "the anchor prompt describes the person, conditioned shots refer to the reference" do
    attrs = FaceAttributes.sample(5)

    assert FacePrompts.prompt("mugshot_frontal", attrs) =~ FaceAttributes.describe(attrs)
    assert FacePrompts.prompt("mugshot_left_profile", attrs) =~ "reference image"
    assert FacePrompts.prompt("mugshot_left_profile", attrs) =~ "faces the left edge"
    assert FacePrompts.prompt("mugshot_right_profile", attrs) =~ "faces the right edge"
  end
end
